import { describe, expect, it } from 'vitest';

import { PaymentStatus, ServiceEventName } from '../src/lib/enums.js';
import { transitionFor } from '../src/lib/stateMachine.js';
import { unsettledCash } from '../src/payments/cashSettlement.js';
import {
  brandLabel,
  captureAmounts,
  intentOutcome,
  type IntentView,
} from '../src/payments/intentPatch.js';

/**
 * Paying for a tow: what Stripe's answers do to a service, how much of a hold
 * is charged, and what a chofer owes at the corte.
 */

const NOW = 'server-now';

const intent = (over: Partial<IntentView> = {}): IntentView => ({
  id: 'pi_1',
  status: 'requires_payment_method',
  amount: 575000,
  amount_capturable: 0,
  amount_received: 0,
  customer: 'cus_1',
  payment_method: null,
  last_payment_error: null,
  metadata: { serviceId: 'svc-1' },
  ...over,
});

describe('intentOutcome', () => {
  it('a hold in place authorizes the job, with the card it was made on', () => {
    const outcome = intentOutcome(
      intent({
        status: 'requires_capture',
        amount_capturable: 575000,
        payment_method: { id: 'pm_1', card: { brand: 'visa', last4: '4242' } },
      }),
      NOW,
    );

    expect(outcome.status).toBe(PaymentStatus.authorized);
    expect(outcome.event).toBe(ServiceEventName.paymentAuthorized);
    expect(outcome.paymentMethodId).toBe('pm_1');
    expect(outcome.customerId).toBe('cus_1');
    expect(outcome.patch).toMatchObject({
      'payment.status': 'authorized',
      'payment.authorizedCents': 575000,
      'payment.authorizedAt': NOW,
      'payment.intentId': 'pi_1',
      'payment.paymentMethodId': 'pm_1',
      'payment.brand': 'Visa',
      'payment.last4': '4242',
      'payment.requiresAction': false,
    });
  });

  it('succeeded is paid, for what was actually received', () => {
    const outcome = intentOutcome(
      intent({ status: 'succeeded', amount_received: 499000 }),
      NOW,
    );

    expect(outcome.status).toBe(PaymentStatus.captured);
    expect(outcome.event).toBe(ServiceEventName.paymentCaptured);
    expect(outcome.patch['payment.capturedCents']).toBe(499000);
    expect(outcome.patch['payment.capturedAt']).toBe(NOW);
  });

  it('a declined card is a failure the customer is told about', () => {
    const outcome = intentOutcome(
      intent({
        last_payment_error: { code: 'card_declined', message: 'Your card was declined.' },
      }),
      NOW,
    );

    expect(outcome.status).toBe(PaymentStatus.failed);
    expect(outcome.patch['payment.failureCode']).toBe('card_declined');
    expect(outcome.patch['payment.failureMessage']).toBe('Your card was declined.');
  });

  it('a hold not yet tried is nothing yet, not a failure', () => {
    const outcome = intentOutcome(intent(), NOW);
    expect(outcome.status).toBe(PaymentStatus.none);
    expect(outcome.event).toBeNull();
  });

  it('3-D Secure in progress says so', () => {
    const outcome = intentOutcome(intent({ status: 'requires_action' }), NOW);
    expect(outcome.status).toBe(PaymentStatus.none);
    expect(outcome.patch['payment.requiresAction']).toBe(true);
  });

  it('a released hold is voided', () => {
    const outcome = intentOutcome(intent({ status: 'canceled' }), NOW);
    expect(outcome.status).toBe(PaymentStatus.voided);
    expect(outcome.patch['payment.authorizedCents']).toBe(0);
  });

  it('reads a card method given only by id without inventing card details', () => {
    const outcome = intentOutcome(
      intent({ status: 'requires_capture', payment_method: 'pm_2' }),
      NOW,
    );
    expect(outcome.paymentMethodId).toBe('pm_2');
    expect(outcome.patch).not.toHaveProperty('payment.last4');
  });
});

describe('captureAmounts', () => {
  it('charges the final price when the hold covers it', () => {
    expect(captureAmounts(499000, 575000)).toEqual({ captureCents: 499000, shortfallCents: 0 });
  });

  it('never charges more than was held, and says what is missing', () => {
    // Stripe refuses a capture above the hold outright.
    expect(captureAmounts(620000, 575000)).toEqual({
      captureCents: 575000,
      shortfallCents: 45000,
    });
  });
});

describe('brandLabel', () => {
  it('writes the brand the way a receipt does', () => {
    expect(brandLabel('visa')).toBe('Visa');
    expect(brandLabel('amex')).toBe('American Express');
    expect(brandLabel('somethingnew')).toBe('Somethingnew');
    expect(brandLabel(null)).toBe('');
  });
});

describe('unsettledCash', () => {
  it('counts only cash collected and not yet in a corte', () => {
    const { serviceIds, totalCents } = unsettledCash([
      { id: 'a', payment: { method: 'cash', status: 'cash_collected', capturedCents: 250000 } },
      { id: 'b', payment: { method: 'cash', status: 'cash_collected', capturedCents: 180000 } },
      // Already handed in at an earlier corte.
      {
        id: 'c',
        payment: {
          method: 'cash',
          status: 'cash_collected',
          capturedCents: 90000,
          cashSettlementId: 'set-1',
        },
      },
      // Collected by nobody yet.
      { id: 'd', payment: { method: 'cash', status: 'cash_pending', capturedCents: 0 } },
      // The company already has card money.
      { id: 'e', payment: { method: 'card', status: 'captured', capturedCents: 300000 } },
    ]);

    expect(serviceIds).toEqual(['a', 'b']);
    expect(totalCents).toBe(430000);
  });
});

describe('starting a job waits on the payment', () => {
  const guard = transitionFor(ServiceEventName.startService).guard!;
  const run = (payment: Record<string, unknown>) => () =>
    guard({
      serviceId: 'svc-1',
      service: { status: 'arrived', payment },
      actorId: 'driver-1',
      actorRole: 'driver',
      meta: {},
      transaction: {} as FirebaseFirestore.Transaction,
    });

  it('refuses before the customer chooses how to pay', () => {
    expect(run({ method: 'pending', status: 'none' })).toThrow(/elegido cómo pagar/);
  });

  it('refuses a card whose hold is not in place', () => {
    expect(run({ method: 'card', status: 'none' })).toThrow(/tarjeta no está aprobado/);
    expect(run({ method: 'card', status: 'failed' })).toThrow(/tarjeta no está aprobado/);
  });

  it('lets cash start, and a card once held', () => {
    expect(run({ method: 'cash', status: 'none' })).not.toThrow();
    expect(run({ method: 'card', status: 'authorized' })).not.toThrow();
  });
});
