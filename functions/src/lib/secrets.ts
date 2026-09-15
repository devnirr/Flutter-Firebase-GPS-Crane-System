import { defineSecret } from 'firebase-functions/params';

/**
 * Secrets, declared so the runtime injects them.
 *
 * Firebase Functions v2 does not put every Secret Manager value into every
 * function's environment — a function only receives a secret it names in its
 * own options. Reading `process.env.QUOTE_SIGNING_SECRET` without that
 * declaration returns undefined in production, which is exactly the case the
 * signing code refuses to paper over.
 *
 * Set it with:
 *
 *     firebase functions:secrets:set QUOTE_SIGNING_SECRET
 *
 * Rotating it invalidates every outstanding quote, which is harmless: the
 * longest one lives ten minutes, and the app re-quotes on a mismatch.
 */
export const quoteSigningSecret = defineSecret('QUOTE_SIGNING_SECRET');

/**
 * The Maps key the server routes with.
 *
 * Separate from the one in each app's `web/index.html`: that one draws tiles in
 * a browser and is referrer-restricted, this one calls the Routes API from a
 * function and should be restricted to that API instead. Leaving it unset is
 * not an error — every route falls back to the straight-line estimate, which
 * is what the product did before.
 *
 *     firebase functions:secrets:set MAPS_API_KEY
 */
export const mapsApiKey = defineSecret('MAPS_API_KEY');

/**
 * LiveKit, for voice calls between a customer and their chofer.
 *
 * The key and secret mint room tokens and must never leave the server. The
 * URL is not secret — it is the `wss://…livekit.cloud` address both apps
 * connect to — but living next to its key means one place to set a project.
 *
 *     firebase functions:secrets:set LIVEKIT_URL
 *     firebase functions:secrets:set LIVEKIT_API_KEY
 *     firebase functions:secrets:set LIVEKIT_API_SECRET
 *
 * Unset, calls are refused with a message pointing to the chat.
 */
/**
 * Stripe, for card payments to GRUAS RD 24/7 SRL.
 *
 * The secret key moves money and never leaves the server. The webhook secret
 * (`whsec_…`) is what proves an incoming event came from Stripe; it belongs to
 * one webhook endpoint, so test mode and live mode each have their own.
 *
 *     firebase functions:secrets:set STRIPE_SECRET_KEY        # sk_test_… then sk_live_…
 *     firebase functions:secrets:set STRIPE_WEBHOOK_SECRET    # whsec_…
 *
 * Unset, choosing a card is refused with a message offering cash.
 */
export const stripeSecretKey = defineSecret('STRIPE_SECRET_KEY');
export const stripeWebhookSecret = defineSecret('STRIPE_WEBHOOK_SECRET');

export const livekitUrl = defineSecret('LIVEKIT_URL');
export const livekitApiKey = defineSecret('LIVEKIT_API_KEY');
export const livekitApiSecret = defineSecret('LIVEKIT_API_SECRET');
