import { getFunctions } from 'firebase-admin/functions';
import { logger } from 'firebase-functions/v2';

/**
 * Delayed work, via Cloud Tasks.
 *
 * An offer expires at a precise `t+25s`. Cloud Scheduler cannot do that — it
 * runs at most once a minute, so a chofer would get anywhere from 25 to 85
 * seconds and the customer would wait through the difference. Cloud Tasks fires
 * at an exact instant, one task per offer.
 *
 * A scheduled sweeper still exists as a backstop (`sweepExpiredOffers`) because
 * a dropped task would otherwise leave a service parked in `offered` forever.
 * Belt and braces: the task is the mechanism, the sweep is the guarantee.
 */

/** Queue names must match the exported task-function names in index.ts. */
export const Queues = { expireOffer: 'expireOffer' } as const;

/**
 * Schedules a task-queue function.
 *
 * Under the emulator Cloud Tasks is not available, so this falls back to an
 * in-process timer. That is fine for a test and wrong for production — the
 * process can die — which is exactly why the sweeper exists.
 */
export async function enqueue(
  queue: string,
  payload: Record<string, unknown>,
  delayMs: number,
): Promise<string | undefined> {
  if (process.env.FUNCTIONS_EMULATOR === 'true') {
    logger.debug('tasks.emulatorFallback', { queue, delayMs });
    return undefined;
  }

  try {
    const enqueuer = getFunctions().taskQueue(queue);
    await enqueuer.enqueue(payload, {
      scheduleDelaySeconds: Math.max(0, Math.round(delayMs / 1000)),
      dispatchDeadlineSeconds: 60,
    });
    return `${queue}:${Date.now()}`;
  } catch (error) {
    // A failed enqueue is not fatal. The sweeper picks the offer up within a
    // minute, so the cost is latency rather than a stuck service.
    logger.error('tasks.enqueueFailed', { queue, error });
    return undefined;
  }
}

export async function enqueueOfferExpiry(options: {
  serviceId: string;
  driverId: string;
  round: number;
  delayMs: number;
}): Promise<string | undefined> {
  return enqueue(
    Queues.expireOffer,
    {
      serviceId: options.serviceId,
      driverId: options.driverId,
      round: options.round,
    },
    options.delayMs,
  );
}
