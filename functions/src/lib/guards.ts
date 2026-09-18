import type { CallableRequest } from 'firebase-functions/v2/https';

import { DriverStatus, InsurerRole, InsurerStatus, UserRole } from './enums.js';
import { Code, permissionDenied, precondition, unauthenticated } from './errors.js';
import { Paths } from './firestore.js';

/**
 * The checks every callable runs before it does anything.
 *
 * Order matters and is always the same: App Check, then authentication, then
 * role, then input, then the business guard. Each one is cheaper than the next,
 * and each one that passes narrows what the following check has to consider.
 */

/**
 * True when App Check should be enforced.
 *
 * Off against the emulator, because the emulator has no attestation provider
 * and requiring one would make every local test fail for the wrong reason.
 *
 * Also off unless `ENFORCE_APP_CHECK` is set, and that default is deliberate.
 * No client in this project activates App Check yet, so enforcing it does not
 * raise the bar for an attacker - it simply rejects every caller, including
 * the real apps, and the whole callable surface goes dark. A check nobody can
 * satisfy protects nothing.
 *
 * Turn it on - `ENFORCE_APP_CHECK=true` - in the same change that provisions
 * App Check in the console and calls `FirebaseAppCheck.instance.activate()`
 * in the Flutter bootstrap. Not before, and not separately.
 */
const enforceAppCheck =
  process.env.FUNCTIONS_EMULATOR !== 'true' &&
  process.env.ENFORCE_APP_CHECK === 'true';

export interface Caller {
  uid: string;
  role: UserRole | undefined;
  /** Set only for people of an insurance company. */
  insurerId?: string;
  /** As the token says; `requireActiveInsurer` reads the current one. */
  insurerRole?: InsurerRole;
}

/** Rejects a request with no App Check token. */
export function requireAppCheck(request: CallableRequest<unknown>): void {
  if (!enforceAppCheck) return;
  if (request.app === undefined) {
    throw permissionDenied('No pudimos verificar la app. Actualízala desde la tienda.');
  }
}

/** Rejects an unauthenticated request and returns the caller's identity. */
export function requireAuth(request: CallableRequest<unknown>): Caller {
  requireAppCheck(request);
  const auth = request.auth;
  if (!auth) throw unauthenticated();
  const insurerId = auth.token['insurerId'];
  const insurerRole = auth.token['insurerRole'];
  return {
    uid: auth.uid,
    role: auth.token['role'] as UserRole | undefined,
    ...(typeof insurerId === 'string' && insurerId !== '' ? { insurerId } : {}),
    ...(typeof insurerRole === 'string' ? { insurerRole: insurerRole as InsurerRole } : {}),
  };
}

/** Requires one of [roles]. */
export function requireRole(
  request: CallableRequest<unknown>,
  ...roles: UserRole[]
): Caller {
  const caller = requireAuth(request);
  if (caller.role === undefined || !roles.includes(caller.role)) {
    throw permissionDenied();
  }
  return caller;
}

export function requireStaff(request: CallableRequest<unknown>): Caller {
  return requireRole(request, UserRole.admin, UserRole.ops);
}

export function requireAdmin(request: CallableRequest<unknown>): Caller {
  return requireRole(request, UserRole.admin);
}

/**
 * Requires a chofer who is currently allowed to work.
 *
 * The claim alone is not enough: an admin can suspend an account at any moment,
 * and a token minted before that is valid for up to an hour. Reading the driver
 * document costs one read and closes that window.
 */
export async function requireActiveDriver(
  request: CallableRequest<unknown>,
): Promise<Caller & { driver: FirebaseFirestore.DocumentData }> {
  const caller = requireRole(request, UserRole.driver);

  const snap = await Paths.driver(caller.uid).get();
  const driver = snap.data();
  if (!driver) throw permissionDenied('Esta cuenta no es de chofer.');

  if (driver['status'] !== DriverStatus.active) {
    throw precondition(
      Code.driverInactive,
      driver['status'] === DriverStatus.suspended
        ? 'Tu cuenta está suspendida. Comunícate con la oficina.'
        : 'Tu cuenta no está activa. Comunícate con la oficina.',
    );
  }

  return { ...caller, driver };
}

export interface InsurerCaller extends Caller {
  insurerId: string;
  /** From the member document, so a demotion takes effect at once. */
  insurerRole: InsurerRole;
  insurer: FirebaseFirestore.DocumentData;
  member: FirebaseFirestore.DocumentData;
}

/**
 * Requires a person of an insurance company who may act for it right now.
 *
 * Like `requireActiveDriver`, the claim is only the start. The company can be
 * suspended and the person deactivated while their token is still good for up
 * to an hour, so both documents are read on every call. The role returned is
 * the member document's, not the token's.
 */
export async function requireActiveInsurer(
  request: CallableRequest<unknown>,
): Promise<InsurerCaller> {
  const caller = requireRole(request, UserRole.insurer);
  const insurerId = caller.insurerId;
  if (!insurerId) throw permissionDenied('Esta cuenta no pertenece a una aseguradora.');

  const [insurerSnap, memberSnap] = await Promise.all([
    Paths.insurer(insurerId).get(),
    Paths.insurerMember(insurerId, caller.uid).get(),
  ]);
  const insurer = insurerSnap.data();
  const member = memberSnap.data();
  if (!insurer || !member) {
    throw permissionDenied('Esta cuenta no pertenece a una aseguradora.');
  }

  if (insurer['status'] !== InsurerStatus.active) {
    throw precondition(
      Code.accountSuspended,
      'La cuenta de tu aseguradora está suspendida. Comunícate con la oficina.',
    );
  }
  if (member['active'] !== true) {
    throw precondition(
      Code.accountSuspended,
      'Tu usuario está desactivado. Pide acceso al administrador de tu empresa.',
    );
  }

  return {
    ...caller,
    insurerId,
    insurerRole: member['insurerRole'] as InsurerRole,
    insurer,
    member,
  };
}

/** Requires a customer who is not blocked. */
export async function requireClient(
  request: CallableRequest<unknown>,
): Promise<Caller & { user: FirebaseFirestore.DocumentData }> {
  const caller = requireAuth(request);

  const snap = await Paths.user(caller.uid).get();
  const user = snap.data();
  if (!user) throw permissionDenied('No encontramos tu perfil.');

  if (user['blocked'] === true) {
    throw precondition(
      Code.accountBlocked,
      'Tu cuenta está bloqueada. Comunícate con soporte.',
    );
  }

  return { ...caller, user };
}

/**
 * Refuses new work while the operator has switched the system off.
 *
 * Only request-creating callables call this. A tow already under way must still
 * be able to finish — stranding a loaded vehicle because someone flipped a
 * maintenance flag would be worse than the outage it is meant to contain.
 */
export async function requireNotInMaintenance(): Promise<void> {
  const snap = await Paths.appSettings().get();
  const settings = snap.data();
  if (settings?.['maintenanceMode'] === true) {
    throw precondition(
      Code.maintenance,
      (settings['maintenanceMessage'] as string | undefined) ??
        'Estamos en mantenimiento. Vuelve en unos minutos.',
    );
  }
}
