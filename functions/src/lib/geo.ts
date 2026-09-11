import { geohashForLocation, geohashQueryBounds } from 'geofire-common';

/**
 * Geo maths for dispatch.
 *
 * The haversine here must agree with `LatLng.distanceTo` in
 * `packages/grua_core/lib/src/domain/value_objects.dart`: the app shows a
 * chofer how far away a job is and the server decides whether they are close
 * enough to press "Llegué", and a disagreement between those two is an argument
 * at the roadside.
 */

export interface LatLng {
  latitude: number;
  longitude: number;
}

const EARTH_RADIUS_M = 6371000;

const toRadians = (degrees: number): number => (degrees * Math.PI) / 180;

/** Great-circle distance in metres. */
export function distanceMeters(a: LatLng, b: LatLng): number {
  const dLat = toRadians(b.latitude - a.latitude);
  const dLng = toRadians(b.longitude - a.longitude);
  const h =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(toRadians(a.latitude)) *
      Math.cos(toRadians(b.latitude)) *
      Math.sin(dLng / 2) *
      Math.sin(dLng / 2);
  return EARTH_RADIUS_M * 2 * Math.atan2(Math.sqrt(h), Math.sqrt(1 - h));
}

export const distanceKm = (a: LatLng, b: LatLng): number =>
  distanceMeters(a, b) / 1000;

/** Initial bearing in degrees, 0 = north. Rotates the truck marker. */
export function bearing(a: LatLng, b: LatLng): number {
  const dLng = toRadians(b.longitude - a.longitude);
  const lat1 = toRadians(a.latitude);
  const lat2 = toRadians(b.latitude);
  const y = Math.sin(dLng) * Math.cos(lat2);
  const x =
    Math.cos(lat1) * Math.sin(lat2) -
    Math.sin(lat1) * Math.cos(lat2) * Math.cos(dLng);
  return ((Math.atan2(y, x) * 180) / Math.PI + 360) % 360;
}

export const geohash = (point: LatLng): string =>
  geohashForLocation([point.latitude, point.longitude]);

/**
 * Geohash ranges covering a radius.
 *
 * A geohash cell is a rectangle and a radius is a circle, so these bounds
 * always over-select — callers must still filter by real distance afterwards.
 * Skipping that filter is how a chofer 8 km away gets offered a job billed as
 * being 5 km out.
 */
export const queryBounds = (center: LatLng, radiusMeters: number): string[][] =>
  geohashQueryBounds([center.latitude, center.longitude], radiusMeters);

/** Rough national bounding box, used to reject nonsense coordinates early. */
export function isPlausiblyInDominicanRepublic(point: LatLng): boolean {
  return (
    point.latitude >= 17.4 &&
    point.latitude <= 20.1 &&
    point.longitude >= -72.1 &&
    point.longitude <= -68.2
  );
}

/**
 * Ray-casting point-in-polygon.
 *
 * Coverage zones are drawn by hand in the admin panel, so they are small and
 * simple; an unclosed or two-point polygon contains nothing rather than
 * throwing.
 */
export function isInsidePolygon(point: LatLng, polygon: LatLng[]): boolean {
  if (polygon.length < 3) return false;

  let inside = false;
  for (let i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    const pi = polygon[i]!;
    const pj = polygon[j]!;
    const crosses =
      pi.longitude > point.longitude !== pj.longitude > point.longitude &&
      point.latitude <
        ((pj.latitude - pi.latitude) * (point.longitude - pi.longitude)) /
          (pj.longitude - pi.longitude) +
          pi.latitude;
    if (crosses) inside = !inside;
  }
  return inside;
}

/**
 * Straight-line distance inflated to approximate a road route.
 *
 * A stand-in for the Routes API on paths where a real call is not worth its
 * latency or its price — 1.35 is the usual detour factor for a dense street
 * grid. Anything a customer is billed for uses the real route.
 */
export const estimatedRoadKm = (a: LatLng, b: LatLng): number =>
  distanceKm(a, b) * 1.35;
