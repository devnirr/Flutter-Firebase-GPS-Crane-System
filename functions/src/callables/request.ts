import { onCall } from 'firebase-functions/v2/https';
import { logger } from 'firebase-functions/v2';
import { z } from 'zod';

import {
  ACTIVE_STATUSES,
  PaymentMethod,
  PaymentStatus,
  ServiceEventName,
  ServiceStatus,
  TruckType,
  UserRole,
  VehicleCondition,
  VehicleType,
  inferTruckType,
} from '../lib/enums.js';
import { Code, invalidArgument, precondition } from '../lib/errors.js';
import { GeoPoint } from 'firebase-admin/firestore';

import { FieldValue, Paths, Timestamp, db } from '../lib/firestore.js';
import {
  estimatedRoadKm,
  geohash,
  isInsidePolygon,
  isPlausiblyInDominicanRepublic,
  type LatLng,
} from '../lib/geo.js';
import { requireClient, requireNotInMaintenance } from '../lib/guards.js';
import { buildQuote, loadPricing, signQuote, verifyQuote } from '../lib/pricing.js';
import { serviceCode } from '../lib/time.js';
import { dispatchNext } from '../dispatch/dispatchNext.js';
import { region } from './region.js';

/**
 * Quoting and requesting a tow.
 *
 * The rule that shapes both: **the app never decides a price.** It asks what a
 * tow costs, shows the answer, and hands back a signature proving those were the
 * inputs we priced. `requestService` recomputes from the same inputs and refuses
 * a mismatch, so a modified client cannot request a RD$200 tow to Puerto Plata.
 */

const point = z.object({
  latitude: z.number().min(-90).max(90),
  longitude: z.number().min(-180).max(180),
});

const location = z.object({
  geo: point,
  address: z.string().max(300).default(''),
  reference: z.string().max(300).default(''),
  placeId: z.string().max(200).default(''),
  notes: z.string().max(500).default(''),
});

const vehicle = z.object({
  make: z.string().max(60).default(''),
  model: z.string().max(60).default(''),
  plate: z.string().max(20).default(''),
  color: z.string().max(40).default(''),
  year: z.number().int().min(1900).max(2100).nullable().optional(),
  type: z.nativeEnum(VehicleType).default(VehicleType.sedan),
  condition: z.nativeEnum(VehicleCondition).default(VehicleCondition.noArranca),
  photoPaths: z.array(z.string().max(400)).max(5).default([]),
  notes: z.string().max(500).default(''),
});

const quoteInput = z.object({
  pickup: location,
  dropoff: location,
  vehicle,
  truckTypeOverride: z.nativeEnum(TruckType).nullish(),
});

const requestInput = quoteInput.extend({
  truckType: z.nativeEnum(TruckType),
  paymentMethod: z.nativeEnum(PaymentMethod),
  quoteSignature: z.string().min(16).max(200),
  // Echoed back from quoteService. It is covered by the signature, so a client
  // cannot extend its own quote by editing this.
  quoteExpiresAtMs: z.number().int().positive(),
  paymentMethodId: z.string().max(200).nullish(),
  notes: z.string().max(500).nullish(),
});

const QUOTE_TTL_MS = 10 * 60 * 1000;

const toLatLng = (p: z.infer<typeof point>): LatLng => ({
  latitude: p.latitude,
  longitude: p.longitude,
});

/**
 * Refuses a point we cannot actually serve.
 *
 * Better to say so while the customer is still choosing than to accept the job
 * and strand them when the cascade finds nobody within 40 km.
 */
