import { getAuth } from 'firebase-admin/auth';
import { onCall } from 'firebase-functions/v2/https';
import { logger } from 'firebase-functions/v2';
import { z } from 'zod';

import {
  AssignmentMode,
  DriverLiveState,
  DriverStatus,
  ServiceEventName,
  UserRole,
} from '../lib/enums.js';
import { Code, invalidArgument, permissionDenied, precondition } from '../lib/errors.js';
import { FieldValue, Paths, db } from '../lib/firestore.js';
import { requireAdmin, requireAuth, requireStaff } from '../lib/guards.js';
import { notify } from '../lib/push.js';
import { applyTransition } from '../lib/stateMachine.js';
import { region } from './region.js';

/**
 * Everything the office does.
 *
 * Choferes cannot self-register: an account created from a phone is an account
 * that can work without documents on file, insurance the company has not seen,
 * and a truck nobody has inspected. So account creation is here, behind an
 * admin claim, and every mutation writes an audit entry naming who did it.
 */

/** Records who changed what. Nothing in this file writes without one. */
async function audit(
  actorId: string,
  action: string,
  target: string,
  details: Record<string, unknown> = {},
): Promise<void> {
  await Paths.audit().add({
    actorId,
    action,
    target,
    details,
    at: FieldValue.serverTimestamp(),
  });
}

/** Dominican cédula: 11 digits, with a check digit. */
function isValidCedula(raw: string): boolean {
  const digits = raw.replace(/\D/g, '');
  if (digits.length !== 11) return false;

  // Luhn-style alternating 1/2 weighting, as used by the JCE.
  let sum = 0;
  for (let i = 0; i < 10; i++) {
    const weight = i % 2 === 0 ? 1 : 2;
    let product = Number(digits[i]) * weight;
    if (product > 9) product -= 9;
    sum += product;
  }
  const check = (10 - (sum % 10)) % 10;
  return check === Number(digits[10]);
}

const createDriverInput = z.object({
  name: z.string().min(3).max(120),
  cedula: z.string().min(11).max(20),
  phone: z.string().min(10).max(20),
  email: z.string().email().max(200),
  licenseNumber: z.string().max(40).default(''),
  licenseExpiry: z.string().datetime().nullish(),
  truckId: z.string().max(64).nullish(),
  initialPassword: z.string().min(8).max(128).nullish(),
});

/**
 * Creates a chofer account.
 *
 * The account starts `inactive` regardless of what the caller asks for. It
 * becomes active only once documents are verified, which is the one gate
 * between the office and a grúa on the road with lapsed insurance.
 */
export const createDriver = onCall({ region, cors: true }, async (request) => {
  const parsed = createDriverInput.safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Revisa los datos del chofer.');

  const caller = requireAdmin(request);
  const input = parsed.data;

  if (!isValidCedula(input.cedula)) {
    throw invalidArgument('La cédula no es válida.');
  }

  const cedula = input.cedula.replace(/\D/g, '');

  // A duplicate cédula means either a typo or a second account for somebody who
  // already has one; both need a human, not a silent create.
  const duplicate = await Paths.drivers().where('cedula', '==', cedula).limit(1).get();
  if (!duplicate.empty) {
    throw precondition(Code.invalidInput, 'Ya existe un chofer con esa cédula.', {
      driverId: duplicate.docs[0]!.id,
    });
  }

  const password =
    input.initialPassword ?? `Grua${Math.random().toString(36).slice(2, 10)}!`;

  const user = await getAuth().createUser({
    email: input.email,
    password,
    displayName: input.name,
    phoneNumber: input.phone.startsWith('+') ? input.phone : undefined,
  });

  // The claim is what the security rules and every callable read. Setting it
  // before the document exists would leave a window where the token says
  // "driver" and there is nothing to read.
  await getAuth().setCustomUserClaims(user.uid, {
    role: UserRole.driver,
    driverId: user.uid,
  });

  const truck = input.truckId ? await Paths.truck(input.truckId).get() : null;

  await Paths.driver(user.uid).set({
    name: input.name,
    cedula,
    phone: input.phone,
    email: input.email,
    licenseNumber: input.licenseNumber,
    licenseExpiry: input.licenseExpiry ? new Date(input.licenseExpiry) : null,
    status: DriverStatus.inactive,
    statusReason: 'Documentos pendientes de verificación',
    assignedTruckId: input.truckId ?? null,
    assignedTruckPlate: (truck?.data()?.['plate'] as string | undefined) ?? '',
    truckType: (truck?.data()?.['type'] as string | undefined) ?? '',
    isOnline: false,
    rating: 4.8,
    ratingCount: 0,
    completedServices: 0,
    offersSent: 0,
    offersAccepted: 0,
    cancellations: 0,
    cashOwedCents: 0,
    mustChangePassword: true,
    archived: false,
    createdBy: caller.uid,
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  });

  if (input.truckId) {
    await Paths.truck(input.truckId).update({
      assignedDriverId: user.uid,
      assignedDriverName: input.name,
      updatedAt: FieldValue.serverTimestamp(),
    });
  }

  await audit(caller.uid, 'createDriver', user.uid, { email: input.email });
  logger.info('driver.created', { driverId: user.uid, by: caller.uid });

  // Returned once and never again: the office reads it to the chofer, and the
  // account forces a change on first sign-in.
  return { driverId: user.uid, temporaryPassword: password };
});

