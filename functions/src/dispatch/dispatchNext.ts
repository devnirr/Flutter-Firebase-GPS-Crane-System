import { logger } from 'firebase-functions/v2';

import {
  DriverStatus,
  OfferState,
  ServiceEventName,
  ServiceStatus,
  TruckType,
} from '../lib/enums.js';
import { FieldValue, Paths, Timestamp, db } from '../lib/firestore.js';
import { distanceMeters, type LatLng } from '../lib/geo.js';
import { isAvailableWithin, positionsWithin } from '../lib/live.js';
import { commissionCents, loadPricing } from '../lib/pricing.js';
import { alertAdmins, sendOffer } from '../lib/push.js';
import { applyTransition } from '../lib/stateMachine.js';
import { enqueueOfferExpiry } from '../lib/tasks.js';

/**
 * The dispatch cascade.
 *
 * One chofer at a time gets one exclusive offer, for 25 seconds, with the search
 * radius doubling each time nobody takes it. Broadcasting to everyone is much
 * simpler and it is the wrong design: two choferes accept the same job, one
 * drives out for nothing, and within a week they have all learned that the
 * notification is a lottery and stopped looking at it.
 *
 * The expensive part is being *correct* rather than being clever. Two
 * invocations of this function racing — a task firing while a rejection
 * cascades — must produce at most one live offer, so the offer is created in a
 * transaction that re-reads the service and bails if anything moved underneath.
 */

export interface DispatchConfig {
  offerTtlMs: number;
  startRadiusKm: number;
  maxRadiusKm: number;
  maxRounds: number;
  maxDispatchMs: number;
  retryDelayMs: number;
  arrivalRadiusM: number;
  completionRadiusM: number;
  stalePositionMs: number;
  weightDistance: number;
  weightRating: number;
  weightIdleTime: number;
}

export const DEFAULT_DISPATCH: DispatchConfig = {
  offerTtlMs: 25000,
  startRadiusKm: 5,
  maxRadiusKm: 40,
  maxRounds: 8,
  maxDispatchMs: 360000,
  retryDelayMs: 15000,
  arrivalRadiusM: 300,
  completionRadiusM: 500,
  stalePositionMs: 90000,
  weightDistance: 0.7,
  weightRating: 0.2,
  weightIdleTime: 0.1,
};

export async function loadDispatchConfig(): Promise<DispatchConfig> {
  const snap = await Paths.dispatchConfig().get();
  return { ...DEFAULT_DISPATCH, ...(snap.data() as Partial<DispatchConfig> | undefined) };
}

export interface Candidate {
  driverId: string;
  position: LatLng;
  distanceM: number;
  rating: number;
  idleMinutes: number;
  score: number;
  truckId?: string;
  name: string;
  phone: string;
}

/**
 * Ranks the choferes who could take this job. Lower score wins.
 *
 * Distance dominates because it is what the customer feels. Rating and idle
 * time only break ties: weighting them heavily would send the nearest truck
 * past a job to reward a better-rated one three kilometres further out.
 */
export function scoreCandidates(
  candidates: Omit<Candidate, 'score'>[],
  radiusKm: number,
  config: DispatchConfig,
): Candidate[] {
  const norm = (value: number, min: number, max: number): number =>
    max === min ? 0 : Math.min(1, Math.max(0, (value - min) / (max - min)));

  return candidates
    .map((candidate) => ({
      ...candidate,
      score:
        config.weightDistance * norm(candidate.distanceM / 1000, 0, radiusKm) +
        config.weightRating * (1 - norm(candidate.rating, 3, 5)) +
        config.weightIdleTime * (1 - norm(candidate.idleMinutes, 0, 30)),
    }))
    .sort((a, b) => a.score - b.score);
}

/**
 * Finds eligible choferes at a given radius.
 *
 * Every filter here exists because of a specific way dispatch goes wrong:
 * a stale position is a phone that lost signal, a busy chofer is already towing
 * something, a mismatched truck type cannot lift the vehicle, and an already-
 * offered chofer must not be asked twice in one cascade.
 */
