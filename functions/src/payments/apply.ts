import { logger } from 'firebase-functions/v2';
import type Stripe from 'stripe';

import {
  PaymentStatus,
  ServiceEventName,
  ServiceStatus,
  type ServiceEventName as EventName,
} from '../lib/enums.js';
import { FieldValue, Paths, db } from '../lib/firestore.js';
import { alertAdmins, notify } from '../lib/push.js';
import { applyTransition } from '../lib/stateMachine.js';
import { stripe } from '../lib/stripe.js';
import { captureAmounts, intentOutcome, type IntentView } from './intentPatch.js';

/**
 * Where a PaymentIntent's news reaches the service.
 *
 * Three roads lead here: Stripe's webhook, the app asking right after the
 * customer paid (so the chofer is not left waiting on a webhook in test mode),
 * and our own capture at completion. The same intent arriving by two of them
 * writes the same fields twice, which is harmless.
 */

/**
 * An entry in the service's event log that does not move its status.
 *
 * Awaited by every caller: a function instance may be frozen the moment it
 * responds, and an unawaited write is then simply lost from the audit trail.
 */
export async function paymentEvent(
  serviceId: string,
  event: EventName,
  meta: Record<string, unknown>,
  actorId = 'system',
  actorRole = 'system',
): Promise<void> {
  try {
    await Paths.events(serviceId).doc().set({
      event,
      from: '',
      to: '',
      actorId,
      actorRole,
      meta,
      at: FieldValue.serverTimestamp(),
    });
  } catch (error) {
    // The payment itself already stands; only its log line is missing.
    logger.error('payments.eventNotLogged', { serviceId, event, error: String(error) });
  }
}

/** The card's brand and last four, which the intent only carries by id. */
async function withCard(intent: Stripe.PaymentIntent): Promise<IntentView> {
  const view = intent as unknown as IntentView;
  if (typeof intent.payment_method !== 'string') return view;
  if (intent.status !== 'requires_capture' && intent.status !== 'succeeded') return view;
  try {
    const method = await stripe().paymentMethods.retrieve(intent.payment_method);
    return { ...view, payment_method: method as unknown as IntentView['payment_method'] };
  } catch (error) {
    logger.warn('payments.cardDetailsUnavailable', { intentId: intent.id, error: String(error) });
    return view;
  }
}

/**
 * Writes what [intent] says onto its service, and closes a finished job once
 * its card is charged. Ignores an intent that is not the service's current one
 * — a hold replaced after the customer switched cards.
 */
export async function applyIntent(intent: Stripe.PaymentIntent): Promise<void> {
  const serviceId = intent.metadata?.['serviceId'];
  if (!serviceId) {
    logger.info('payments.intentWithoutService', { intentId: intent.id });
    return;
  }

  const view = await withCard(intent);
  const outcome = intentOutcome(view, FieldValue.serverTimestamp());
  const ref = Paths.service(serviceId);

  let service: FirebaseFirestore.DocumentData | undefined;
  let changed = false;

  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    service = snap.data();
    if (!service) return;

    const payment = (service['payment'] ?? {}) as Record<string, unknown>;
    if (payment['intentId'] !== intent.id) {
      logger.info('payments.staleIntent', {
        serviceId,
        intentId: intent.id,
        current: payment['intentId'] ?? null,
      });
      return;
    }
    // A charged card is final. A late "authorized" from a webhook retried out
    // of order must not walk it back.
    if (
      payment['status'] === PaymentStatus.captured &&
      outcome.status !== PaymentStatus.captured
    ) {
      return;
    }

    changed = payment['status'] !== outcome.status;
    tx.update(ref, { ...outcome.patch, updatedAt: FieldValue.serverTimestamp() });

    // The card stays on the customer's Stripe profile for the next job, and
    // for charging without them present later — the insurers' monthly bill.
    const clientId = service['clientId'] as string | undefined;
    if (
      clientId &&
      outcome.paymentMethodId &&
      (outcome.status === PaymentStatus.authorized ||
        outcome.status === PaymentStatus.captured)
    ) {
      tx.set(
        Paths.user(clientId),
        {
          ...(outcome.customerId ? { gatewayCustomerId: outcome.customerId } : {}),
          defaultPaymentMethodId: outcome.paymentMethodId,
          updatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
    }
  });

  if (!service || !changed) return;

  if (outcome.event) {
    await paymentEvent(serviceId, outcome.event, {
      intentId: intent.id,
      amountCents:
        outcome.status === PaymentStatus.captured
          ? intent.amount_received
          : intent.amount_capturable || intent.amount,
    });
  }

  const clientId = service['clientId'] as string | undefined;
  const driverId = service['driverId'] as string | undefined;

  if (outcome.status === PaymentStatus.authorized && driverId) {
    await notify({
      uid: driverId,
      audience: 'driver',
      title: 'Pago con tarjeta aprobado',
      body: 'El cliente pagará con tarjeta. Ya puedes iniciar el servicio.',
      data: { serviceId, type: 'payment_authorized' },
    }).catch((error: unknown) => logger.warn('payments.pushFailed', { error: String(error) }));
  }

  if (outcome.status === PaymentStatus.failed && clientId) {
    await notify({
      uid: clientId,
      audience: 'client',
      title: 'No pudimos procesar tu tarjeta',
      body: 'Prueba con otra tarjeta o paga en efectivo.',
      data: { serviceId, type: 'payment_failed' },
    }).catch((error: unknown) => logger.warn('payments.pushFailed', { error: String(error) }));
  }

  // Charged: the job is paid, and a completed one is over.
  if (outcome.status === PaymentStatus.captured) {
    await closeIfCompleted(serviceId, { intentId: intent.id, paid: true });
    if (clientId) {
      await notify({
        uid: clientId,
        audience: 'client',
        title: 'Pago recibido',
        body: `Cobramos RD$ ${(intent.amount_received / 100).toFixed(2)} a tu tarjeta. ¡Gracias!`,
        data: { serviceId, type: 'payment_captured' },
      }).catch((error: unknown) => logger.warn('payments.pushFailed', { error: String(error) }));
    }
  }
}

