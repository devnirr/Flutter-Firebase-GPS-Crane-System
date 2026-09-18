import { GeoPoint } from 'firebase-admin/firestore';
import { onCall } from 'firebase-functions/v2/https';
import { logger } from 'firebase-functions/v2';

import {
  ACTIVE_STATUSES,
  PaymentMethod,
  PaymentStatus,
  ServiceEventName,
  ServiceStatus,
  UserRole,
  VehicleCondition,
  inferTruckType,
} from '../lib/enums.js';
import { Code, invalidArgument, precondition } from '../lib/errors.js';
import { FieldValue, Paths, db } from '../lib/firestore.js';
import { geohash, type LatLng } from '../lib/geo.js';
import { requireActiveInsurer, requireNotInMaintenance } from '../lib/guards.js';
import {
  claimKey,
  createInsurerServiceInput,
  driverPayoutBpsOf,
  insurerBilling,
  payoutSplit,
  quoteFromZone,
  quoteInsurerServiceInput,
  signInsurerQuote,
  verifyInsurerQuote,
} from '../lib/insurerService.js';
import { mapsApiKey, quoteSigningSecret } from '../lib/secrets.js';
import { serviceCode } from '../lib/time.js';
import { withItbis } from '../lib/zonePricing.js';
import { quoteForInsurer } from '../lib/zoneTariff.js';
import { dispatchNext } from '../dispatch/dispatchNext.js';
import { assertCovered, tripRoute } from './request.js';
import { region } from './region.js';

/**
 * Tows ordered by an insurance company.
 *
 * The same order and the same dispatch as a customer's tow, with three
 * differences: the price comes from the zone tariff, nobody pays at the
 * roadside, and there is no one-tow-at-a-time rule — a company has many
 * policyholders stranded at once. What stops a double order instead is the
 * claim number: one live tow per claim.
 */

const QUOTE_TTL_MS = 15 * 60 * 1000;

const toLatLng = (p: { latitude: number; longitude: number }): LatLng => ({
  latitude: p.latitude,
  longitude: p.longitude,
});

const roundTenths = (km: number): number => Math.round(km * 10) / 10;

/**
 * What a tow will cost the company, before it is ordered.
 *
 * Shows the price and the ITBIS it adds, never the chofer's share. The
 * signature lets the order bill exactly this distance.
 */
export const quoteInsurerService = onCall(
  { region, cors: true, secrets: [quoteSigningSecret, mapsApiKey] },
  async (request) => {
    const parsed = quoteInsurerServiceInput.safeParse(request.data);
    if (!parsed.success) throw invalidArgument('Revisa el origen, el destino y el vehículo.');

    const caller = await requireActiveInsurer(request);
    const { pickup, dropoff, vehicleType } = parsed.data;

    const from = toLatLng(pickup.geo);
    const to = toLatLng(dropoff.geo);
    await assertCovered(from, to);

    const now = new Date();
    const route = await tripRoute(from, to, now);
    const distanceKm = roundTenths(route.distanceMeters / 1000);

    const zone = await quoteForInsurer({
      insurerId: caller.insurerId,
      vehicleType,
      distanceKm,
    });

    const expiresAtMs = now.getTime() + QUOTE_TTL_MS;
    const signature = signInsurerQuote({
      insurerId: caller.insurerId,
      vehicleType,
      pickupGeohash: geohash(from),
      dropoffGeohash: geohash(to),
      distanceKm: zone.distanceKm,
      expiresAtMs,
    });

    return {
      price: {
        ...withItbis(zone.subtotalCents),
        vehicleClass: zone.vehicleClass,
        zoneMinKm: zone.zoneMinKm,
        zoneMaxKm: zone.zoneMaxKm,
        baseCents: zone.baseCents,
        extraKm: zone.extraKm,
        extraCents: zone.extraCents,
        tariff: zone.tariff,
      },
      route: {
        distanceMeters: route.distanceMeters,
        durationSeconds: route.durationSeconds,
        polyline: route.polyline,
        provider: route.provider,
      },
      priced: {
        distanceKm: zone.distanceKm,
        expiresAtMs,
        signature,
      },
    };
  },
);

/**
 * Orders the tow and starts looking for the nearest grúa.
 *
 * Heavy vehicles go straight to dispatch too — only to heavy grúas. The
 * customer flow holds them for an operator to confirm the price; here the
 * price is the company's contract, and there is nothing to confirm.
 */
