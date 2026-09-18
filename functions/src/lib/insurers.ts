import { randomBytes } from 'node:crypto';

import { type ZodError, z } from 'zod';

import { InsurerRole, InsurerStatus, UserRole } from './enums.js';
import { payoutBpsSchema } from './insurerService.js';

/**
 * Insurance companies as customers: who they are, and who may act for them.
 *
 * An insurance company does not pay at the roadside. It creates tows for its
 * policyholders and is billed for them at the end of the month, so everything
 * it can see is fenced to its own `insurerId`. That id travels in the custom
 * claims of each of its people, and the member document under
 * `insurers/{insurerId}/members/{uid}` is what says whether that person may
 * still act — a claim outlives a deactivation by up to an hour.
 *
 * Nothing in this file touches Firestore, so the rules it states can be tested
 * without an emulator. The callables in `callables/insurers.ts` apply them.
 */

/**
 * A Dominican RNC for a company: nine digits, the last a check digit.
 *
 * The DGII's weighting — 7, 9, 8, 6, 5, 4, 3, 2 over the first eight digits,
 * modulo 11. An insurer's RNC goes on every fiscal invoice it is sent, so a
 * typo caught here is a rejected invoice avoided at the end of the month.
 */
export function isValidCompanyRnc(raw: string): boolean {
  const digits = raw.replace(/\D/g, '');
  if (digits.length !== 9) return false;

  const weights = [7, 9, 8, 6, 5, 4, 3, 2];
  let sum = 0;
  for (let i = 0; i < 8; i++) sum += Number(digits[i]) * weights[i]!;

  const remainder = sum % 11;
  const check = remainder === 0 ? 2 : remainder === 1 ? 1 : 11 - remainder;
  return check === Number(digits[8]);
}

export const normalizeRnc = (raw: string): string => raw.replace(/\D/g, '');

const rnc = z
  .string()
  .max(20)
  .refine(isValidCompanyRnc, { message: 'RNC inválido' })
  .transform(normalizeRnc);

const phone = z.string().trim().max(20);

export const createInsurerInput = z.object({
  name: z.string().trim().min(2).max(120),
  rnc,
  contactName: z.string().trim().max(120).default(''),
  contactEmail: z.string().trim().email().max(200).or(z.literal('')).default(''),
  contactPhone: phone.default(''),
  /** Where the monthly invoice goes. */
  billingEmail: z.string().trim().email().max(200),
  /** The chofer's share of this company's tows; left out, the default 70%. */
  driverPayoutBps: payoutBpsSchema.optional(),
});

export type CreateInsurerInput = z.infer<typeof createInsurerInput>;

export const updateInsurerInput = z.object({
  insurerId: z.string().min(1).max(64),
  name: z.string().trim().min(2).max(120).optional(),
  rnc: rnc.optional(),
  contactName: z.string().trim().max(120).optional(),
  contactEmail: z.string().trim().email().max(200).or(z.literal('')).optional(),
  contactPhone: phone.optional(),
  billingEmail: z.string().trim().email().max(200).optional(),
  status: z.nativeEnum(InsurerStatus).optional(),
  statusReason: z.string().trim().max(300).optional(),
  /** `null` goes back to the default share. */
  driverPayoutBps: payoutBpsSchema.nullable().optional(),
});

export const createInsurerUserInput = z.object({
  insurerId: z.string().min(1).max(64),
  name: z.string().trim().min(2).max(120),
  email: z.string().trim().toLowerCase().email().max(200),
  phone: phone.default(''),
  insurerRole: z.nativeEnum(InsurerRole),
  // Auth's own floor is six. Left out, a strong one is generated and returned
  // once, the same way the office hands a chofer their first password.
  initialPassword: z.string().min(8).max(128).nullish(),
});

export const updateInsurerUserInput = z
  .object({
    insurerId: z.string().min(1).max(64),
    uid: z.string().min(1).max(128),
    name: z.string().trim().min(2).max(120).optional(),
    phone: phone.optional(),
    insurerRole: z.nativeEnum(InsurerRole).optional(),
    active: z.boolean().optional(),
  })
  .refine(
    (v) =>
      v.name !== undefined ||
      v.phone !== undefined ||
      v.insurerRole !== undefined ||
      v.active !== undefined,
    { message: 'Nada que cambiar' },
  );

/**
 * What to tell the office about input the callables refused.
 *
 * When several fields are wrong, the one named is the one most likely to be a
 * real mistake rather than a missing blank: a mistyped RNC matters more than a
 * short name, because the RNC ends up on a fiscal invoice.
 */
const invalidFieldMessages: ReadonlyArray<readonly [string, string]> = [
  ['rnc', 'El RNC no es válido. Debe tener 9 dígitos.'],
  ['billingEmail', 'El correo de facturación no es válido.'],
  ['email', 'El correo no es válido.'],
  ['contactEmail', 'El correo de contacto no es válido.'],
  ['initialPassword', 'La contraseña debe tener al menos 8 caracteres.'],
  ['driverPayoutBps', 'El porcentaje del chofer debe estar entre 0% y 100%.'],
  ['name', 'Escribe el nombre completo.'],
];

export function describeInvalidInput(error: ZodError, fallback: string): string {
  const fields = new Set(error.issues.map((issue) => String(issue.path[0] ?? '')));
  for (const [field, message] of invalidFieldMessages) {
    if (fields.has(field)) return message;
  }
  return fallback;
}

/** The custom claims every person of an insurance company carries. */
export function insurerClaims(
  insurerId: string,
  insurerRole: InsurerRole,
): { role: typeof UserRole.insurer; insurerId: string; insurerRole: InsurerRole } {
  return { role: UserRole.insurer, insurerId, insurerRole };
}

/**
 * Who is asking to manage a company's people.
 *
 * `insurerRole` here must come from the member document, not the token: a
 * manager demoted a minute ago still holds a token that says otherwise.
 */
export interface MemberManager {
  uid: string;
  role: UserRole | undefined;
  insurerId?: string;
  insurerRole?: InsurerRole;
}

/**
 * Whether [actor] may add, edit or deactivate people of [insurerId].
 *
 * The office can, for any company. Inside a company only its own managers can,
 * and never for somebody else's company.
 */
export function canManageMembers(actor: MemberManager, insurerId: string): boolean {
  if (actor.role === UserRole.admin) return true;
  return (
    actor.role === UserRole.insurer &&
    actor.insurerId === insurerId &&
    actor.insurerRole === InsurerRole.manager
  );
}

/**
 * Why a change to a member must be refused, or `null` when it may go ahead.
 *
 * A manager cannot demote or deactivate themselves: a company whose only
 * manager does that is locked out of its own account until the office steps
 * in. The office itself is not bound by this.
 */
export function memberChangeRefusal(
  actor: MemberManager,
  targetUid: string,
  change: { insurerRole?: InsurerRole; active?: boolean },
): string | null {
  if (actor.role === UserRole.admin || actor.uid !== targetUid) return null;
  if (change.active === false) return 'No puedes desactivar tu propio usuario.';
  if (change.insurerRole !== undefined && change.insurerRole !== InsurerRole.manager) {
    return 'No puedes quitarte el rol de administrador de tu empresa.';
  }
  return null;
}

/**
 * A first password: 16 random characters, framed so it always holds a letter
 * of each case, a digit and a symbol and passes any password policy Auth is
 * later configured with.
 */
export function generateTemporaryPassword(): string {
  const body = randomBytes(12).toString('base64url');
  return `Ts${body}7!`;
}
