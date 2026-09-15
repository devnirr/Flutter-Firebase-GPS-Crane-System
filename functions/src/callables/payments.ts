import { logger } from 'firebase-functions/v2';
import { onCall, onRequest } from 'firebase-functions/v2/https';
import type Stripe from 'stripe';
import { z } from 'zod';

import {
  PaymentMethod,
  PaymentStatus,
  ServiceEventName,
  ServiceStatus,
  UserRole,
} from '../lib/enums.js';
import { Code, invalidArgument, notFound, permissionDenied, precondition } from '../lib/errors.js';
import { FieldValue, Paths, db } from '../lib/firestore.js';
import { requireAuth, requireStaff } from '../lib/guards.js';
import { authorizationAmountCents, loadPricing } from '../lib/pricing.js';
import { stripeSecretKey, stripeWebhookSecret } from '../lib/secrets.js';
import { CURRENCY, isTestMode, stripe } from '../lib/stripe.js';
import { applyIntent, paymentEvent, releaseHold } from '../payments/apply.js';
import { unsettledCash, type CashJob } from '../payments/cashSettlement.js';
import { region } from './region.js';

/**
 * Paying for a tow.
 *
 * The customer pays GRUAS RD 24/7 SRL — card through Stripe, or cash to the
 * chofer, who then owes it to the company until the office makes a corte.
 * They choose when the grúa is at the curb:
 *
 * * **Tarjeta**: a hold for the quote plus headroom (a PaymentIntent with
 *   manual capture). The chofer may only start once it is in place. At
 *   "Finalizar" the final price is charged from it, Stripe confirms with
 *   `payment_intent.succeeded`, and the job is marked paid and closed. The
 *   card is saved to the customer's Stripe profile for later charges.
 * * **Efectivo**: nothing goes through Stripe. The chofer confirms
 *   "Cobrado en efectivo RD$X", the job is marked paid, and the amount is
 *   added to what they hold for the next corte.
 */

const serviceOnly = z.object({ serviceId: z.string().min(1).max(64) });

/** Before the vehicle is loaded: the only window a payment choice may change. */
const CHOOSABLE: readonly string[] = [ServiceStatus.accepted, ServiceStatus.arrived];

async function loadService(serviceId: string): Promise<FirebaseFirestore.DocumentData> {
  const service = (await Paths.service(serviceId).get()).data();
  if (!service) throw notFound('Este servicio ya no existe.');
  return service;
}

/**
 * "Pagar en efectivo" / "Pagar con tarjeta".
 *
 * The customer may pick either. The chofer may only mark cash — the customer
 * in front of them has no app, or would rather hand over notes — never card,
 * which needs the customer's own card and consent.
 */
export const choosePaymentMethod = onCall(
  { region, cors: true, secrets: [stripeSecretKey] },
  async (request) => {
    const parsed = serviceOnly
      .extend({ method: z.enum([PaymentMethod.cash, PaymentMethod.card]) })
      .safeParse(request.data);
    if (!parsed.success) throw invalidArgument('Datos inválidos.');

    const caller = requireAuth(request);
    const { serviceId, method } = parsed.data;
    const ref = Paths.service(serviceId);

    let releasedIntent: string | null = null;

    await db.runTransaction(async (tx) => {
      const service = (await tx.get(ref)).data();
      if (!service) throw notFound('Este servicio ya no existe.');

      const isClient = service['clientId'] === caller.uid;
      const isDriver = service['driverId'] === caller.uid;
      if (!isClient && !(isDriver && method === PaymentMethod.cash)) {
        throw permissionDenied('Solo el cliente puede elegir pagar con tarjeta.');
      }
      if (!CHOOSABLE.includes(service['status'] as string)) {
        throw precondition(
          Code.invalidTransition,
          'La forma de pago ya no se puede cambiar en este servicio.',
        );
      }

      const payment = (service['payment'] ?? {}) as Record<string, unknown>;
      if (payment['status'] === PaymentStatus.captured) {
        throw precondition(Code.invalidTransition, 'Este servicio ya está pagado.');
      }

      if (method === PaymentMethod.cash) {
        const intentId = payment['intentId'] as string | undefined;
        if (intentId) releasedIntent = intentId;
        tx.update(ref, {
          'payment.method': PaymentMethod.cash,
          'payment.status': PaymentStatus.none,
          // Dropped before the hold is released, so the release does not
          // write "voided" over a job that is now cash.
          'payment.intentId': null,
          'payment.authorizedCents': 0,
          'payment.requiresAction': false,
          updatedAt: FieldValue.serverTimestamp(),
        });
      } else {
        tx.update(ref, {
          'payment.method': PaymentMethod.card,
          updatedAt: FieldValue.serverTimestamp(),
        });
      }
    });

    await paymentEvent(
      serviceId,
      ServiceEventName.choosePaymentMethod,
      { method },
      caller.uid,
      caller.role ?? UserRole.client,
    );

    if (releasedIntent) {
      await paymentEvent(serviceId, ServiceEventName.paymentVoided, {
        intentId: releasedIntent,
        reason: 'switched_to_cash',
      });
      await releaseHold(serviceId, releasedIntent);
    }

    return { ok: true };
  },
);

