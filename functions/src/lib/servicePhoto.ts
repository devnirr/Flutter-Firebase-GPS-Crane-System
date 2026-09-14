import { ACTIVE_STATUSES, type ServiceStatus } from './enums.js';

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