async function assertCovered(pickup: LatLng, dropoff: LatLng): Promise<void> {
  if (!isPlausiblyInDominicanRepublic(pickup)) {
    throw precondition(
      Code.outsideCoverage,
      'Todavía no damos servicio en esa zona. Llámanos y te ayudamos.',
    );
  }

  const snap = await Paths.appSettings().get();
  const settings = snap.data();
  const zones = (settings?.['zones'] as
    | { id: string; active?: boolean; polygon?: LatLng[] }[]
    | undefined) ?? [];
  const launchZoneIds = (settings?.['launchZoneIds'] as string[] | undefined) ?? [];

  const candidates = zones
    .filter((zone) => zone.active !== false)
    .filter((zone) => launchZoneIds.length === 0 || launchZoneIds.includes(zone.id));

  // No zones drawn yet: the country is the coverage area, so a fresh
  // environment is usable before somebody opens the polygon editor.
  if (candidates.length === 0) return;

  const covered = candidates.some((zone) =>
    isInsidePolygon(pickup, zone.polygon ?? []),
  );
  if (!covered) {
    throw precondition(
      Code.outsideCoverage,
      'Todavía no damos servicio en esa zona. Llámanos y te ayudamos.',
    );
  }

  void dropoff;
}

/**
 * Prices a tow.
 *
 * Distance is currently a straight line inflated by a detour factor. Swapping in
 * the Routes API is a change to this one function: everything downstream reads
 * `route.distanceMeters`, and the signature covers the resulting total either
 * way.
 */
export const quoteService = onCall({ region, cors: true }, async (request) => {
  const parsed = quoteInput.safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Revisa los datos e intenta de nuevo.');

  const caller = await requireClient(request);
  const { pickup, dropoff, vehicle: v, truckTypeOverride } = parsed.data;

  const from = toLatLng(pickup.geo);
  const to = toLatLng(dropoff.geo);
  await assertCovered(from, to);

  const truckType = truckTypeOverride ?? inferTruckType(v.type, v.condition);
  const distanceKm = estimatedRoadKm(from, to);
  const now = new Date();

  const pricing = await loadPricing();
  const quote = buildQuote({
    config: pricing,
    truckType,
    distanceKm,
    at: now,
    // ITBIS only applies to a fiscal receipt, which is only issued when the
    // customer has given an RNC.
    chargeItbis: Boolean((caller.user['rnc'] as string | undefined)?.trim()),
  });

  const expiresAt = new Date(now.getTime() + QUOTE_TTL_MS);
  const signature = signQuote({
    clientId: caller.uid,
    pickupGeohash: geohash(from),
    dropoffGeohash: geohash(to),
    totalCents: quote.totalCents,
    expiresAtMs: expiresAt.getTime(),
    pricingVersion: quote.pricingVersion,
    truckType,
  });

  return {
    quote,
    route: {
      distanceMeters: Math.round(distanceKm * 1000),
      durationSeconds: Math.round((distanceKm / 28) * 3600),
      polyline: '',
      provider: 'estimate',
      fetchedAt: now.toISOString(),
    },
    expiresAt: expiresAt.toISOString(),
    expiresAtMs: expiresAt.getTime(),
    signature,
    truckType,
  };
});

/**
 * Creates the service and starts the cascade.
 *
 * Two guards do most of the work here. The signature check stops a client
 * pricing its own tow. The active-service check stops a customer stacking
 * requests — and returns the existing id so the app can deep-link to it rather
 * than leaving them on a dead end.
 */