/**
 * Everything the app's checkout needs to hold the customer's card for this
 * job: the PaymentIntent's client secret, and a session showing the cards
 * already saved on their Stripe profile.
 */
export const preparePayment = onCall(
  { region, cors: true, secrets: [stripeSecretKey] },
  async (request) => {
    const parsed = serviceOnly.safeParse(request.data);
    if (!parsed.success) throw invalidArgument('Datos inválidos.');

    const caller = requireAuth(request);
    const { serviceId } = parsed.data;
    const service = await loadService(serviceId);

    if (service['clientId'] !== caller.uid) {
      throw permissionDenied('Este servicio no es tuyo.');
    }
    if (!CHOOSABLE.includes(service['status'] as string)) {
      throw precondition(
        Code.invalidTransition,
        'Podrás pagar con tarjeta cuando el chofer esté en camino o haya llegado.',
      );
    }

    const payment = (service['payment'] ?? {}) as Record<string, unknown>;
    if (payment['status'] === PaymentStatus.authorized) {
      return { alreadyAuthorized: true, testMode: isTestMode() };
    }
    if (payment['status'] === PaymentStatus.captured) {
      throw precondition(Code.invalidTransition, 'Este servicio ya está pagado.');
    }

    const api = stripe();
    const customerId = await ensureCustomer(caller.uid, api);

    const pricing = await loadPricing();
    const quoteCents =
      ((service['quote'] as Record<string, unknown> | undefined)?.['totalCents'] as number) ?? 0;
    if (quoteCents <= 0) {
      throw precondition(Code.invalidTransition, 'Este servicio todavía no tiene precio.');
    }
    const amount = authorizationAmountCents(pricing, quoteCents);

    // The hold already started, if it is still usable: a customer who closed
    // the sheet and opens it again continues where they were.
    let intent: Stripe.PaymentIntent | null = null;
    const existingId = payment['intentId'] as string | undefined;
    if (existingId) {
      const existing = await api.paymentIntents.retrieve(existingId);
      const reusable = ['requires_payment_method', 'requires_confirmation', 'requires_action'];
      if (existing.status === 'requires_capture') {
        await applyIntent(existing);
        return { alreadyAuthorized: true, testMode: isTestMode() };
      }
      if (reusable.includes(existing.status) && existing.amount === amount) {
        intent = existing;
      } else if (reusable.includes(existing.status)) {
        await api.paymentIntents.cancel(existingId).catch(() => undefined);
      }
    }

    if (!intent) {
      intent = await api.paymentIntents.create({
        amount,
        currency: CURRENCY,
        customer: customerId,
        // Held now, charged at "Finalizar" for the final price.
        capture_method: 'manual',
        // Saved to the customer for charges without them present.
        setup_future_usage: 'off_session',
        automatic_payment_methods: { enabled: true },
        description: `Grúas RD 24/7 · Servicio ${service['code'] ?? serviceId}`,
        metadata: {
          serviceId,
          serviceCode: String(service['code'] ?? ''),
          clientId: caller.uid,
        },
      });
    }

    await Paths.service(serviceId).update({
      'payment.method': PaymentMethod.card,
      'payment.gateway': 'stripe',
      'payment.intentId': intent.id,
      'payment.customerId': customerId,
      'payment.status': PaymentStatus.none,
      updatedAt: FieldValue.serverTimestamp(),
    });

    return {
      alreadyAuthorized: false,
      clientSecret: intent.client_secret,
      customerId,
      customerSessionClientSecret: await customerSession(api, customerId),
      amountCents: amount,
      quoteCents,
      currency: CURRENCY,
      testMode: isTestMode(),
    };
  },
);

