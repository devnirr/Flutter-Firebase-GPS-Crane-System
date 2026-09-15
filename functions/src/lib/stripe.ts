import Stripe from 'stripe';

import { Code, precondition } from './errors.js';
import { stripeSecretKey } from './secrets.js';

/**
 * The Stripe client, for the functions that declared the secret.
 *
 * One charge account: GRUAS RD 24/7 SRL. No Stripe Connect — the customer pays
 * the company, and the company pays choferes by transfer each week — so no
 * call here ever names a connected account.
 */

let client: Stripe | null = null;
let clientKey = '';

export function stripe(): Stripe {
  const key = stripeSecretKey.value().trim();
  if (!key) {
    throw precondition(
      Code.paymentsNotConfigured,
      'El pago con tarjeta no está disponible ahora. Puedes pagar en efectivo.',
    );
  }
  // Rebuilt when the key changes — test to live — rather than kept for the
  // life of the instance.
  if (!client || clientKey !== key) {
    client = new Stripe(key, {
      maxNetworkRetries: 2,
      appInfo: { name: 'Gruas RD 24/7' },
    });
    clientKey = key;
  }
  return client;
}

/** Dominican pesos, in cents — the unit every amount in the system is in. */
export const CURRENCY = 'dop';

/** Test keys start `sk_test_`; the app shows a "modo prueba" label on those. */
export const isTestMode = (): boolean =>
  stripeSecretKey.value().trim().startsWith('sk_test_');
