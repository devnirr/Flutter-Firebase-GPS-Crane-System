import { logger } from 'firebase-functions/v2';

import { mapsApiKey } from './secrets.js';
import type { LatLng } from './geo.js';

/** A road route, as the service document stores it. */
export interface RoadRoute {
  distanceMeters: number;
  durationSeconds: number;
  /** Google's encoded polyline, drawn by every app that shows this service. */
  polyline: string;
}

const ENDPOINT = 'https://routes.googleapis.com/directions/v2:computeRoutes';

/**
 * Long enough for a cold Routes API call, short enough that a quote does not
 * keep somebody on the shoulder waiting. A miss costs the estimate, not the
 * quote.
 */
const TIMEOUT_MS = 6000;

/**
 * Answers are reused within a function instance, keyed by the ends rounded to
 * ~100 m. A quote and the request that follows it are two calls about the same
 * trip, and instances are warm for minutes.
 */
const cache = new Map<string, RoadRoute>();

const cacheKey = (from: LatLng, to: LatLng): string =>
  `${from.latitude.toFixed(3)},${from.longitude.toFixed(3)}` +
  `>${to.latitude.toFixed(3)},${to.longitude.toFixed(3)}`;

/**
 * The road between two points, or null.
 *
 * Computed here rather than on each phone for three reasons: the key never
 * leaves the server, one call covers every screen that will ever draw this
 * tow — the customer's, the chofer's and the dispatcher's, which otherwise
 * each paid for the same line — and all three then draw exactly the same path
 * instead of three slightly different ones.
 *
 * Never throws. Without a key, with the API disabled, or with no answer in
 * time, the caller keeps the straight-line estimate it already had.
 */
export async function roadRoute(from: LatLng, to: LatLng): Promise<RoadRoute | null> {
  // Trimmed: this secret is normally set by pasting a key at an interactive
  // prompt, and a stray newline or carriage return rides along more often than
  // not. Node refuses a header value containing one, so an untrimmed key
  // throws on every call and every trip quietly falls back to the straight
  // line — the exact failure this helper exists to end.
  const key = mapsApiKey.value().trim();
  if (!key) return null;

  const cached = cache.get(cacheKey(from, to));
  if (cached) return cached;

  const waypoint = (p: LatLng) => ({
    location: { latLng: { latitude: p.latitude, longitude: p.longitude } },
  });

  try {
    const response = await fetch(ENDPOINT, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Goog-Api-Key': key,
        // Billed by field mask: only what is drawn and shown.
        'X-Goog-FieldMask':
          'routes.distanceMeters,routes.duration,routes.polyline.encodedPolyline',
      },
      body: JSON.stringify({
        origin: waypoint(from),
        destination: waypoint(to),
        travelMode: 'DRIVE',
        // Not TRAFFIC_AWARE: the same trip has to price the same at quote time
        // and again a minute later when the request lands, and a traffic-aware
        // duration is by design not stable.
        routingPreference: 'TRAFFIC_UNAWARE',
        languageCode: 'es-DO',
        units: 'METRIC',
      }),
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });

    if (!response.ok) {
      // Most often "Routes API has not been used in project … or it is
      // disabled", which is a console fix rather than a code one.
      logger.warn('routes.refused', {
        status: response.status,
        body: (await response.text()).slice(0, 300),
      });
      return null;
    }

    const body = (await response.json()) as {
      routes?: {
        distanceMeters?: number;
        duration?: string;
        polyline?: { encodedPolyline?: string };
      }[];
    };

    const route = body.routes?.[0];
    const polyline = route?.polyline?.encodedPolyline;
    if (!route || !polyline) return null;

    const answer: RoadRoute = {
      distanceMeters: Math.round(route.distanceMeters ?? 0),
      // "3600s" — seconds with a trailing s, per protobuf Duration.
      durationSeconds: Math.round(Number.parseFloat(route.duration ?? '0') || 0),
      polyline,
    };
    if (answer.distanceMeters <= 0) return null;

    cache.set(cacheKey(from, to), answer);
    return answer;
  } catch (error) {
    logger.warn('routes.unavailable', { error: String(error) });
    return null;
  }
}
