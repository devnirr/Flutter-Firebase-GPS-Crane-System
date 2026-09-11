import { distanceKm, type LatLng } from './geo.js';
import { DriverLiveState } from './enums.js';
import { Paths } from './firestore.js';

/** A chofer's live position, as stored at `/live/{driverId}`. */
export interface LivePosition {
  driverId: string;
  lat: number;
  lng: number;
  geohash?: string;
  heading?: number;
  isOnline?: boolean;
  state?: string;
  truckType?: string;
  updatedAt?: number;
}

/**
 * Reads the online trucks that could be within [radiusKm] of [center].
 *
 * One query on the `isOnline` index, then a distance cut, rather than geohash
 * range queries. The geohash is only as good as the app build that wrote it —
 * a chofer on an older build publishes none, and a range query then misses a
 * truck parked next to the customer. `isOnline` has been written by every
 * build. For a fleet of tens to a few hundred trucks one query is also fewer
 * reads than the four to nine ranges a geohash search needs; past a few
 * thousand online at once, go back to ranges (the geohash is still written).
 *
 * Callers still filter by real distance, freshness and state.
 */
export async function positionsWithin(
  center: LatLng,
  radiusKm: number,
): Promise<LivePosition[]> {
  const snap = await Paths.liveRoot().orderByChild('isOnline').equalTo(true).get();
  const value = snap.val() as Record<string, Omit<LivePosition, 'driverId'>> | null;
  if (!value) return [];

  return Object.entries(value)
    .filter(([, p]) => typeof p?.lat === 'number' && typeof p?.lng === 'number')
    .map(([driverId, p]) => ({ driverId, ...p }))
    .filter((p) => distanceKm({ latitude: p.lat, longitude: p.lng }, center) <= radiusKm);
}

/**
 * Whether a live position is a truck that could take work right now: online,
 * not on a job, reporting recently, and truly inside the circle.
 */
export function isAvailableWithin(
  position: LivePosition,
  center: LatLng,
  radiusKm: number,
  options: { now: number; staleMs: number },
): boolean {
  if (position.isOnline !== true) return false;
  if (position.state !== DriverLiveState.idle) return false;
  // A phone that lost signal is not available, whatever `isOnline` claims.
  if (options.now - (position.updatedAt ?? 0) > options.staleMs) return false;
  return distanceKm({ latitude: position.lat, longitude: position.lng }, center) <= radiusKm;
}
