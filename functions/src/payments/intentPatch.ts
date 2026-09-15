import { PaymentStatus, ServiceEventName } from '../lib/enums.js';

/**
 * What a Stripe PaymentIntent says about a service's payment, as fields to
 * write on `services/{id}.payment`.
 *
 * Kept free of Stripe's SDK and of Firestore so the mapping — the one place a
 * wrong line means a tow towed for free or a card charged twice — is tested
 * on its own. The webhook, the app's "I just paid" sync and the capture at
 * completion all land here, so the three can never disagree.
 */

/** The parts of a PaymentIntent this reads. Stripe's object satisfies it. */
export interface IntentView {
  id: string;
  status: string;
  amount: number;
  amount_capturable: number;
  amount_received: number;
  customer: string | { id: string } | null;
  payment_method:
    | string
    | { id: string; card?: { brand?: string | null; last4?: string | null } | null }
    | null;
  last_payment_error?: { code?: string | null; message?: string | null } | null;
  metadata?: Record<string, string> | null;
}

export interface IntentOutcome {
  /** Dotted field paths under the service document, ready for `update`. */
  patch: Record<string, unknown>;
  status: PaymentStatus;
  /** The audit event this moment deserves, when it is one. */
  event: ServiceEventName | null;
  paymentMethodId: string | null;
  customerId: string | null;
}

const idOf = (value: string | { id: string } | null): string | null =>
  value === null ? null : typeof value === 'string' ? value : value.id;

/** `visa` reads as `Visa` on a receipt. */
export const brandLabel = (brand: string | null | undefined): string => {
  const raw = (brand ?? '').trim();
  if (!raw) return '';
  const names: Record<string, string> = {
    amex: 'American Express',
    mastercard: 'Mastercard',
    visa: 'Visa',
    discover: 'Discover',
    diners: 'Diners Club',
    jcb: 'JCB',
    unionpay: 'UnionPay',
  };
  return names[raw.toLowerCase()] ?? raw.charAt(0).toUpperCase() + raw.slice(1);
};

/**
 * [now] stands in for the server timestamp, so a test can compare the patch
 * whole; callers pass `FieldValue.serverTimestamp()`.
 */
export function intentOutcome(intent: IntentView, now: unknown): IntentOutcome {
  const paymentMethodId = idOf(
    intent.payment_method as string | { id: string } | null,
  );
  const card =
    intent.payment_method && typeof intent.payment_method === 'object'
      ? intent.payment_method.card
      : null;

  const patch: Record<string, unknown> = {
    'payment.gateway': 'stripe',
    'payment.intentId': intent.id,
    'payment.requiresAction': intent.status === 'requires_action',
  };
  const customerId = idOf(intent.customer);
  if (customerId) patch['payment.customerId'] = customerId;
  if (paymentMethodId) patch['payment.paymentMethodId'] = paymentMethodId;
  if (card?.last4) patch['payment.last4'] = card.last4;
  if (card?.brand) patch['payment.brand'] = brandLabel(card.brand);

  let status: PaymentStatus;
  let event: ServiceEventName | null = null;

  switch (intent.status) {
    case 'requires_capture':
      status = PaymentStatus.authorized;
      event = ServiceEventName.paymentAuthorized;
      patch['payment.authorizedCents'] = intent.amount_capturable;
      patch['payment.authorizedAt'] = now;
      patch['payment.failureCode'] = '';
      patch['payment.failureMessage'] = '';
      break;

    case 'succeeded':
      status = PaymentStatus.captured;
      event = ServiceEventName.paymentCaptured;
      patch['payment.capturedCents'] = intent.amount_received;
      patch['payment.capturedAt'] = now;
      patch['payment.failureCode'] = '';
      patch['payment.failureMessage'] = '';
      break;

    case 'canceled':
      status = PaymentStatus.voided;
      event = ServiceEventName.paymentVoided;
      patch['payment.authorizedCents'] = 0;
      break;

    case 'requires_payment_method': {
      // Either nothing tried yet, or a card that was declined and handed back
      // for another one. Only the second is a failure worth saying.
      const error = intent.last_payment_error;
      if (error) {
        status = PaymentStatus.failed;
        event = ServiceEventName.paymentFailed;
        patch['payment.failureCode'] = error.code ?? '';
        patch['payment.failureMessage'] =
          error.message ?? 'La tarjeta fue rechazada. Prueba con otra.';
      } else {
        status = PaymentStatus.none;
      }
      break;
    }

    // requires_confirmation, requires_action, processing: on its way.
    default:
      status = PaymentStatus.none;
  }

  patch['payment.status'] = status;
  return { patch, status, event, paymentMethodId, customerId };
}

/**
 * How much of a hold to charge for a finished job: the final price, but never
 * more than what was held — Stripe refuses that outright. What the hold did
 * not cover is returned as [shortfallCents] for the office to collect.
 */
export function captureAmounts(
  finalCents: number,
  authorizedCents: number,
): { captureCents: number; shortfallCents: number } {
  const captureCents = Math.max(0, Math.min(finalCents, authorizedCents));
  return { captureCents, shortfallCents: Math.max(0, finalCents - captureCents) };
}