export const requestService = onCall({ region, cors: true }, async (request) => {
  const parsed = requestInput.safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Revisa los datos e intenta de nuevo.');

  const caller = await requireClient(request);
  await requireNotInMaintenance();

  const {
    pickup,
    dropoff,
    vehicle: v,
    truckType,
    paymentMethod,
    quoteSignature,
    quoteExpiresAtMs,
    notes,
  } = parsed.data;

  const from = toLatLng(pickup.geo);
  const to = toLatLng(dropoff.geo);
  await assertCovered(from, to);

  // One tow at a time. Checked before anything is written so a double-tap
  // cannot produce two services.
  const existing = await Paths.services()
    .where('clientId', '==', caller.uid)
    .where('status', 'in', ACTIVE_STATUSES)
    .limit(1)
    .get();

  if (!existing.empty) {
    throw precondition(
      Code.alreadyHasActiveService,
      'Ya tienes un servicio en curso.',
      { serviceId: existing.docs[0]!.id },
    );
  }

  const now = new Date();
  const pricing = await loadPricing();
  const distanceKm = estimatedRoadKm(from, to);
  const chargeItbis = Boolean((caller.user['rnc'] as string | undefined)?.trim());

  const quote = buildQuote({
    config: pricing,
    truckType,
    distanceKm,
    at: now,
    chargeItbis,
  });

  // The signature is checked against a freshly computed total, so tampering
  // with either the inputs or the price fails the same way.
  const expiresAtMs = quoteExpiresAtMs;

  if (Date.now() > expiresAtMs) {
    throw precondition(Code.quoteExpired, 'El precio venció. Vamos a calcularlo de nuevo.');
  }

  const signatureValid = verifyQuote(
    {
      clientId: caller.uid,
      pickupGeohash: geohash(from),
      dropoffGeohash: geohash(to),
      totalCents: quote.totalCents,
      expiresAtMs,
      pricingVersion: quote.pricingVersion,
      truckType,
    },
    quoteSignature,
  );

  if (!signatureValid) {
    logger.warn('request.signatureMismatch', { clientId: caller.uid });
    throw precondition(
      Code.quoteMismatch,
      'El precio cambió. Revisa el nuevo total antes de continuar.',
    );
  }

  const serviceRef = Paths.services().doc();
  const code = serviceCode(now);

  await db.runTransaction(async (transaction) => {
    transaction.create(serviceRef, {
      code,
      status: ServiceStatus.pendingDispatch,
      clientId: caller.uid,
      clientName: caller.user['name'] ?? '',
      clientPhone: caller.user['phone'] ?? '',
      vehicle: {
        ...v,
        year: v.year ?? null,
      },
      truckTypeRequired: truckType,
      pickup: {
        geo: new GeoPoint(from.latitude, from.longitude),
        geohash: geohash(from),
        address: pickup.address,
        reference: pickup.reference,
        placeId: pickup.placeId,
        notes: pickup.notes,
      },
      dropoff: {
        geo: new GeoPoint(to.latitude, to.longitude),
        geohash: geohash(to),
        address: dropoff.address,
        reference: dropoff.reference,
        placeId: dropoff.placeId,
        notes: dropoff.notes,
      },
      route: {
        distanceMeters: Math.round(distanceKm * 1000),
        durationSeconds: Math.round((distanceKm / 28) * 3600),
        polyline: '',
        provider: 'estimate',
        fetchedAt: Timestamp.fromDate(now),
      },
      quote,
      payment: {
        method: paymentMethod,
        status: PaymentStatus.none,
        gateway: '',
        authorizedCents: 0,
        capturedCents: 0,
        refundedCents: 0,
      },
      dispatch: { round: 0, radiusKm: 5, offeredTo: [], rejectedBy: [] },
      timeline: { createdAt: FieldValue.serverTimestamp() },
      driverNotes: notes ?? '',
      unreadForClient: 0,
      unreadForDriver: 0,
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });

    transaction.create(Paths.events(serviceRef.id).doc(), {
      event: ServiceEventName.requestService,
      from: '',
      to: ServiceStatus.pendingDispatch,
      actorId: caller.uid,
      actorRole: UserRole.client,
      meta: { truckType, paymentMethod },
      at: FieldValue.serverTimestamp(),
    });

    // Denormalised so the app can deep-link straight back into a tow in flight
    // without a query on cold start.
    transaction.update(Paths.user(caller.uid), {
      activeServiceId: serviceRef.id,
      updatedAt: FieldValue.serverTimestamp(),
    });
  });

  logger.info('service.requested', {
    serviceId: serviceRef.id,
    code,
    clientId: caller.uid,
    truckType,
    totalCents: quote.totalCents,
  });

  // Started immediately rather than by a trigger: the customer is watching a
  // "buscando grúa" screen and every second of latency is visible.
  await dispatchNext(serviceRef.id);

  return { serviceId: serviceRef.id, code };
});