/** Moves a completed job to closed. Quiet when it already moved on. */
async function closeIfCompleted(
  serviceId: string,
  meta: Record<string, unknown>,
): Promise<void> {
  const snap = await Paths.service(serviceId).get();
  if (snap.get('status') !== ServiceStatus.completed) return;
  try {
    await applyTransition({
      serviceId,
      event: ServiceEventName.closeService,
      actorId: 'system',
      actorRole: 'system',
      meta,
    });
  } catch (error) {
    // Closed a moment ago by the other road here.
    logger.info('payments.closeSkipped', { serviceId, error: String(error) });
  }
}

/**
 * Charges the hold for a finished card job: the final price, capped at what
 * was held.
 *
 * Whatever happens the job is closed afterwards, so the chofer is never stuck
 * on a screen waiting for money that is now the office's to chase. A failed
 * or short capture is flagged for review and the office is told.
 */
export async function captureForService(serviceId: string): Promise<void> {
  const service = (await Paths.service(serviceId).get()).data();
  if (!service) return;

  const payment = (service['payment'] ?? {}) as Record<string, unknown>;
  const intentId = payment['intentId'] as string | undefined;
  const finalCents =
    ((service['final'] as Record<string, unknown> | undefined)?.['totalCents'] as number) ??
    ((service['quote'] as Record<string, unknown> | undefined)?.['totalCents'] as number) ??
    0;
  const code = (service['code'] as string | undefined) ?? serviceId;

  const flag = async (message: string, extra: Record<string, unknown> = {}) => {
    await Paths.service(serviceId).update({
      needsReview: true,
      'payment.failureMessage': message,
      ...extra,
      updatedAt: FieldValue.serverTimestamp(),
    });
    await alertAdmins('Cobro con tarjeta pendiente', `${code}: ${message}`, {
      serviceId,
      type: 'payment_review',
    }).catch(() => undefined);
  };

  if (!intentId || payment['status'] !== PaymentStatus.authorized) {
    await flag('El servicio terminó sin una tarjeta retenida.', {
      'payment.status': PaymentStatus.failed,
    });
    await closeIfCompleted(serviceId, { paid: false, reason: 'no_hold' });
    return;
  }

  const { captureCents, shortfallCents } = captureAmounts(
    finalCents,
    (payment['authorizedCents'] as number | undefined) ?? 0,
  );

  try {
    const captured = await stripe().paymentIntents.capture(
      intentId,
      { amount_to_capture: captureCents },
      // The same capture, however many times completion is retried.
      { idempotencyKey: `capture-${serviceId}-${intentId}` },
    );
    await applyIntent(captured);
    if (shortfallCents > 0) {
      await flag(
        `La retención no cubrió el total. Faltan RD$ ${(shortfallCents / 100).toFixed(2)}.`,
        { 'payment.shortfallCents': shortfallCents },
      );
    }
  } catch (error) {
    const message =
      error instanceof Error && error.message
        ? error.message
        : 'Stripe no pudo cobrar la tarjeta.';
    logger.error('payments.captureFailed', { serviceId, intentId, error: message });
    await paymentEvent(serviceId, ServiceEventName.paymentFailed, {
      intentId,
      stage: 'capture',
    });
    await flag(message, { 'payment.status': PaymentStatus.failed });
    await closeIfCompleted(serviceId, { paid: false, reason: 'capture_failed' });
  }
}

/**
 * Lets go of a card hold that will not be charged — the job was cancelled,
 * or the customer switched to cash. When [feeCents] is owed and the hold is in
 * place, that much is charged instead and the rest released.
 */
export async function releaseHold(
  serviceId: string,
  intentId: string,
  feeCents = 0,
): Promise<void> {
  try {
    const intent = await stripe().paymentIntents.retrieve(intentId);
    if (intent.status === 'succeeded' || intent.status === 'canceled') return;

    if (feeCents > 0 && intent.status === 'requires_capture') {
      const charged = await stripe().paymentIntents.capture(
        intentId,
        { amount_to_capture: Math.min(feeCents, intent.amount_capturable) },
        { idempotencyKey: `cancel-fee-${serviceId}-${intentId}` },
      );
      await applyIntent(charged);
      return;
    }

    const cancelled = await stripe().paymentIntents.cancel(
      intentId,
      {},
      { idempotencyKey: `release-${serviceId}-${intentId}` },
    );
    await applyIntent(cancelled);
  } catch (error) {
    // An uncaptured hold lapses on its own within days; the office can also
    // release it from the Stripe dashboard.
    logger.error('payments.releaseFailed', { serviceId, intentId, error: String(error) });
  }
}