/**
 * "I just paid": reads the intent from Stripe now rather than waiting for the
 * webhook, so the chofer's "Iniciar" unlocks the moment the sheet closes.
 */
export const syncPayment = onCall(
  { region, cors: true, secrets: [stripeSecretKey] },
  async (request) => {
    const parsed = serviceOnly.safeParse(request.data);
    if (!parsed.success) throw invalidArgument('Datos inválidos.');

    const caller = requireAuth(request);
    const service = await loadService(parsed.data.serviceId);
    const isParty =
      service['clientId'] === caller.uid ||
      service['driverId'] === caller.uid ||
      caller.role === UserRole.admin ||
      caller.role === UserRole.ops;
    if (!isParty) throw permissionDenied('Este servicio no es tuyo.');

    const intentId = (service['payment'] as Record<string, unknown> | undefined)?.['intentId'];
    if (typeof intentId !== 'string' || !intentId) return { status: PaymentStatus.none };

    const intent = await stripe().paymentIntents.retrieve(intentId);
    await applyIntent(intent);
    return { status: intent.status };
  },
);

/** The customer's Stripe profile, made the first time they pay by card. */
async function ensureCustomer(uid: string, api: Stripe): Promise<string> {
  const user = (await Paths.user(uid).get()).data() ?? {};
  const existing = user['gatewayCustomerId'] as string | undefined;
  if (existing) return existing;

  const customer = await api.customers.create(
    {
      name: (user['name'] as string | undefined) || undefined,
      phone: (user['phone'] as string | undefined) || undefined,
      email: (user['email'] as string | undefined) || undefined,
      metadata: { uid },
    },
    // Two taps, one customer.
    { idempotencyKey: `customer-${uid}` },
  );
  await Paths.user(uid).set(
    { gatewayCustomerId: customer.id, updatedAt: FieldValue.serverTimestamp() },
    { merge: true },
  );
  return customer.id;
}

/**
 * Lets the checkout show and reuse the customer's saved cards. Saving is
 * always on — the intent asks for it — so the "save this card" box is not
 * offered. Without a session the checkout still works, only with no saved
 * cards listed.
 */
async function customerSession(api: Stripe, customer: string): Promise<string | null> {
  const features = {
    payment_method_redisplay: 'enabled',
    payment_method_remove: 'enabled',
    payment_method_save: 'disabled',
  } as const;
  try {
    const session = await api.customerSessions.create({
      customer,
      components: {
        mobile_payment_element: { enabled: true, features },
        payment_element: { enabled: true, features },
      },
    });
    return session.client_secret;
  } catch (error) {
    logger.warn('payments.customerSessionUnavailable', { error: String(error) });
    return null;
  }
}

/** Events that change a service's payment. Everything else is acknowledged and ignored. */
const HANDLED_EVENTS = new Set<string>([
  'payment_intent.amount_capturable_updated',
  'payment_intent.succeeded',
  'payment_intent.payment_failed',
  'payment_intent.canceled',
  'payment_intent.requires_action',
  'payment_intent.processing',
]);

/**
 * Stripe's webhook.
 *
 * Register this function's URL in the Stripe dashboard for the events above,
 * once for test mode and once for live. The signature is checked against the
 * raw body before anything is read, and every event is recorded under its id
 * so a delivery Stripe retries is applied once.
 */
