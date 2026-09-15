import { logger } from 'firebase-functions/v2';

import { mapsApiKey } from './secrets.js';
import type { LatLng } from './geo.js';

/** A road route, as the service document stores it. */
export interface RoadRoute {
  distanceMeters: number;
  durationSeconds: number;
  /** Google's encoded polyline, drawn by every app that shows this service. */
  polyline: string;
  /**
   * The trip in driving order, as runs of city streets and open road. What the
   * tariff reads: a kilometre of autopista is priced differently from one in
   * town.
   */
  stretches: RoadStretch[];
}

/** One run of the route that is all city or all carretera. */
export interface RoadStretch {
  meters: number;
  highway: boolean;
}

/**
 * The speed at or above which a stretch counts as carretera.
 *
 * Google does not say what kind of road a step is on, but it does say how long
 * it takes without traffic: an autopista or a carretera between towns is
 * driven at 60 km/h and more, and a city street is not.
 */
export const HIGHWAY_KMH = 60;

/**
 * Turns Google's steps into city and carretera runs, in order.
 *
 * Consecutive steps of the same kind are merged: a route is dozens of steps
 * and the tariff only cares where the kind changes.
 */
export function stretchesFrom(
  steps: { distanceMeters?: number; staticDuration?: string }[],
  highwayKmh = HIGHWAY_KMH,
): RoadStretch[] {
  const runs: RoadStretch[] = [];
  for (const step of steps) {
    const meters = Math.round(step.distanceMeters ?? 0);
    if (meters <= 0) continue;
    const seconds = Number.parseFloat(step.staticDuration ?? '0') || 0;
    // No duration is no evidence of speed: priced as city, the lower rate.
    const kmh = seconds > 0 ? (meters / seconds) * 3.6 : 0;
    const highway = kmh >= highwayKmh;

    const last = runs[runs.length - 1];
    if (last && last.highway === highway) {
      last.meters += meters;
    } else {
      runs.push({ meters, highway });
    }
  }
  return runs;
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
        // The steps' distance and traffic-free duration are what split the
        // trip into city and carretera for the tariff.
        'X-Goog-FieldMask':
          'routes.distanceMeters,routes.duration,routes.polyline.encodedPolyline,' +
          'routes.legs.steps.distanceMeters,routes.legs.steps.staticDuration',
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
        legs?: { steps?: { distanceMeters?: number; staticDuration?: string }[] }[];
      }[];
    };

    const route = body.routes?.[0];
    const polyline = route?.polyline?.encodedPolyline;
    if (!route || !polyline) return null;

    const distance = Math.round(route.distanceMeters ?? 0);
    const steps = (route.legs ?? []).flatMap((leg) => leg.steps ?? []);
    let stretches = stretchesFrom(steps);
    // Steps that do not add up to the route — missing, or trimmed — would
    // price a shorter trip than the one driven. The whole distance as city is
    // the honest fallback.
    const stepped = stretches.reduce((sum, s) => sum + s.meters, 0);
    if (Math.abs(stepped - distance) > Math.max(50, distance * 0.02)) {
      stretches = [{ meters: distance, highway: false }];
    }

    const answer: RoadRoute = {
      distanceMeters: distance,
      // "3600s" — seconds with a trailing s, per protobuf Duration.
      durationSeconds: Math.round(Number.parseFloat(route.duration ?? '0') || 0),
      polyline,
      stretches,
    };
    if (answer.distanceMeters <= 0) return null;

    cache.set(cacheKey(from, to), answer);
    return answer;
  } catch (error) {
    logger.warn('routes.unavailable', { error: String(error) });
    return null;
  }
}
