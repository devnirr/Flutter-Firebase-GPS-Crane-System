import { getAuth } from 'firebase-admin/auth';
import type { CallableRequest } from 'firebase-functions/v2/https';
import { onCall } from 'firebase-functions/v2/https';
import { logger } from 'firebase-functions/v2';

import { InsurerStatus, UserRole } from '../lib/enums.js';
import { Code, invalidArgument, notFound, permissionDenied, precondition } from '../lib/errors.js';
import { FieldValue, Paths } from '../lib/firestore.js';
import { requireActiveInsurer, requireAdmin, requireAuth } from '../lib/guards.js';
import {
  type MemberManager,
  canManageMembers,
  createInsurerInput,
  createInsurerUserInput,
  describeInvalidInput,
  generateTemporaryPassword,
  insurerClaims,
  memberChangeRefusal,
  updateInsurerInput,
  updateInsurerUserInput,
} from '../lib/insurers.js';
import { audit } from './admin.js';
import { region } from './region.js';

/**
 * Insurance companies and their people.
 *
 * The office opens a company and its first users. From then on the company's
 * own managers can add and remove their colleagues, but only inside their own
 * company — every call re-checks that against the member document, never
 * against the token alone. Every change writes an audit entry.
 */

/** What Auth refuses when an account is created, in words the office can act on. */
const createUserRefusals: Record<string, string> = {
  'auth/email-already-exists': 'Ya existe una cuenta con ese correo.',
  'auth/invalid-email': 'Ese correo no es válido.',
  'auth/invalid-password': 'La contraseña debe tener al menos 8 caracteres.',
};

/**
 * Resolves who is managing [insurerId]'s people, or refuses.
 *
 * An admin always may. Anyone else must be an active manager of that very
 * company, as the member document says right now.
 */
async function requireMemberManager(
  request: CallableRequest<unknown>,
  insurerId: string,
): Promise<MemberManager> {
  const caller = requireAuth(request);
  if (caller.role === UserRole.admin) return caller;
  if (caller.role !== UserRole.insurer) throw permissionDenied();

  const insurerCaller = await requireActiveInsurer(request);
  const actor: MemberManager = {
    uid: insurerCaller.uid,
    role: insurerCaller.role,
    insurerId: insurerCaller.insurerId,
    insurerRole: insurerCaller.insurerRole,
  };
  if (!canManageMembers(actor, insurerId)) throw permissionDenied();
  return actor;
}

async function assertRncFree(rnc: string, exceptInsurerId?: string): Promise<void> {
  const existing = await Paths.insurers().where('rnc', '==', rnc).limit(2).get();
  const other = existing.docs.find((doc) => doc.id !== exceptInsurerId);
  if (other) {
    throw precondition(Code.invalidInput, 'Ya existe una aseguradora con ese RNC.', {
      insurerId: other.id,
    });
  }
}

/** Opens an insurance company's account. Admin only. */
export const createInsurer = onCall({ region, cors: true }, async (request) => {
  const parsed = createInsurerInput.safeParse(request.data);
  if (!parsed.success) {
    throw invalidArgument(describeInvalidInput(parsed.error, 'Revisa los datos de la aseguradora.'));
  }

  const caller = requireAdmin(request);
  const input = parsed.data;

  await assertRncFree(input.rnc);

  const ref = Paths.insurers().doc();
  await ref.set({
    ...input,
    status: InsurerStatus.active,
    statusReason: '',
    createdBy: caller.uid,
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  });

  await audit(caller.uid, 'createInsurer', ref.id, { name: input.name, rnc: input.rnc });
  logger.info('insurer.created', { insurerId: ref.id, by: caller.uid });

  return { insurerId: ref.id };
});

/**
 * Edits a company, or suspends and reactivates it. Admin only.
 *
 * Suspending signs every one of its people out: their refresh tokens are
 * revoked, and the security rules refuse them on the next read even while an
 * already-issued token is still valid.
 */
export const updateInsurer = onCall({ region, cors: true }, async (request) => {
  const parsed = updateInsurerInput.safeParse(request.data);
  if (!parsed.success) {
    throw invalidArgument(describeInvalidInput(parsed.error, 'Revisa los datos de la aseguradora.'));
  }

  const caller = requireAdmin(request);
  const { insurerId, ...changes } = parsed.data;

  const ref = Paths.insurer(insurerId);
  const snap = await ref.get();
  if (!snap.exists) throw notFound('No encontramos esa aseguradora.');
  const before = snap.data()!;

  if (changes.rnc !== undefined && changes.rnc !== before['rnc']) {
    await assertRncFree(changes.rnc, insurerId);
  }

  const patch: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(changes)) {
    if (value !== undefined) patch[key] = value;
  }
  // Back to the default share: the field goes, rather than holding a null.
  if (changes.driverPayoutBps === null) patch['driverPayoutBps'] = FieldValue.delete();
  if (patch['status'] === InsurerStatus.active && changes.statusReason === undefined) {
    patch['statusReason'] = '';
  }
  if (Object.keys(patch).length === 0) {
    throw invalidArgument('No hay nada que cambiar.');
  }

  await ref.update({ ...patch, updatedAt: FieldValue.serverTimestamp() });

  const suspended =
    changes.status === InsurerStatus.suspended &&
    before['status'] !== InsurerStatus.suspended;
  if (suspended) {
    const members = await Paths.insurerMembers(insurerId).get();
    await Promise.all(
      members.docs.map((doc) =>
        getAuth()
          .revokeRefreshTokens(doc.id)
          .catch((error: unknown) =>
            logger.warn('insurer.revokeFailed', { insurerId, uid: doc.id, error }),
          ),
      ),
    );
  }

  await audit(caller.uid, 'updateInsurer', insurerId, { changed: Object.keys(patch) });
  logger.info('insurer.updated', { insurerId, by: caller.uid, changed: Object.keys(patch) });

  return { ok: true };
});

