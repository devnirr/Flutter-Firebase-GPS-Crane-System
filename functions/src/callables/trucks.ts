import { logger } from 'firebase-functions/v2';
import { onCall } from 'firebase-functions/v2/https';
import { z } from 'zod';

import { TruckType } from '../lib/enums.js';
import { Code, invalidArgument, precondition } from '../lib/errors.js';
import { FieldValue, Paths, db } from '../lib/firestore.js';
import { requireAdmin } from '../lib/guards.js';
import {
  MAX_CAPACITY_KG,
  MIN_TRUCK_YEAR,
  isValidPlate,
  maxTruckYear,
  normalizePlate,
} from '../lib/trucks.js';
import { audit } from './admin.js';
import { region } from './region.js';

/**
 * The fleet: creating, editing and retiring grúas.
 *
 * Two things make this more than a form behind a callable. The plate is unique
 * across the fleet, enforced by `trucks_by_plate/{PLATE}` claimed in the same
 * transaction as the truck, because a query-then-write check lets two admins
 * register the same plate a second apart. And the chofer carries a copy of
 * their grúa's plate and type — the type is what dispatch matches jobs on — so
 * every change here keeps that copy in step, and refuses the changes that
 * would pull a truck out from under a job.
 */

const truckFields = z.object({
  plate: z.string().min(1).max(20),
  make: z.string().trim().min(1).max(40),
  model: z.string().trim().min(1).max(40),
  year: z
    .number()
    .int()
    .min(MIN_TRUCK_YEAR)
    .refine((y) => y <= maxTruckYear(), { message: 'Año inválido' })
    .nullish(),
  color: z.string().trim().max(30).default(''),
  // `unknown` is a decoding fallback, not a truck anybody can drive.
  type: z.enum([TruckType.plataforma, TruckType.gancho, TruckType.pesada]),
  capacityKg: z.number().int().min(1).max(MAX_CAPACITY_KG),
  registrationNumber: z.string().trim().max(40).default(''),
  insurancePolicy: z.string().trim().max(60).default(''),
  // Required: expiring paperwork is what the fleet screen exists to catch, and
  // a truck with no dates on file is one it can never warn about.
  insuranceExpiry: z.string().datetime(),
  marbeteExpiry: z.string().datetime(),
});

type TruckFields = z.infer<typeof truckFields>;

/** Parses the plate, or refuses with the format the office should type. */
function plateFrom(input: TruckFields): string {
  const plate = normalizePlate(input.plate);
  if (!isValidPlate(plate)) {
    throw invalidArgument('Esa placa no es válida. Ejemplo: L123456.');
  }
  return plate;
}

/** The editable part of a truck document. */
function editableFields(input: TruckFields, plate: string) {
  return {
    plate,
    make: input.make,
    model: input.model,
    year: input.year ?? null,
    color: input.color,
    type: input.type,
    capacityKg: input.capacityKg,
    registrationNumber: input.registrationNumber,
    insurancePolicy: input.insurancePolicy,
    insuranceExpiry: new Date(input.insuranceExpiry),
    marbeteExpiry: new Date(input.marbeteExpiry),
  };
}

const duplicatePlate = () =>
  precondition(Code.invalidInput, 'Ya existe una grúa con esa placa.');

/** Adds a grúa to the fleet, unassigned. A chofer is put on it from their form. */
export const createTruck = onCall({ region, cors: true }, async (request) => {
  const parsed = truckFields.safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Revisa los datos de la grúa.');

  const caller = requireAdmin(request);
  const input = parsed.data;
  const plate = plateFrom(input);

  const truckRef = Paths.trucks().doc();
  const now = FieldValue.serverTimestamp();

  await db.runTransaction(async (tx) => {
    const index = Paths.truckByPlate(plate);
    if ((await tx.get(index)).exists) throw duplicatePlate();

    tx.create(index, { truckId: truckRef.id, createdAt: now });
    tx.create(truckRef, {
      ...editableFields(input, plate),
      active: true,
      inactiveReason: '',
      assignedDriverId: null,
      assignedDriverName: '',
      photoPaths: [],
      completedServices: 0,
      archived: false,
      createdBy: caller.uid,
      createdAt: now,
      updatedAt: now,
    });
  });

  await audit(caller.uid, 'createTruck', truckRef.id, { plate });
  logger.info('truck.created', { truckId: truckRef.id, plate, by: caller.uid });
  return { truckId: truckRef.id };
});

/**
 * Saves the office's edits to a grúa.
 *
 * The plate and the type are the two fields the rest of the system leans on.
 * Neither may change mid-tow: the customer is watching for that plate, and the
 * job was offered for that type. The type is also refused while the chofer is
 * merely online, because their live position still advertises the old one and
 * dispatch would keep matching them against it.
 */