async function findCandidates(options: {
  pickup: LatLng;
  radiusKm: number;
  truckType: TruckType;
  excluded: Set<string>;
  paymentMethod: string;
  config: DispatchConfig;
  now: number;
}): Promise<Candidate[]> {
  const { pickup, radiusKm, truckType, excluded, config, now } = options;

  const positions = await positionsWithin(pickup, radiusKm);

  const nearby = positions.filter((position) => {
    if (excluded.has(position.driverId)) return false;
    if (position.truckType !== truckType) return false;
    // Online, idle, fresh, and inside the real circle — geohash boxes
    // over-select.
    return isAvailableWithin(position, pickup, radiusKm, {
      now,
      staleMs: config.stalePositionMs,
    });
  });

  if (nearby.length === 0) return [];

  const pricing = await loadPricing();

  // One read per candidate, but the candidate list is a handful of trucks and
  // the RTDB node cannot be trusted about account state.
  const drivers = await db.getAll(
    ...nearby.map((position) => Paths.driver(position.driverId)),
  );

  const eligible: Omit<Candidate, 'score'>[] = [];

  for (let i = 0; i < nearby.length; i++) {
    const position = nearby[i]!;
    const driver = drivers[i]?.data();
    if (!driver) continue;
    if (driver['status'] !== DriverStatus.active) continue;
    if (driver['archived'] === true) continue;
    // Already towing something. The RTDB state should agree, but the Firestore
    // document is the authority on assignment.
    if (typeof driver['currentServiceId'] === 'string' && driver['currentServiceId']) {
      continue;
    }

    // A chofer over the cash limit stops receiving cash work but keeps getting
    // card work, so the limit throttles exposure without idling the truck.
    if (
      options.paymentMethod === 'cash' &&
      (driver['cashOwedCents'] as number | undefined ?? 0) >= pricing.maxCashOwedCents
    ) {
      continue;
    }

    const point: LatLng = { latitude: position.lat, longitude: position.lng };
    const lastOnline = (driver['lastOnlineAt'] as FirebaseFirestore.Timestamp | undefined)
      ?.toMillis();

    eligible.push({
      driverId: position.driverId,
      position: point,
      distanceM: Math.round(distanceMeters(point, pickup)),
      rating: (driver['rating'] as number | undefined) ?? 4.5,
      idleMinutes: lastOnline ? (now - lastOnline) / 60000 : 0,
      truckId: driver['assignedTruckId'] as string | undefined,
      name: (driver['name'] as string | undefined) ?? '',
      phone: (driver['phone'] as string | undefined) ?? '',
    });
  }

  return scoreCandidates(eligible, radiusKm, config);
}

/**
 * Offers the service to the next best chofer, or gives up.
 *
 * Idempotent: safe to call twice, and safe to call on a service that has since
 * been taken or cancelled — it reads the current state and returns.
 *
 * [options.preferredDriverId] is the truck the customer picked on the map. It
 * gets the first offer if it can take the job — online, free, the right type
 * and within dispatch's widest radius — and otherwise changes nothing. Either
 * way the cascade after it is the usual one.
 */
