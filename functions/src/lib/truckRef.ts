import { createCipheriv, createDecipheriv, createHash, randomBytes } from 'node:crypto';

import { signingSecret } from './pricing.js';

/**
 * The handle a customer holds on a nearby truck.
 *
 * "Pedir esta grúa" has to tell the server which truck was tapped, but the
 * customer must never learn who drives it — not even a stable uid, which
 * would let anyone track one truck across searches. So the driver id is
 * sealed with AES-GCM under a key only the server has: the token is opaque,
 * tamper-evident, different on every search (random IV), and dead after
 * [TRUCK_REF_TTL_MS].
 */

/** Long enough to fill in the request form; short enough to go stale. */
export const TRUCK_REF_TTL_MS = 20 * 60 * 1000;

/** Derived from the quote secret, separated by purpose, so it needs no new secret. */
function key(): Buffer {
  return createHash('sha256').update(`truck-ref|${signingSecret()}`).digest();
}

export function sealTruckRef(driverId: string, now: number = Date.now()): string {
  const iv = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', key(), iv);
  const body = Buffer.concat([
    cipher.update(JSON.stringify({ d: driverId, e: now + TRUCK_REF_TTL_MS }), 'utf8'),
    cipher.final(),
  ]);
  return Buffer.concat([iv, cipher.getAuthTag(), body]).toString('base64url');
}

/** The driver id inside [token], or null if it is forged, altered or expired. */
export function openTruckRef(token: string, now: number = Date.now()): string | null {
  try {
    const raw = Buffer.from(token, 'base64url');
    if (raw.length < 12 + 16 + 1) return null;
    const decipher = createDecipheriv('aes-256-gcm', key(), raw.subarray(0, 12));
    decipher.setAuthTag(raw.subarray(12, 28));
    const json = Buffer.concat([decipher.update(raw.subarray(28)), decipher.final()]).toString(
      'utf8',
    );
    const payload = JSON.parse(json) as { d?: unknown; e?: unknown };
    if (typeof payload.d !== 'string' || typeof payload.e !== 'number') return null;
    return payload.e < now ? null : payload.d;
  } catch {
    return null;
  }
}
