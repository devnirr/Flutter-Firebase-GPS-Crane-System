import { logger } from 'firebase-functions/v2';

import { ACTIVE_STATUSES, DriverLiveState, type ServiceStatus } from './enums.js';
import { FieldValue, Paths, db } from './firestore.js';

/**
 * Freeing a chofer whose `currentServiceId` points at a job that is over.
 *
 * Every transition that ends a job frees the chofer in the same transaction,
 * so this should find nothing. It exists because when it does find something
 * the chofer is stuck in a way nobody can see from the app: "Ocupado" on their
 * own screen with no job on it, skipped by dispatch, and refused when they try
 * to go offline — until someone edits the record by hand.
 */

/**
 * Whether [driverId] holding [service] is a leftover rather than real work:
 * the service is gone, finished, or now belongs to somebody else.
 */
export function isFinishedHold(
  driverId: string,
  service: FirebaseFirestore.DocumentData | undefined,
): boolean {
  if (!service) return true;
  if (service['driverId'] !== driverId) return true;
  return !ACTIVE_STATUSES.includes(service['status'] as ServiceStatus);
}

/**
 * Clears the chofer's hold if it is a leftover. Returns whether it did.
 *
 * Decided inside a transaction on fresh reads of both documents, so it cannot
 * race an accept: that writes the chofer and the service together, and this
 * either sees both or neither.
 */
export async function releaseIfFinished(driverId: string): Promise<boolean> {
  const driverRef = Paths.driver(driverId);
  let released: string | undefined;

  await db.runTransaction(async (transaction) => {
    // Transactions retry; only the last attempt's answer counts.
    released = undefined;

    const driver = (await transaction.get(driverRef)).data();
    const serviceId = driver?.['currentServiceId'] as string | undefined;
    if (!serviceId) return;

    const service = (await transaction.get(Paths.service(serviceId))).data();
    if (!isFinishedHold(driverId, service)) return;

    transaction.update(driverRef, {
      currentServiceId: FieldValue.delete(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    released = serviceId;
  });

  if (!released) return false;
  logger.warn('driver.releasedFromFinishedService', { driverId, serviceId: released });

  // Only an existing node: one with no position is one the map and dispatch
  // would trip over.
  const live = Paths.live(driverId);
  if ((await live.get()).exists()) {
    await live.update({ state: DriverLiveState.idle, serviceId: null, updatedAt: Date.now() });
  }
  return true;
}