/**
 * Adds a person to an insurance company.
 *
 * The office can do it for any company; a company's manager only for their
 * own. Returns the first password once — the account asks for a new one on
 * first sign-in.
 */
export const createInsurerUser = onCall({ region, cors: true }, async (request) => {
  const parsed = createInsurerUserInput.safeParse(request.data);
  if (!parsed.success) {
    throw invalidArgument(describeInvalidInput(parsed.error, 'Revisa los datos del usuario.'));
  }
  const input = parsed.data;

  const actor = await requireMemberManager(request, input.insurerId);

  const insurer = await Paths.insurer(input.insurerId).get();
  if (!insurer.exists) throw notFound('No encontramos esa aseguradora.');

  const password = input.initialPassword ?? generateTemporaryPassword();

  let uid: string;
  try {
    const user = await getAuth().createUser({
      email: input.email,
      password,
      displayName: input.name,
    });
    uid = user.uid;
  } catch (error) {
    const message = createUserRefusals[(error as { code?: string }).code ?? ''];
    if (message) throw precondition(Code.invalidInput, message);
    throw error;
  }

  try {
    // Claim before document, as for a chofer. Until the document exists the
    // rules refuse this person everything, so the gap grants nothing.
    await getAuth().setCustomUserClaims(uid, insurerClaims(input.insurerId, input.insurerRole));

    await Paths.insurerMember(input.insurerId, uid).set({
      name: input.name,
      email: input.email,
      phone: input.phone,
      insurerRole: input.insurerRole,
      active: true,
      mustChangePassword: true,
      createdBy: actor.uid,
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
  } catch (error) {
    // An Auth user with no member record can do nothing and holds the email
    // hostage from a retry, so it does not outlive the failure.
    await getAuth()
      .deleteUser(uid)
      .catch(() => undefined);
    throw error;
  }

  await audit(actor.uid, 'createInsurerUser', uid, {
    insurerId: input.insurerId,
    email: input.email,
    insurerRole: input.insurerRole,
  });
  logger.info('insurer.userCreated', { insurerId: input.insurerId, uid, by: actor.uid });

  return { uid, temporaryPassword: password };
});

/**
 * Edits a person of an insurance company: their name, phone, role, or whether
 * they may sign in at all.
 *
 * Deactivating disables the Auth account and revokes its sessions. A manager
 * cannot deactivate or demote themselves.
 */
export const updateInsurerUser = onCall({ region, cors: true }, async (request) => {
  const parsed = updateInsurerUserInput.safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Revisa los datos del usuario.');
  const { insurerId, uid, ...changes } = parsed.data;

  const actor = await requireMemberManager(request, insurerId);

  // Looked up under the company named in the request, so a manager cannot
  // reach a person of another company by pairing their own id with that uid.
  const ref = Paths.insurerMember(insurerId, uid);
  const snap = await ref.get();
  if (!snap.exists) throw notFound('Ese usuario no pertenece a esta aseguradora.');
  const before = snap.data()!;

  const refusal = memberChangeRefusal(actor, uid, changes);
  if (refusal) throw precondition(Code.invalidInput, refusal);

  const patch: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(changes)) {
    if (value !== undefined) patch[key] = value;
  }
  await ref.update({ ...patch, updatedAt: FieldValue.serverTimestamp() });

  const auth = getAuth();
  if (changes.insurerRole !== undefined && changes.insurerRole !== before['insurerRole']) {
    await auth.setCustomUserClaims(uid, insurerClaims(insurerId, changes.insurerRole));
  }
  if (changes.name !== undefined) {
    await auth.updateUser(uid, { displayName: changes.name });
  }
  if (changes.active !== undefined && changes.active !== before['active']) {
    await auth.updateUser(uid, { disabled: !changes.active });
    if (!changes.active) await auth.revokeRefreshTokens(uid);
  }

  await audit(actor.uid, 'updateInsurerUser', uid, { insurerId, changed: Object.keys(patch) });
  logger.info('insurer.userUpdated', { insurerId, uid, by: actor.uid });

  return { ok: true };
});

/**
 * The signed-in person of a company has chosen their own password.
 *
 * Clears the flag the panel reads to send them to the change-password page.
 * Called by the person themselves, right after Auth accepted the new password.
 */
export const insurerPasswordChanged = onCall({ region, cors: true }, async (request) => {
  const caller = await requireActiveInsurer(request);
  await Paths.insurerMember(caller.insurerId, caller.uid).update({
    mustChangePassword: false,
    passwordChangedAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  });
  await audit(caller.uid, 'insurerPasswordChanged', caller.uid, { insurerId: caller.insurerId });
  return { ok: true };
});
