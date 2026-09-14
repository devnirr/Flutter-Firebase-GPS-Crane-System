import { logger } from 'firebase-functions/v2';

import { FieldValue, Paths } from './firestore.js';

/**
 * What happens when a chofer's app presence says it has closed.
 *
 * Called by `followAppPresence` for every write to `/presence/{driverId}`
 * that leaves `connected` false. Returns what it did, so the log and the tests
 * can tell a chofer taken offline from one left alone on purpose.
 */
export type PresenceOutcome =
  | 'reconnected'
  | 'already-offline'
  | 'mid-service'
  | 'went-offline';

export async function followPresence(driverId: string): Promise<PresenceOutcome> {
  // The trigger's event is a snapshot of the past. A dropped signal and the
  // reconnect a few seconds later are two writes, and this can run after the
  // second — so what matters is whether the app is still gone now.
  const current = (await Paths.presence(driverId).get()).val() as
    | { connected?: boolean }
    | null;
  if (current?.connected === true) return 'reconnected';

  const driverRef = Paths.driver(driverId);
  const driver = (await driverRef.get()).data();
  if (!driver || driver['isOnline'] !== true) return 'already-offline';

  // The customer is watching that truck, and `setOnline` refuses the same
  // thing for the same reason. If the phone has really gone,
  // `reapStaleDrivers` notices the silent position and tells the office.
  if (driver['currentServiceId']) {
    logger.info('presence.closedMidService', {
      driverId,
      serviceId: driver['currentServiceId'],
    });
    return 'mid-service';
  }

  await driverRef.update({
    isOnline: false,
    updatedAt: FieldValue.serverTimestamp(),
  });
  // Off the live map and out of dispatch at once, not when the stale sweep
  // gets round to it.
  await Paths.live(driverId).update({ isOnline: false, updatedAt: Date.now() });

  logger.info('presence.wentOffline', { driverId });
  return 'went-offline';
}