export const updateTruck = onCall({ region, cors: true }, async (request) => {
  const parsed = truckFields
    .extend({ truckId: z.string().min(1).max(64) })
    .safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Revisa los datos de la grúa.');

  const caller = requireAdmin(request);
  const input = parsed.data;
  const plate = plateFrom(input);
  const truckRef = Paths.truck(input.truckId);

  let plateChanged = false;
  let typeChanged = false;

  await db.runTransaction(async (tx) => {
    // Every read before the first write, as a transaction requires.
    const truck = (await tx.get(truckRef)).data();
    if (!truck || truck['archived'] === true) {
      throw precondition(Code.notFound, 'Grúa no encontrada.');
    }

    const previousPlate = normalizePlate((truck['plate'] as string | undefined) ?? '');
    plateChanged = previousPlate !== plate;
    typeChanged = truck['type'] !== input.type;

    const driverId = (truck['assignedDriverId'] as string | null | undefined) ?? null;
    const driverRef = driverId ? Paths.driver(driverId) : null;
    const driver = driverRef ? (await tx.get(driverRef)).data() : undefined;

    if (driver && (plateChanged || typeChanged) && driver['currentServiceId']) {
      throw precondition(
        Code.driverBusy,
        'El chofer de esta grúa tiene un servicio en curso. ' +
          'Cambia la placa o el tipo cuando termine.',
        { serviceId: driver['currentServiceId'] },
      );
    }
    if (driver && typeChanged && driver['isOnline'] === true) {
      throw precondition(
        Code.driverBusy,
        'El chofer de esta grúa está en línea. ' +
          'Cambia el tipo cuando se desconecte.',
      );
    }

    const previousIndexRef = previousPlate ? Paths.truckByPlate(previousPlate) : null;
    const previousIndex = previousIndexRef && plateChanged
      ? (await tx.get(previousIndexRef)).data()
      : undefined;
    if (plateChanged) {
      const claimed = (await tx.get(Paths.truckByPlate(plate))).data();
      if (claimed && claimed['truckId'] !== input.truckId) throw duplicatePlate();
    }

    const now = FieldValue.serverTimestamp();
    if (plateChanged) {
      // Only an index this truck owns is released; one left by another truck
      // (an import, a seed) is not this edit's to delete.
      if (previousIndexRef && previousIndex?.['truckId'] === input.truckId) {
        tx.delete(previousIndexRef);
      }
      tx.set(Paths.truckByPlate(plate), { truckId: input.truckId, createdAt: now });
    }
    tx.update(truckRef, { ...editableFields(input, plate), updatedAt: now });
    if (driverRef && driver && (plateChanged || typeChanged)) {
      tx.update(driverRef, {
        assignedTruckPlate: plate,
        truckType: input.type,
        updatedAt: now,
      });
    }
  });

  await audit(caller.uid, 'updateTruck', input.truckId, {
    plate,
    plateChanged,
    typeChanged,
  });
  return { ok: true };
});

/**
 * "Deletes" a grúa: archives it and frees its plate.
 *
 * Archived rather than erased, like a chofer — its services name it. The chofer
 * driving it is left without a grúa and taken offline, since a chofer with
 * nothing to drive must not stay dispatchable. Refused mid-tow.
 */
export const archiveTruck = onCall({ region, cors: true }, async (request) => {
  const parsed = z
    .object({ truckId: z.string().min(1).max(64) })
    .safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Datos inválidos.');

  const caller = requireAdmin(request);
  const { truckId } = parsed.data;
  const truckRef = Paths.truck(truckId);

  // Asserted rather than annotated: an annotation alone narrows this to `null`
  // at the check below, since assignments inside the callback are invisible.
  let unassignedDriverId = null as string | null;

  await db.runTransaction(async (tx) => {
    const truck = (await tx.get(truckRef)).data();
    if (!truck) throw precondition(Code.notFound, 'Grúa no encontrada.');
    if (truck['archived'] === true) return;

    const driverId = (truck['assignedDriverId'] as string | null | undefined) ?? null;
    const driverRef = driverId ? Paths.driver(driverId) : null;
    const driver = driverRef ? (await tx.get(driverRef)).data() : undefined;
    if (driver?.['currentServiceId']) {
      throw precondition(
        Code.driverBusy,
        'El chofer de esta grúa tiene un servicio en curso. ' +
          'Elimínala cuando termine.',
        { serviceId: driver['currentServiceId'] },
      );
    }

    const plate = normalizePlate((truck['plate'] as string | undefined) ?? '');
    const indexRef = plate ? Paths.truckByPlate(plate) : null;
    const index = indexRef ? (await tx.get(indexRef)).data() : undefined;

    const now = FieldValue.serverTimestamp();
    tx.update(truckRef, {
      archived: true,
      archivedAt: now,
      archivedBy: caller.uid,
      active: false,
      inactiveReason: 'Eliminada por la oficina',
      assignedDriverId: null,
      assignedDriverName: '',
      updatedAt: now,
    });
    // The plate goes back to the pool: a truck re-registered after a sale or a
    // mistake must not be refused as a duplicate of itself.
    if (indexRef && index?.['truckId'] === truckId) tx.delete(indexRef);

    if (driverRef && driver && driver['assignedTruckId'] === truckId) {
      unassignedDriverId = driverId;
      tx.update(driverRef, {
        assignedTruckId: null,
        assignedTruckPlate: '',
        truckType: 'unknown',
        isOnline: false,
        updatedAt: now,
      });
    }
  });

  if (unassignedDriverId) {
    // Off the live map at once rather than after the stale-position sweep.
    await Paths.live(unassignedDriverId)
      .update({ isOnline: false, updatedAt: Date.now() })
      .catch(() => undefined);
  }

  await audit(caller.uid, 'archiveTruck', truckId, {
    unassignedDriverId,
  });
  logger.info('truck.archived', { truckId, by: caller.uid });
  return { ok: true };
});