export async function dispatchNext(
  serviceId: string,
  options: { preferredDriverId?: string } = {},
): Promise<void> {
  const config = await loadDispatchConfig();
  const snap = await Paths.service(serviceId).get();
  const service = snap.data();

  if (!service) {
    logger.warn('dispatch.serviceGone', { serviceId });
    return;
  }

  if (service['status'] !== ServiceStatus.pendingDispatch) {
    // Somebody accepted, or the customer cancelled, between the trigger and
    // here. Not an error — this function is deliberately re-entrant.
    logger.debug('dispatch.notPending', { serviceId, status: service['status'] });
    return;
  }

  const dispatch = (service['dispatch'] ?? {}) as Record<string, unknown>;
  const round = (dispatch['round'] as number | undefined) ?? 0;
  const offeredTo = (dispatch['offeredTo'] as string[] | undefined) ?? [];
  const rejectedBy = (dispatch['rejectedBy'] as string[] | undefined) ?? [];
  const excluded = new Set([...offeredTo, ...rejectedBy]);

  const createdAt = (service['createdAt'] as FirebaseFirestore.Timestamp | undefined)?.toMillis();
  const now = Date.now();
  const elapsedMs = createdAt ? now - createdAt : 0;

  const pickup = service['pickup'] as { geo: FirebaseFirestore.GeoPoint };
  const center: LatLng = {
    latitude: pickup.geo.latitude,
    longitude: pickup.geo.longitude,
  };
  const truckType = service['truckTypeRequired'] as TruckType;
  const paymentMethod =
    ((service['payment'] as Record<string, unknown> | undefined)?.['method'] as string) ??
    'cash';

  // Expand until somebody is found or the radius runs out: 5 → 10 → 20 → 40.
  let radiusKm = (dispatch['radiusKm'] as number | undefined) ?? config.startRadiusKm;
  let candidates: Candidate[] = [];

  // The truck the customer asked for goes first, if it still can. Looked for
  // at the widest radius: the customer chose it knowing how far it was.
  const preferred = options.preferredDriverId;
  if (preferred && !excluded.has(preferred)) {
    const wide = await findCandidates({
      pickup: center,
      radiusKm: config.maxRadiusKm,
      truckType,
      excluded,
      paymentMethod,
      config,
      now,
    });
    const match = wide.find((c) => c.driverId === preferred);
    if (match) candidates = [match];
    logger.info('dispatch.preferred', { serviceId, available: Boolean(match) });
  }

  while (candidates.length === 0 && radiusKm <= config.maxRadiusKm) {
    candidates = await findCandidates({
      pickup: center,
      radiusKm,
      truckType,
      excluded,
      paymentMethod,
      config,
      now,
    });
    if (candidates.length === 0) radiusKm *= 2;
  }

  logger.info('dispatch.round', {
    serviceId,
    round,
    radiusKm,
    candidateCount: candidates.length,
    chosenDriverId: candidates[0]?.driverId,
    elapsedMs,
  });

  if (candidates.length === 0) {
    const exhausted = round >= config.maxRounds || elapsedMs > config.maxDispatchMs;

    if (exhausted) {
      await giveUp(serviceId, service, round, elapsedMs);
      return;
    }

    // Radius is maxed but there is time left — somebody may come online.
    await Paths.service(serviceId).update({
      'dispatch.radiusKm': config.maxRadiusKm,
      'dispatch.round': round + 1,
      updatedAt: FieldValue.serverTimestamp(),
    });
    await enqueueOfferExpiry({
      serviceId,
      driverId: '',
      round: round + 1,
      delayMs: config.retryDelayMs,
    });
    return;
  }

  const chosen = candidates[0]!;
  const expiresAt = new Date(now + config.offerTtlMs);
  const pricing = await loadPricing();
  const quote = (service['quote'] ?? {}) as Record<string, unknown>;
  const gross = (quote['totalCents'] as number | undefined) ?? 0;

  let created = false;

  // The transaction is the whole safety mechanism: it re-reads the status, so a
  // service accepted or cancelled a moment ago cannot get a second live offer.
  await db.runTransaction(async (transaction) => {
    const fresh = await transaction.get(Paths.service(serviceId));
    const current = fresh.data();
    if (!current || current['status'] !== ServiceStatus.pendingDispatch) return;

    const currentOffered =
      ((current['dispatch'] as Record<string, unknown> | undefined)?.['offeredTo'] as
        | string[]
        | undefined) ?? [];
    if (currentOffered.includes(chosen.driverId)) return;

    transaction.set(Paths.offer(serviceId, chosen.driverId), {
      state: OfferState.sent,
      round,
      sentAt: FieldValue.serverTimestamp(),
      expiresAt: Timestamp.fromDate(expiresAt),
      distanceMeters: chosen.distanceM,
      etaSeconds: Math.round((chosen.distanceM / 1000 / 28) * 3600),
      serviceCode: (current['code'] as string | undefined) ?? '',
      pickupAddress:
        ((current['pickup'] as Record<string, unknown>)['address'] as string) ?? '',
      pickupReference:
        ((current['pickup'] as Record<string, unknown>)['reference'] as string) ?? '',
      dropoffAddress:
        ((current['dropoff'] as Record<string, unknown> | undefined)?.['address'] as string) ??
        '',
      pickupGeo: (current['pickup'] as Record<string, unknown>)['geo'],
      // The chofer cannot read the service until they accept, so the offer
      // carries both ends: the app draws the whole trip before they decide.
      dropoffGeo:
        ((current['dropoff'] as Record<string, unknown> | undefined)?.['geo'] as unknown) ??
        null,
      vehicleLabel: vehicleLabel(current['vehicle']),
      condition:
        ((current['vehicle'] as Record<string, unknown> | undefined)?.['condition'] as string) ??
        '',
      truckType,
      paymentMethod,
      grossCents: gross,
      // Take-home, not gross. A chofer working out the commission in their head
      // at the roadside declines.
      netEarningsCents: gross - commissionCents(pricing, gross),
      driverId: chosen.driverId,
    });

    transaction.update(Paths.service(serviceId), {
      status: ServiceStatus.offered,
      'dispatch.radiusKm': radiusKm,
      'dispatch.round': round,
      'dispatch.offeredTo': FieldValue.arrayUnion(chosen.driverId),
      'dispatch.lastOfferAt': FieldValue.serverTimestamp(),
      'dispatch.offerExpiresAt': Timestamp.fromDate(expiresAt),
      'timeline.dispatchedAt':
        current['timeline'] && (current['timeline'] as Record<string, unknown>)['dispatchedAt']
          ? (current['timeline'] as Record<string, unknown>)['dispatchedAt']
          : FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });

    transaction.create(Paths.events(serviceId).doc(), {
      event: ServiceEventName.dispatchNext,
      from: ServiceStatus.pendingDispatch,
      to: ServiceStatus.offered,
      actorId: 'system',
      actorRole: 'system',
      meta: { driverId: chosen.driverId, round, radiusKm, distanceM: chosen.distanceM },
      at: FieldValue.serverTimestamp(),
    });

    created = true;
  });

  if (!created) {
    logger.debug('dispatch.offerRaceLost', { serviceId, driverId: chosen.driverId });
    return;
  }

  // After the commit: a push sent inside a transaction can be delivered several
  // times, because Firestore retries transactions freely.
  await sendOffer({
    driverId: chosen.driverId,
    serviceId,
    ttlSeconds: Math.round(config.offerTtlMs / 1000),
    payload: {
      round: `${round}`,
      distanceM: `${chosen.distanceM}`,
      netCents: `${gross - commissionCents(pricing, gross)}`,
    },
  });

  await enqueueOfferExpiry({
    serviceId,
    driverId: chosen.driverId,
    round,
    // A couple of seconds past the deadline, so a chofer who accepts on the
    // very last tick is not raced by their own expiry.
    delayMs: config.offerTtlMs + 2000,
  });
}

function vehicleLabel(vehicle: unknown): string {
  const v = (vehicle ?? {}) as Record<string, unknown>;
  return [v['make'], v['model'], v['year']].filter(Boolean).join(' ').trim();
}

/** Hands the service to a human. */
async function giveUp(
  serviceId: string,
  service: FirebaseFirestore.DocumentData,
  round: number,
  elapsedMs: number,
): Promise<void> {
  await applyTransition({
    serviceId,
    event: ServiceEventName.noDriversFound,
    actorId: 'system',
    actorRole: 'system',
    meta: { round, elapsedMs },
    afterCommit: async () => {
      await alertAdmins(
        'Servicio sin chofer',
        `${service['code'] ?? serviceId} lleva ${Math.round(elapsedMs / 60000)} min sin asignar.`,
        { serviceId, type: 'needs_manual' },
      );
    },
  });
}