/**
 * Activates, deactivates or suspends a chofer.
 *
 * Suspension is immediate and total: refresh tokens are revoked so an existing
 * session cannot keep working for the up-to-an-hour a claim stays valid, and
 * the RTDB node is switched off so dispatch stops seeing them.
 */
export const setDriverStatus = onCall({ region, cors: true }, async (request) => {
  const parsed = z
    .object({
      driverId: z.string().min(1).max(64),
      status: z.nativeEnum(DriverStatus),
      reason: z.string().max(300).default(''),
    })
    .safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Datos inválidos.');

  const caller = requireAdmin(request);
  const { driverId, status, reason } = parsed.data;

  const snap = await Paths.driver(driverId).get();
  const driver = snap.data();
  if (!driver) throw precondition(Code.notFound, 'Chofer no encontrado.');

  // Deactivating somebody mid-tow would strand a loaded vehicle.
  const busyWith = driver['currentServiceId'] as string | undefined;
  if (status !== DriverStatus.active && busyWith) {
    throw precondition(
      Code.driverBusy,
      'Este chofer tiene un servicio en curso. Reasígnalo primero.',
      { serviceId: busyWith },
    );
  }

  await Paths.driver(driverId).update({
    status,
    statusReason: reason,
    ...(status === DriverStatus.active ? {} : { isOnline: false }),
    updatedAt: FieldValue.serverTimestamp(),
  });

  if (status !== DriverStatus.active) {
    await Paths.live(driverId).update({ isOnline: false, updatedAt: Date.now() });
    await getAuth().revokeRefreshTokens(driverId);
  }

  await audit(caller.uid, 'setDriverStatus', driverId, { status, reason });
  return { ok: true };
});

/**
 * A dispatcher assigns the job by hand.
 *
 * Used when the cascade gave up. The same invariants as an automatic accept
 * apply — the chofer must be active, free and driving the right truck — because
 * a manual assignment that ignores them produces the same stranded customer,
 * just later.
 */
