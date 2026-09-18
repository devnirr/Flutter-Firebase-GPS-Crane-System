import { onSchedule } from 'firebase-functions/v2/scheduler';
import { logger } from 'firebase-functions/v2';

import { releaseIfFinished } from '../lib/driverRelease.js';
import {
  OfferState,
  OperatorReviewState,
  PaymentStatus,
  ServiceEventName,
  ServiceStatus,
} from '../lib/enums.js';
import { FieldValue, Paths, Timestamp } from '../lib/firestore.js';
import { alertAdmins } from '../lib/push.js';
import { applyTransition } from '../lib/stateMachine.js';
import { loadDispatchConfig } from '../dispatch/dispatchNext.js';
import { expireOffer } from '../dispatch/offers.js';
import { region } from '../callables/region.js';

/**
 * The safety nets.
 *
 * Neither of these is the mechanism for anything — offers expire by Cloud Task,
 * and choferes go offline by pressing a switch. They exist because both of those
 * can fail silently, and the failure mode is a customer waiting forever on a
 * screen that says "buscando grúa".
 */

/**
 * Force-expires offers whose Cloud Task never fired.
 *
 * Every minute, which is why the task exists at all: a minute of slack on a
 * offer would multiply the customer's wait. This only catches the cases
 * where the task was dropped, the enqueue failed, or the function crashed
 * mid-cascade.
 *
 * The ten-second grace stops this racing the task itself for offers that are
 * expiring right now.
 */
export const sweepExpiredOffers = onSchedule(
  { schedule: 'every 1 minutes', region, timeZone: 'America/Santo_Domingo' },
  async () => {
    const cutoff = Timestamp.fromMillis(Date.now() - 10000);

    const stuck = await Paths.services()
      .where('status', '==', ServiceStatus.offered)
      .where('dispatch.offerExpiresAt', '<', cutoff)
      .limit(50)
      .get();

    if (stuck.empty) return;

    logger.warn('sweep.expiredOffers', { count: stuck.size });

    for (const doc of stuck.docs) {
      const offeredTo =
        ((doc.data()['dispatch'] as Record<string, unknown>)['offeredTo'] as
          | string[]
          | undefined) ?? [];
      const driverId = offeredTo[offeredTo.length - 1];
      if (!driverId) continue;

      try {
        await expireOffer({ serviceId: doc.id, driverId });
      } catch (error) {
        // One bad service must not stop the sweep for the other forty-nine.
        logger.error('sweep.expireFailed', { serviceId: doc.id, error });
      }
    }
  },
);

/**
 * Takes choferes offline when their phone stops reporting.
 *
 * A truck whose last fix is minutes old is not dispatchable — the phone lost
 * signal, the app was killed, or the battery optimiser stopped the foreground
 * service. Dispatch already filters on staleness, so this is about the *panel*:
 * a dispatcher looking at a green marker that has not moved in ten minutes is
 * being lied to.
 *
 * If such a chofer is holding a job, that is a real operational problem and the
 * office needs to know rather than find out from the customer.
 */
export const reapStaleDrivers = onSchedule(
  { schedule: 'every 2 minutes', region, timeZone: 'America/Santo_Domingo' },
  async () => {
    const config = await loadDispatchConfig();
    // More generous than the dispatch filter: this changes stored state, so it
    // should only fire when the phone is properly gone, not briefly in a tunnel.
    const cutoff = Date.now() - Math.max(config.stalePositionMs * 3, 300000);

    const snap = await Paths.liveRoot().orderByChild('isOnline').equalTo(true).get();
    const all = (snap.val() as Record<string, Record<string, unknown>> | null) ?? {};

    // The other way to be stale: switched on, but no position ever arrived —
    // location permission refused, or no GPS on the device. Nothing under
    // `/live` says online for them, so the pass below would never see them,
    // and the panel would show them "En línea" indefinitely. Judged on
    // `lastOnlineAt`, so a chofer who just switched on has the same grace to
    // get a first fix as a moving one has between fixes.
    const switchedOn = await Paths.drivers().where('isOnline', '==', true).get();
    for (const doc of switchedOn.docs) {
      if (all[doc.id]) continue;
      const since = (doc.get('lastOnlineAt') as FirebaseFirestore.Timestamp | undefined)
        ?.toMillis() ?? 0;
      if (since >= cutoff) continue;
      logger.warn('reap.silentDriver', { driverId: doc.id });
      await doc.ref.update({ isOnline: false, updatedAt: FieldValue.serverTimestamp() });
    }

    const stale = Object.entries(all).filter(
      ([, position]) => ((position['updatedAt'] as number | undefined) ?? 0) < cutoff,
    );
    if (stale.length === 0) return;

    logger.warn('reap.staleDrivers', { count: stale.length });

    for (const [driverId, position] of stale) {
      await Paths.live(driverId).update({ isOnline: false, updatedAt: Date.now() });
      await Paths.driver(driverId).update({
        isOnline: false,
        updatedAt: FieldValue.serverTimestamp(),
      });

      const serviceId = position['serviceId'] as string | undefined;
      if (serviceId) {
        await alertAdmins(
          'Chofer sin señal en servicio',
          'Un chofer con un servicio activo dejó de reportar su ubicación.',
          { driverId, serviceId, type: 'driver_stale' },
        );
      }
    }
  },
);

/**
 * Frees choferes still marked busy with a job that is over.
 *
 * Nothing should leave one behind, but a chofer who is left behind cannot get
 * out on their own: "Ocupado" with an empty screen, never offered work, and
 * refused when they try to go offline.
 */
