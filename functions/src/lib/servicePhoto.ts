import { ACTIVE_STATUSES, type ServiceStatus } from './enums.js';

/** How many vehicle photos a request may carry — the form allows three. */
export const MAX_VEHICLE_PHOTOS = 3;

/**
 * Whether a vehicle photo on a request is one of ours: a download URL from the
 * project's own bucket.
 *
 * The chofer's app loads these as they are, so a request must not be able to
 * point it at any address on the internet.
 */
export function isVehiclePhotoUrl(value: string): boolean {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return false;
  }
  if (url.protocol === 'https:') {
    return (
      url.hostname === 'firebasestorage.googleapis.com' ||
      url.hostname.endsWith('.firebasestorage.app')
    );
  }
  // The Storage emulator, and only when running under the emulator.
  return (
    process.env['FUNCTIONS_EMULATOR'] === 'true' &&
    url.protocol === 'http:' &&
    (url.hostname === 'localhost' || url.hostname === '127.0.0.1')
  );
}

/**
 * The vehicle photos to copy onto an offer: only well-formed ones, at most
 * [MAX_VEHICLE_PHOTOS].
 */
export function vehiclePhotoUrls(vehicle: unknown): string[] {
  const photos = ((vehicle ?? {}) as Record<string, unknown>)['photoPaths'];
  if (!Array.isArray(photos)) return [];
  return photos
    .filter((p): p is string => typeof p === 'string' && isVehiclePhotoUrl(p))
    .slice(0, MAX_VEHICLE_PHOTOS);
}

/**
 * Whether a service has a chofer on it but no photo of them.
 *
 * True for services assigned by hand before `assignServiceManually` copied the
 * photo across, and for a chofer who added their photo after taking the job.
 * Only while the service is active: a finished tow's customer is not looking
 * at the card any more, and there is no reason to rewrite history.
 */
export function needsServiceDriverPhoto(service: {
  status?: unknown;
  driverId?: unknown;
  driverPhotoUrl?: unknown;
}): boolean {
  return (
    ACTIVE_STATUSES.includes(service.status as ServiceStatus) &&
    typeof service.driverId === 'string' &&
    service.driverId.length > 0 &&
    !(typeof service.driverPhotoUrl === 'string' && service.driverPhotoUrl.length > 0)
  );
}