export const stripeWebhook = onRequest(
  { region, secrets: [stripeSecretKey, stripeWebhookSecret] },
  async (req, res) => {
    if (req.method !== 'POST') {
      res.status(405).send('Method not allowed');
      return;
    }

    const signature = req.header('stripe-signature');
    const secret = stripeWebhookSecret.value().trim();
    if (!signature || !secret) {
      res.status(400).send('Missing signature');
      return;
    }

    let event: Stripe.Event;
    try {
      event = stripe().webhooks.constructEvent(req.rawBody, signature, secret);
    } catch (error) {
      logger.warn('stripe.badSignature', { error: String(error) });
      res.status(400).send('Invalid signature');
      return;
    }

    if (!HANDLED_EVENTS.has(event.type)) {
      res.status(200).send('ignored');
      return;
    }

    const record = Paths.webhookEvent(event.id);
    try {
      await record.create({
        gateway: 'stripe',
        type: event.type,
        livemode: event.livemode,
        receivedAt: FieldValue.serverTimestamp(),
      });
    } catch {
      // Already applied: Stripe retried a delivery we acknowledged too late.
      res.status(200).send('duplicate');
      return;
    }

    try {
      await applyIntent(event.data.object as Stripe.PaymentIntent);
      res.status(200).send('ok');
    } catch (error) {
      logger.error('stripe.webhookFailed', { eventId: event.id, error: String(error) });
      // Forget it, so Stripe's retry gets another go.
      await record.delete().catch(() => undefined);
      res.status(500).send('retry');
    }
  },
);

/**
 * The corte: the office receives the cash a chofer holds.
 *
 * Counts every cash job the chofer confirmed collecting that no earlier corte
 * counted, records them together, and marks each one so it is never counted
 * twice. Also clears the commission the chofer owed on those jobs, since the
 * company now has the whole amount.
 */
export const settleDriverCash = onCall({ region, cors: true }, async (request) => {
  const parsed = z
    .object({
      driverId: z.string().min(1).max(128),
      note: z.string().max(300).default(''),
    })
    .safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Datos inválidos.');

  const caller = requireStaff(request);
  const { driverId, note } = parsed.data;
  const settlementRef = Paths.cashSettlements().doc();

  const result = await db.runTransaction(async (tx) => {
    const driverSnap = await tx.get(Paths.driver(driverId));
    const driver = driverSnap.data();
    if (!driver) throw notFound('Chofer no encontrado.');

    const snap = await tx.get(
      Paths.services()
        .where('driverId', '==', driverId)
        .where('payment.status', '==', PaymentStatus.cashCollected)
        .limit(400),
    );
    const { serviceIds, totalCents } = unsettledCash(
      snap.docs.map((doc) => ({ id: doc.id, payment: doc.get('payment') }) as CashJob),
    );
    if (serviceIds.length === 0) {
      throw precondition(Code.invalidTransition, 'Este chofer no tiene efectivo por entregar.');
    }

    tx.create(settlementRef, {
      driverId,
      driverName: driver['name'] ?? '',
      amountCents: totalCents,
      serviceCount: serviceIds.length,
      serviceIds,
      note,
      settledBy: caller.uid,
      createdAt: FieldValue.serverTimestamp(),
    });
    for (const id of serviceIds) {
      tx.update(Paths.service(id), {
        'payment.cashSettlementId': settlementRef.id,
        'payment.cashSettledAt': FieldValue.serverTimestamp(),
      });
    }
    const onHand = (driver['cashOnHandCents'] as number | undefined) ?? 0;
    tx.update(Paths.driver(driverId), {
      cashOnHandCents: Math.max(0, onHand - totalCents),
      cashOwedCents: 0,
      lastCashSettlementAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    tx.set(
      Paths.earnings(driverId),
      { cashOwedCents: 0, updatedAt: FieldValue.serverTimestamp() },
      { merge: true },
    );

    return { totalCents, serviceCount: serviceIds.length };
  });

  logger.info('cash.settled', { driverId, by: caller.uid, ...result });
  return { settlementId: settlementRef.id, ...result };
});