export const releaseFinishedDrivers = onSchedule(
  { schedule: 'every 5 minutes', region, timeZone: 'America/Santo_Domingo' },
  async () => {
    const holding = await Paths.drivers()
      .where('currentServiceId', '!=', null)
      .limit(200)
      .get();

    let released = 0;
    for (const doc of holding.docs) {
      try {
        if (await releaseIfFinished(doc.id)) released++;
      } catch (error) {
        // One bad record must not stop the sweep for the rest.
        logger.error('sweep.releaseFailed', { driverId: doc.id, error });
      }
    }
    if (released > 0) logger.warn('sweep.releasedDrivers', { count: released });
  },
);

/** How long a heavy job may wait for the operator before it is given up on. */
const HEAVY_REVIEW_WINDOW_MS = 6 * 60 * 60 * 1000;

/**
 * Gives up on services nobody ever took.
 *
 * `needs_manual` means a dispatcher was asked to intervene. If nobody has after
 * an hour, the customer has long since called someone else, and leaving the
 * service open distorts every queue and report it appears in.
 */
export const expireAbandonedServices = onSchedule(
  { schedule: 'every 30 minutes', region, timeZone: 'America/Santo_Domingo' },
  async () => {
    const cutoff = Timestamp.fromMillis(Date.now() - 60 * 60 * 1000);

    const abandoned = await Paths.services()
      .where('status', '==', ServiceStatus.needsManual)
      .where('createdAt', '<', cutoff)
      .limit(50)
      .get();

    if (abandoned.empty) return;

    let expired = 0;
    for (const doc of abandoned.docs) {
      // A heavy job counts from when the operator confirmed it, and one still
      // waiting on the operator gets longer: confirming means calling the
      // customer and finding a heavy grúa, which is not a five-minute job.
      const review = doc.data()['operatorReview'] as Record<string, unknown> | undefined;
      const confirmedAt = (review?.['confirmedAt'] as FirebaseFirestore.Timestamp | undefined)
        ?.toMillis();
      if (confirmedAt && confirmedAt > cutoff.toMillis()) continue;
      const createdAt = (doc.data()['createdAt'] as FirebaseFirestore.Timestamp).toMillis();
      if (
        review?.['state'] === OperatorReviewState.pending &&
        createdAt > Date.now() - HEAVY_REVIEW_WINDOW_MS
      ) {
        continue;
      }
      expired++;

      await doc.ref.update({
        status: ServiceStatus.expired,
        updatedAt: FieldValue.serverTimestamp(),
      });
      await Paths.events(doc.id).add({
        event: 'failService',
        from: ServiceStatus.needsManual,
        to: ServiceStatus.expired,
        actorId: 'system',
        actorRole: 'system',
        meta: { reason: 'abandoned' },
        at: FieldValue.serverTimestamp(),
      });

      const clientId = doc.data()['clientId'] as string | undefined;
      if (clientId) {
        await Paths.user(clientId).update({
          activeServiceId: FieldValue.delete(),
        });
      }
    }

    if (expired > 0) logger.warn('sweep.abandonedServices', { count: expired });
  },
);

/** Marks any offer document left dangling, so the panel does not show it open. */
export const tidyOrphanedOffers = onSchedule(
  { schedule: 'every 24 hours', region, timeZone: 'America/Santo_Domingo' },
  async () => {
    const cutoff = Timestamp.fromMillis(Date.now() - 24 * 60 * 60 * 1000);

    const stale = await Paths.services()
      .where('status', 'in', [ServiceStatus.closed, ServiceStatus.cancelled])
      .where('updatedAt', '<', cutoff)
      .limit(100)
      .get();

    for (const doc of stale.docs) {
      const offers = await Paths.offers(doc.id)
        .where('state', '==', OfferState.sent)
        .get();
      for (const offer of offers.docs) {
        await offer.ref.update({ state: OfferState.cancelled });
      }
    }
  },
);

/** How long a finished insurer tow may wait for its automatic close. */
const INSURER_CLOSE_GRACE_MS = 2 * 60 * 1000;

/**
 * Closes insurer tows left at `completed`.
 *
 * `completeService` closes them right after the chofer finishes, outside its
 * transaction. If that one write fails, the job stays active: the chofer's
 * app stays on it, and the claim cannot be ordered again. This finishes the
 * job for them. The tow is already waiting for its invoice either way.
 */
export const closeFinishedInsurerTows = onSchedule(
  { schedule: 'every 5 minutes', region, timeZone: 'America/Santo_Domingo' },
  async () => {
    const left = await Paths.services()
      .where('status', '==', ServiceStatus.completed)
      .where('payment.status', '==', PaymentStatus.toInvoice)
      .limit(100)
      .get();

    let closed = 0;
    for (const doc of left.docs) {
      const completedAt = (doc.get('timeline.completedAt') as FirebaseFirestore.Timestamp | undefined)
        ?.toMillis();
      if (completedAt && Date.now() - completedAt < INSURER_CLOSE_GRACE_MS) continue;
      try {
        await applyTransition({
          serviceId: doc.id,
          event: ServiceEventName.closeService,
          actorId: 'system',
          actorRole: 'system',
          meta: { reason: 'insurer_billed', sweep: true },
        });
        await releaseIfFinished(doc.get('driverId') as string);
        closed++;
      } catch (error) {
        logger.error('sweep.insurerCloseFailed', { serviceId: doc.id, error });
      }
    }
    if (closed > 0) logger.warn('sweep.closedInsurerTows', { count: closed });
  },
);