export const createInsurerService = onCall(
  { region, cors: true, secrets: [quoteSigningSecret, mapsApiKey] },
  async (request) => {
    const parsed = createInsurerServiceInput.safeParse(request.data);
    if (!parsed.success) {
      const field = parsed.error.issues[0]?.path.join('.') ?? '';
      logger.warn('insurerService.invalidInput', {
        issues: parsed.error.issues.map((i) => ({ path: i.path.join('.'), code: i.code })),
      });
      throw invalidArgument(
        field.startsWith('insurance.claimNumber')
          ? 'Escribe el número de siniestro.'
          : field.startsWith('insurance.insuredPhone')
            ? 'El teléfono del asegurado no es válido.'
            : 'Revisa los datos del servicio.',
      );
    }

    const caller = await requireActiveInsurer(request);
    await requireNotInMaintenance();

    const input = parsed.data;
    const from = toLatLng(input.pickup.geo);
    const to = toLatLng(input.dropoff.geo);
    await assertCovered(from, to);

    const now = new Date();
    // Outside the transaction: no network inside one.
    const route = await tripRoute(from, to, now);

    let distanceKm = roundTenths(route.distanceMeters / 1000);
    if (input.priced) {
      if (Date.now() > input.priced.expiresAtMs) {
        throw precondition(Code.quoteExpired, 'El precio venció. Vuelve a calcularlo.');
      }
      const signed = roundTenths(input.priced.distanceKm);
      const valid = verifyInsurerQuote(
        {
          insurerId: caller.insurerId,
          vehicleType: input.vehicle.type,
          pickupGeohash: geohash(from),
          dropoffGeohash: geohash(to),
          distanceKm: signed,
          expiresAtMs: input.priced.expiresAtMs,
        },
        input.priced.signature,
      );
      if (!valid) {
        logger.warn('insurerService.signatureMismatch', { insurerId: caller.insurerId });
        throw precondition(
          Code.quoteMismatch,
          'Cambiaron los datos del servicio. Revisa el precio antes de continuar.',
        );
      }
      distanceKm = signed;
    }

    const zone = await quoteForInsurer({
      insurerId: caller.insurerId,
      vehicleType: input.vehicle.type,
      distanceKm,
    });
    const split = payoutSplit(zone.subtotalCents, driverPayoutBpsOf(caller.insurer));
    const truckType = inferTruckType(input.vehicle.type, VehicleCondition.noArranca);
    const key = claimKey(input.insurance.claimNumber);
    if (key === '') throw invalidArgument('Escribe el número de siniestro.');

    const serviceRef = Paths.services().doc();
    const code = serviceCode(now);
    const insurerName = (caller.insurer['name'] as string | undefined) ?? '';
    const requesterName = (caller.member['name'] as string | undefined) ?? '';

    await db.runTransaction(async (transaction) => {
      // Inside the transaction, so two operators ordering the same claim at
      // the same moment cannot both succeed.
      const duplicate = await transaction.get(
        Paths.services()
          .where('insurerId', '==', caller.insurerId)
          .where('insurance.claimKey', '==', key)
          .where('status', 'in', ACTIVE_STATUSES)
          .limit(1),
      );
      if (!duplicate.empty) {
        throw precondition(
          Code.alreadyHasActiveService,
          'Ya hay un servicio en curso para ese número de siniestro.',
          { serviceId: duplicate.docs[0]!.id },
        );
      }

      transaction.create(serviceRef, {
        code,
        status: ServiceStatus.pendingDispatch,
        // No private customer: nobody's profile to update, nobody to charge.
        // The insured person is who the chofer meets, so they stand in the
        // fields the chofer's app shows.
        clientId: '',
        clientName: input.insurance.insuredName,
        clientPhone: input.insurance.insuredPhone,
        insurerId: caller.insurerId,
        insurerName,
        requestedBy: { uid: caller.uid, name: requesterName },
        insurance: { ...input.insurance, claimKey: key },
        vehicle: {
          ...input.vehicle,
          year: input.vehicle.year ?? null,
          condition: VehicleCondition.noArranca,
          photoPaths: [],
          notes: '',
        },
        truckTypeRequired: truckType,
        pickup: {
          geo: new GeoPoint(from.latitude, from.longitude),
          geohash: geohash(from),
          address: input.pickup.address,
          reference: input.pickup.reference,
          placeId: input.pickup.placeId,
          notes: input.pickup.notes,
        },
        dropoff: {
          geo: new GeoPoint(to.latitude, to.longitude),
          geohash: geohash(to),
          address: input.dropoff.address,
          reference: input.dropoff.reference,
          placeId: input.dropoff.placeId,
          notes: input.dropoff.notes,
        },
        route,
        quote: quoteFromZone(zone, input.vehicle.type),
        billing: insurerBilling(caller.insurerId, zone),
        payment: {
          method: PaymentMethod.insurer,
          status: PaymentStatus.none,
          capturedCents: 0,
        },
        dispatch: { round: 0, radiusKm: 5, offeredTo: [], rejectedBy: [] },
        timeline: { createdAt: FieldValue.serverTimestamp() },
        driverNotes: input.notes,
        unreadForClient: 0,
        unreadForDriver: 0,
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });

      // The split, where only the office can read it.
      transaction.create(Paths.serviceBilling(serviceRef.id), {
        serviceId: serviceRef.id,
        insurerId: caller.insurerId,
        subtotalCents: zone.subtotalCents,
        ...split,
        createdAt: FieldValue.serverTimestamp(),
      });

      transaction.create(Paths.events(serviceRef.id).doc(), {
        event: ServiceEventName.requestService,
        from: '',
        to: ServiceStatus.pendingDispatch,
        actorId: caller.uid,
        actorRole: UserRole.insurer,
        meta: {
          truckType,
          vehicleType: input.vehicle.type,
          insurerId: caller.insurerId,
          claimNumber: input.insurance.claimNumber,
        },
        at: FieldValue.serverTimestamp(),
      });
    });

    logger.info('insurerService.requested', {
      serviceId: serviceRef.id,
      code,
      insurerId: caller.insurerId,
      by: caller.uid,
      subtotalCents: zone.subtotalCents,
    });

    await dispatchNext(serviceRef.id);

    return {
      serviceId: serviceRef.id,
      code,
      price: withItbis(zone.subtotalCents),
    };
  },
);
