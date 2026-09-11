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