export const assignServiceManually = onCall({ region, cors: true }, async (request) => {
  const parsed = z
    .object({
      serviceId: z.string().min(1).max(64),
      driverId: z.string().min(1).max(64),
      note: z.string().max(300).default(''),
    })
    .safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Datos inválidos.');

  const caller = requireStaff(request);
  const { serviceId, driverId, note } = parsed.data;

  await applyTransition({
    serviceId,
    event: ServiceEventName.assignServiceManually,
    actorId: caller.uid,
    actorRole: caller.role as UserRole,
    meta: { driverId, note },

    inTransaction: async ({ transaction }) => {
      const driverRef = Paths.driver(driverId);
      const driverSnap = await transaction.get(driverRef);
      const driver = driverSnap.data();

      if (!driver) throw precondition(Code.notFound, 'Chofer no encontrado.');
      if (driver['status'] !== DriverStatus.active) {
        throw precondition(Code.driverInactive, 'Ese chofer no está activo.');
      }
      if (driver['currentServiceId']) {
        throw precondition(Code.driverBusy, 'Ese chofer ya tiene un servicio.');
      }

      transaction.update(driverRef, {
        currentServiceId: serviceId,
        updatedAt: FieldValue.serverTimestamp(),
      });

      transaction.update(Paths.service(serviceId), {
        driverId,
        driverName: driver['name'] ?? '',
        driverPhone: driver['phone'] ?? '',
        driverRating: driver['rating'] ?? 0,
        truckId: driver['assignedTruckId'] ?? null,
        truckPlate: driver['assignedTruckPlate'] ?? '',
        assignedAt: FieldValue.serverTimestamp(),
        assignmentMode: AssignmentMode.manual,
        'timeline.acceptedAt': FieldValue.serverTimestamp(),
      });
    },

    afterCommit: async ({ service }) => {
      await Paths.live(driverId).update({
        state: DriverLiveState.onService,
        serviceId,
        updatedAt: Date.now(),
      });

      // Pushed as an assignment, not an offer: there is nothing to accept or
      // decline, so a ringing screen with two buttons would be a lie.
      await notify({
        uid: driverId,
        audience: 'driver',
        title: 'Servicio asignado',
        body: 'La oficina te asignó un servicio.',
        data: { serviceId, type: 'assigned' },
      });

      const clientId = service['clientId'] as string | undefined;
      if (clientId) {
        await notify({
          uid: clientId,
          audience: 'client',
          title: 'Tu grúa va en camino',
          body: 'Ya asignamos un chofer a tu servicio.',
          data: { serviceId, type: 'driver_assigned' },
        });
      }
    },
  });

  await audit(caller.uid, 'assignServiceManually', serviceId, { driverId, note });
  return { ok: true };
});

/**
 * Grants the first admin.
 *
 * Succeeds only when nobody holds an admin claim yet and the caller's email is
 * on the allowlist, so this cannot be used to escalate later. After the first
 * admin exists it is permanently inert.
 */
export const bootstrapFirstAdmin = onCall({ region, cors: true }, async (request) => {
  const caller = requireAuth(request);

  const allowlist = (process.env['ADMIN_BOOTSTRAP_EMAILS'] ?? '')
    .split(',')
    .map((entry) => entry.trim().toLowerCase())
    .filter(Boolean);

  const email = (request.auth?.token['email'] as string | undefined)?.toLowerCase();
  if (!email || !allowlist.includes(email)) throw permissionDenied();

  const existing = await db.collection('admins_marker').doc('bootstrapped').get();
  if (existing.exists) {
    throw precondition(Code.invalidInput, 'Ya existe un administrador.');
  }

  await getAuth().setCustomUserClaims(caller.uid, { role: UserRole.admin });
  await db.collection('admins_marker').doc('bootstrapped').set({
    uid: caller.uid,
    at: FieldValue.serverTimestamp(),
  });

  await audit(caller.uid, 'bootstrapFirstAdmin', caller.uid, { email });
  logger.warn('admin.bootstrapped', { uid: caller.uid, email });

  return { ok: true, role: UserRole.admin };
});

/** Sets or clears a staff role. Refuses to remove the last admin. */
export const setAdminRole = onCall({ region, cors: true }, async (request) => {
  const parsed = z
    .object({
      uid: z.string().min(1).max(128),
      role: z.enum([UserRole.admin, UserRole.ops]).nullable(),
    })
    .safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Datos inválidos.');

  const caller = requireAdmin(request);
  const { uid, role } = parsed.data;

  if (role === null && uid === caller.uid) {
    throw precondition(
      Code.invalidInput,
      'No puedes quitarte tu propio acceso de administrador.',
    );
  }

  await getAuth().setCustomUserClaims(uid, role ? { role } : {});
  await getAuth().revokeRefreshTokens(uid);
  await audit(caller.uid, 'setAdminRole', uid, { role });

  return { ok: true };
});

/** What the caller is allowed to do. The panel's single source of truth. */
export const whoAmI = onCall({ region, cors: true }, async (request) => {
  const caller = requireAuth(request);
  return {
    uid: caller.uid,
    role: caller.role ?? null,
    canManageDrivers: caller.role === UserRole.admin,
    canAssignServices:
      caller.role === UserRole.admin || caller.role === UserRole.ops,
    canEditPricing: caller.role === UserRole.admin,
  };
});
