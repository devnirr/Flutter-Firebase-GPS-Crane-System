import { onCall } from 'firebase-functions/v2/https';
import { z } from 'zod';

import { PaymentMethod, UserRole } from '../lib/enums.js';
import { invalidArgument, permissionDenied } from '../lib/errors.js';
import { FieldValue, Paths } from '../lib/firestore.js';
import { requireAuth } from '../lib/guards.js';
import { region } from './region.js';

/**
 * Creates the customer profile on first sign-in.
 *
 * A server call rather than a client write, because the client must not decide
 * its own `role`, `blocked` or `activeServiceId` — the security rules forbid
 * creating a `users/` document at all for exactly that reason.
 *
 * The natural home for this is an Auth blocking function, which fires
 * automatically on account creation. Those require Identity Platform to be
 * enabled, so until that is turned on the client app calls this once after a
 * successful sign-in. It is idempotent, so calling it on every launch is
 * harmless.
 */
export const ensureProfile = onCall({ region, cors: true }, async (request) => {
  const parsed = z
    .object({ locale: z.string().max(10).default('es_DO') })
    .safeParse(request.data ?? {});
  if (!parsed.success) throw invalidArgument('Datos inválidos.');

  const caller = requireAuth(request);

  // A person of an insurance company works from the web panel and is billed
  // through their company. A customer profile would let them order and pay
  // for tows as a private person under the company's account.
  if (caller.role === UserRole.insurer) {
    throw permissionDenied(
      'Las cuentas de aseguradora se usan desde el panel web, no desde la app.',
    );
  }

  const ref = Paths.user(caller.uid);
  const existing = await ref.get();

  if (existing.exists) {
    return { created: false, blocked: existing.data()?.['blocked'] === true };
  }

  await ref.set({
    phone: (request.auth?.token['phone_number'] as string | undefined) ?? '',
    email: (request.auth?.token['email'] as string | undefined) ?? '',
    name: '',
    rnc: '',
    role: UserRole.client,
    locale: parsed.data.locale,
    blocked: false,
    preferredPaymentMethod: PaymentMethod.cash,
    completedServices: 0,
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  });

  return { created: true, blocked: false };
});
