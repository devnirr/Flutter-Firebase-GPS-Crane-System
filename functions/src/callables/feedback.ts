import { onCall } from 'firebase-functions/v2/https';
import { z } from 'zod';

import { CONTACT_OPEN_STATUSES, ServiceStatus } from '../lib/enums.js';
import { Code, invalidArgument, precondition } from '../lib/errors.js';
import { FieldValue, Paths } from '../lib/firestore.js';
import { requireActiveDriver, requireAuth } from '../lib/guards.js';
import { region } from './region.js';

/**
 * Rating a finished job, and the chofer's live ETA.
 *
 * Both are small, and both exist because the alternative is a client write to a
 * collection the rules deny — ratings feed a chofer's dispatch score, and the
 * tracking document is what the customer's map reads.
 */

/**
 * Rates the other party.
 *
 * The rolling average is maintained with increments rather than recomputed, so
 * a chofer with two thousand jobs does not cost two thousand reads to rate.
 * Re-rating is refused rather than overwritten: silently replacing a rating
 * would let somebody walk one back after a dispute.
 */
export const rateService = onCall({ region, cors: true }, async (request) => {
  const parsed = z
    .object({
      serviceId: z.string().min(1).max(64),
      stars: z.number().int().min(1).max(5),
      comment: z.string().max(500).nullish(),
    })
    .safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Elige entre 1 y 5 estrellas.');

  const caller = requireAuth(request);
  const { serviceId, stars, comment } = parsed.data;

  const snap = await Paths.service(serviceId).get();
  const service = snap.data();
  if (!service) throw precondition(Code.notFound, 'Este servicio ya no existe.');

  const isClient = service['clientId'] === caller.uid;
  const isDriver = service['driverId'] === caller.uid;
  if (!isClient && !isDriver) {
    throw precondition(Code.invalidTransition, 'Este servicio no es tuyo.');
  }

  // Rating a job that has not finished is rating something that has not
  // happened yet.
  const status = service['status'] as ServiceStatus;
  if (status !== ServiceStatus.completed && status !== ServiceStatus.closed) {
    throw precondition(
      Code.invalidTransition,
      'Puedes calificar cuando termine el servicio.',
    );
  }

  const field = isClient ? 'ratings.clientToDriver' : 'ratings.driverToClient';
  const ratings = (service['ratings'] ?? {}) as Record<string, unknown>;
  const existing = ratings[isClient ? 'clientToDriver' : 'driverToClient'];
  if (existing) {
    throw precondition(Code.invalidInput, 'Ya calificaste este servicio.');
  }

  await Paths.service(serviceId).update({
    [field]: { stars, comment: comment ?? '', ratedAt: FieldValue.serverTimestamp() },
    updatedAt: FieldValue.serverTimestamp(),
  });

  // Only a customer's rating of a chofer feeds the dispatch score.
  const driverId = service['driverId'] as string | undefined;
  if (isClient && driverId) {
    await Paths.driver(driverId).update({
      ratingCount: FieldValue.increment(1),
      ratingSum: FieldValue.increment(stars),
      updatedAt: FieldValue.serverTimestamp(),
    });

    // Kept denormalised so dispatch scoring does not have to divide on read.
    const driverSnap = await Paths.driver(driverId).get();
    const data = driverSnap.data() ?? {};
    const count = (data['ratingCount'] as number | undefined) ?? 1;
    const sum = (data['ratingSum'] as number | undefined) ?? stars;
    await Paths.driver(driverId).update({ rating: sum / Math.max(1, count) });
  }

  return { ok: true };
});

/**
 * Publishes the chofer's ETA for the customer's map.
 *
 * The position itself is mirrored from RTDB by a trigger; this carries the
 * estimate, which only the chofer's device can compute — it knows the remaining
 * polyline and the current speed, and recomputing that server-side would mean a
 * Routes API call every twenty seconds per active tow.
 */
export const publishEta = onCall({ region, cors: true }, async (request) => {
  const parsed = z
    .object({
      serviceId: z.string().min(1).max(64),
      etaSeconds: z.number().int().min(0).max(24 * 3600),
      remainingMeters: z.number().int().min(0).max(2_000_000),
    })
    .safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Datos inválidos.');

  const { uid } = await requireActiveDriver(request);
  const { serviceId, etaSeconds, remainingMeters } = parsed.data;

  const snap = await Paths.service(serviceId).get();
  const service = snap.data();
  if (!service) throw precondition(Code.notFound, 'Este servicio ya no existe.');
  if (service['driverId'] !== uid) {
    throw precondition(Code.invalidTransition, 'Este servicio no es tuyo.');
  }
  if (!CONTACT_OPEN_STATUSES.includes(service['status'] as ServiceStatus)) {
    // Nothing is moving, so an ETA would be a number with no meaning.
    return { ok: false };
  }

  await Paths.tracking(serviceId).set(
    { etaSeconds, remainingMeters, updatedAt: FieldValue.serverTimestamp() },
    { merge: true },
  );

  return { ok: true };
});
