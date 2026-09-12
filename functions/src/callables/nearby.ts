import { onCall } from 'firebase-functions/v2/https';
import { z } from 'zod';

import { invalidArgument } from '../lib/errors.js';
import { distanceMeters } from '../lib/geo.js';
import { requireAuth } from '../lib/guards.js';
import { isAvailableWithin, positionsWithin } from '../lib/live.js';
import { quoteSigningSecret } from '../lib/secrets.js';
import { sealTruckRef } from '../lib/truckRef.js';
import { loadDispatchConfig } from '../dispatch/dispatchNext.js';
import { region } from './region.js';

/**
 * The widest search the map offers: the whole country from anywhere in it.
 *
 * Wider than dispatch's own cascade on purpose — this answers "is there a
 * grúa anywhere near me", and one 400 km read is cheaper than a customer
 * refreshing at 40 km and concluding the service does not exist.
 */
export const MAX_NEARBY_RADIUS_KM = 400;

/** Enough to fill a map; a busy area has no use for more pins than this. */
const MAX_RESULTS = 30;

/**
 * Rounds a coordinate to three decimals, about 110 m.
 *
 * A customer sees that trucks are near, never exactly where a named chofer is
 * parked: the answer carries no identity and no position finer than a city
 * block.
 */
export const coarse = (value: number): number => Math.round(value * 1000) / 1000;

/**
 * "Grúas cerca de ti": the trucks that could take a job near the caller now.
 *
 * The customer app may not read `/live` — that is the whole fleet — so the
 * search happens here and hands back only what the map needs: rough positions,
 * the truck type and the distance, nearest first. The same rules as dispatch
 * decide who counts (online, free, reporting in the last 90 seconds), so the
 * number the customer sees is the pool their request would actually draw on.
 */
export const nearbyTrucks = onCall(
  { region, cors: true, secrets: [quoteSigningSecret] },
  async (request) => {
  const parsed = z
    .object({
      latitude: z.number().min(-90).max(90),
      longitude: z.number().min(-180).max(180),
      radiusKm: z.number().min(0.5).max(MAX_NEARBY_RADIUS_KM),
    })
    .safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Datos inválidos.');

  requireAuth(request);
  const { latitude, longitude, radiusKm } = parsed.data;
  const center = { latitude, longitude };

  const config = await loadDispatchConfig();
  const now = Date.now();
  const positions = await positionsWithin(center, radiusKm);

  const trucks = positions
    .filter((p) =>
      isAvailableWithin(p, center, radiusKm, { now, staleMs: config.stalePositionMs }),
    )
    .map((p) => ({
      latitude: coarse(p.lat),
      longitude: coarse(p.lng),
      heading: Math.round(p.heading ?? 0),
      truckType: p.truckType ?? 'unknown',
      distanceMeters: Math.round(
        distanceMeters({ latitude: p.lat, longitude: p.lng }, center),
      ),
      // What "Pedir esta grúa" sends back. Sealed: it names nobody.
      ref: sealTruckRef(p.driverId, now),
    }))
    .sort((a, b) => a.distanceMeters - b.distanceMeters)
    .slice(0, MAX_RESULTS);

  return { trucks, searchedAt: now };
  },
);
