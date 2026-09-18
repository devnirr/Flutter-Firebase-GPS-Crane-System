import { afterAll, beforeAll, describe, expect, it } from 'vitest';

import { freshRnc } from './support/rnc.js';

/**
 * The insurer callables against real Firestore and Auth emulators:
 *
 *     npm run test:emulator
 *
 * These prove what the pure tests cannot: that the accounts really get the
 * claims the rules read, that a refused call leaves nothing half-made behind,
 * and that a demotion or suspension takes effect before the token expires.
 */

const describeEmulator =
  process.env['FIRESTORE_EMULATOR_HOST'] && process.env['FIREBASE_AUTH_EMULATOR_HOST']
    ? describe
    : describe.skip;

type Callables = typeof import('../src/callables/insurers.js');

interface Token {
  uid: string;
  token: Record<string, unknown>;
}

let fns: Callables;
let admin: typeof import('../src/callables/admin.js');
let profile: typeof import('../src/callables/profile.js');
let guards: typeof import('../src/lib/guards.js');
let Paths: typeof import('../src/lib/firestore.js')['Paths'];
let auth: import('firebase-admin/auth').Auth;

const createdUids: string[] = [];
const runId = Math.random().toString(36).slice(2, 8);
const email = (name: string) => `${name}.${runId}@aseguradora.test`;

const ADMIN: Token = { uid: 'admin-insurer-tests', token: { role: 'admin' } };
const OPS: Token = { uid: 'ops-insurer-tests', token: { role: 'ops' } };

/** The request shape `onCall` hands its handler. */
function request(data: unknown, who?: Token) {
  return {
    data,
    auth: who ? { uid: who.uid, token: { uid: who.uid, ...who.token } } : undefined,
    rawRequest: {},
    acceptsStreaming: false,
  } as never;
}

async function call<T>(
  fn: { run: (req: never) => T | Promise<T> },
  data: unknown,
  who?: Token,
): Promise<T> {
  return fn.run(request(data, who));
}

/** The token the person would get on their next sign-in. */
async function tokenOf(uid: string): Promise<Token> {
  const user = await auth.getUser(uid);
  return { uid, token: { ...(user.customClaims ?? {}) } };
}

async function refusal(promise: Promise<unknown>): Promise<{ code: string; message: string }> {
  try {
    await promise;
  } catch (error) {
    const e = error as { code: string; message: string };
    return { code: e.code, message: e.message };
  }
  throw new Error('expected the call to be refused');
}

/** Signs in through the Auth emulator's REST API, as the panel would. */
async function signIn(address: string, password: string): Promise<boolean> {
  const host = process.env['FIREBASE_AUTH_EMULATOR_HOST'];
  const res = await fetch(
    `http://${host}/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=fake`,
    {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ email: address, password, returnSecureToken: true }),
    },
  );
  return res.ok;
}

describeEmulator('insurer callables', () => {
  let insurerA: string;
  let insurerB: string;
  let managerA: string;
  let managerAPassword: string;
  let operatorA: string;
  let operatorB: string;

  beforeAll(async () => {
    process.env['GCLOUD_PROJECT'] ??= 'grua-rd-test';
    process.env['QUOTE_SIGNING_SECRET'] ??= 'test-secret';

    fns = await import('../src/callables/insurers.js');
    admin = await import('../src/callables/admin.js');
    profile = await import('../src/callables/profile.js');
    guards = await import('../src/lib/guards.js');
    Paths = (await import('../src/lib/firestore.js')).Paths;
    auth = (await import('firebase-admin/auth')).getAuth();
  });

  afterAll(async () => {
    if (createdUids.length > 0) await auth?.deleteUsers(createdUids);
  });

  async function newUser(
    insurerId: string,
    name: string,
    insurerRole: 'manager' | 'operator',
    who: Token = ADMIN,
  ) {
    const result = await call(
      fns.createInsurerUser,
      { insurerId, name, email: email(name), insurerRole },
      who,
    );
    createdUids.push(result.uid);
    return result;
  }

  describe('opening a company', () => {
    it('refuses an invalid RNC with a message about the RNC', async () => {
      const r = await refusal(
        call(
          fns.createInsurer,
          { name: 'Aseguradora Mal Escrita', rnc: '130000002', billingEmail: 'f@x.do' },
          ADMIN,
        ),
      );
      expect(r.code).toBe('invalid-argument');
      expect(r.message).toMatch(/RNC/);
    });

    it('refuses anyone but an admin', async () => {
      const data = { name: 'Nope', rnc: freshRnc(), billingEmail: 'f@x.do' };
      expect((await refusal(call(fns.createInsurer, data, OPS))).code).toBe('permission-denied');
      expect((await refusal(call(fns.createInsurer, data))).code).toBe('unauthenticated');
    });

    it('opens an active company with the RNC as digits', async () => {
      const rnc = freshRnc();
      const dashed = `${rnc.slice(0, 1)}-${rnc.slice(1, 3)}-${rnc.slice(3, 8)}-${rnc.slice(8)}`;
      const { insurerId } = await call(
        fns.createInsurer,
        { name: 'Aseguradora Prueba A', rnc: dashed, billingEmail: 'facturas@a.test' },
        ADMIN,
      );
      insurerA = insurerId;

      const doc = (await Paths.insurer(insurerId).get()).data()!;
      expect(doc['rnc']).toBe(rnc);
      expect(doc['status']).toBe('active');
      expect(doc['createdBy']).toBe(ADMIN.uid);

      const logged = await Paths.audit()
        .where('action', '==', 'createInsurer')
        .where('target', '==', insurerId)
        .get();
      expect(logged.size).toBe(1);

      insurerB = (
        await call(
          fns.createInsurer,
          { name: 'Aseguradora Prueba B', rnc: freshRnc(), billingEmail: 'facturas@b.test' },
          ADMIN,
        )
      ).insurerId;
    });

    it('refuses a second company with the same RNC', async () => {
      const rnc = (await Paths.insurer(insurerA).get()).data()!['rnc'] as string;
      const r = await refusal(
        call(fns.createInsurer, { name: 'Copia', rnc, billingEmail: 'f@x.do' }, ADMIN),
      );
      expect(r.code).toBe('failed-precondition');
      expect(r.message).toMatch(/RNC/);
    });
  });

  describe('adding people', () => {
    it('gives a new person the claims, the member record and a working password', async () => {
      const result = await newUser(insurerA, 'gerente', 'manager');
      managerA = result.uid;
      managerAPassword = result.temporaryPassword;

      const user = await auth.getUser(managerA);
      expect(user.customClaims).toEqual({
        role: 'insurer',
        insurerId: insurerA,
        insurerRole: 'manager',
      });

      const member = (await Paths.insurerMember(insurerA, managerA).get()).data()!;
      expect(member['active']).toBe(true);
      expect(member['insurerRole']).toBe('manager');
      expect(member['mustChangePassword']).toBe(true);
      expect(member['email']).toBe(email('gerente'));

      expect(await signIn(email('gerente'), managerAPassword)).toBe(true);
    });

    it('refuses an email that already has an account, leaving nothing behind', async () => {
      const r = await refusal(
        call(
          fns.createInsurerUser,
          { insurerId: insurerA, name: 'Repetido', email: email('gerente'), insurerRole: 'operator' },
          ADMIN,
        ),
      );
      expect(r.code).toBe('failed-precondition');
      expect(r.message).toMatch(/correo/);

      const members = await Paths.insurerMembers(insurerA).get();
      expect(members.size).toBe(1);
    });

    it('refuses a company that does not exist', async () => {
      const r = await refusal(
        call(
          fns.createInsurerUser,
          { insurerId: 'no-such-company', name: 'Nadie', email: email('nadie'), insurerRole: 'operator' },
          ADMIN,
        ),
      );
      expect(r.code).toBe('not-found');
    });

    it('lets a manager add a colleague to their own company', async () => {
      const who = await tokenOf(managerA);
      operatorA = (await newUser(insurerA, 'operador', 'operator', who)).uid;

      const member = (await Paths.insurerMember(insurerA, operatorA).get()).data()!;
      expect(member['createdBy']).toBe(managerA);
    });

    it('does not let a manager add people to another company', async () => {
      const who = await tokenOf(managerA);
      const r = await refusal(
        call(
          fns.createInsurerUser,
          { insurerId: insurerB, name: 'Intruso', email: email('intruso'), insurerRole: 'manager' },
          who,
        ),
      );
      expect(r.code).toBe('permission-denied');
    });

    it('does not let an operator add anyone', async () => {
      const who = await tokenOf(operatorA);
      const r = await refusal(
        call(
          fns.createInsurerUser,
          { insurerId: insurerA, name: 'Otro', email: email('otro'), insurerRole: 'operator' },
          who,
        ),
      );
      expect(r.code).toBe('permission-denied');
    });

    it('does not let a dispatcher add anyone', async () => {
      const r = await refusal(
        call(
          fns.createInsurerUser,
          { insurerId: insurerA, name: 'Otro', email: email('otro2'), insurerRole: 'operator' },
          OPS,
        ),
      );
      expect(r.code).toBe('permission-denied');
    });
  });

  describe('changing people', () => {
    it('does not let a manager deactivate themselves', async () => {
      const who = await tokenOf(managerA);
      const r = await refusal(
        call(fns.updateInsurerUser, { insurerId: insurerA, uid: managerA, active: false }, who),
      );
      expect(r.code).toBe('failed-precondition');
      expect((await Paths.insurerMember(insurerA, managerA).get()).data()!['active']).toBe(true);
    });

    it('does not let a manager reach a person of another company', async () => {
      operatorB = (await newUser(insurerB, 'operadorb', 'operator')).uid;
      const who = await tokenOf(managerA);

      // Their own company id, somebody else's person.
      const r = await refusal(
        call(fns.updateInsurerUser, { insurerId: insurerA, uid: operatorB, active: false }, who),
      );
      expect(r.code).toBe('not-found');
      expect((await auth.getUser(operatorB)).disabled).toBe(false);
    });

    it('deactivating disables the account and the guard refuses it at once', async () => {
      const who = await tokenOf(managerA);
      // The token the operator already holds, minted before the change.
      const operatorToken = await tokenOf(operatorA);

      await call(fns.updateInsurerUser, { insurerId: insurerA, uid: operatorA, active: false }, who);

      expect((await auth.getUser(operatorA)).disabled).toBe(true);
      expect((await Paths.insurerMember(insurerA, operatorA).get()).data()!['active']).toBe(false);

      const r = await refusal(guards.requireActiveInsurer(request({}, operatorToken)));
      expect(r.code).toBe('failed-precondition');
      expect(r.message).toMatch(/desactivado/);
    });

    it('reactivating lets them back in', async () => {
      const who = await tokenOf(managerA);
      await call(fns.updateInsurerUser, { insurerId: insurerA, uid: operatorA, active: true }, who);

      expect((await auth.getUser(operatorA)).disabled).toBe(false);
      const ok = await guards.requireActiveInsurer(request({}, await tokenOf(operatorA)));
      expect(ok.insurerId).toBe(insurerA);
      expect(ok.insurerRole).toBe('operator');
    });

    it('a demotion takes effect before the old token expires', async () => {
      // A second manager, then the office demotes them.
      const second = (await newUser(insurerA, 'gerente2', 'manager')).uid;
      const staleToken = await tokenOf(second);

      await call(
        fns.updateInsurerUser,
        { insurerId: insurerA, uid: second, insurerRole: 'operator' },
        ADMIN,
      );
      expect((await auth.getUser(second)).customClaims?.['insurerRole']).toBe('operator');

      // Their token still says manager; the member record is what counts.
      const r = await refusal(
        call(
          fns.createInsurerUser,
          { insurerId: insurerA, name: 'Tarde', email: email('tarde'), insurerRole: 'operator' },
          staleToken,
        ),
      );
      expect(r.code).toBe('permission-denied');
    });
  });

  describe('suspending a company', () => {
    it('is refused to anyone but an admin', async () => {
      const who = await tokenOf(managerA);
      const r = await refusal(
        call(fns.updateInsurer, { insurerId: insurerA, status: 'suspended' }, who),
      );
      expect(r.code).toBe('permission-denied');
    });

    it('locks every person out, and reactivating lets them back', async () => {
      const token = await tokenOf(managerA);
      // Auth records revocation to the second.
      const suspendedAt = Math.floor(Date.now() / 1000) * 1000;

      await call(
        fns.updateInsurer,
        { insurerId: insurerA, status: 'suspended', statusReason: 'Pago pendiente' },
        ADMIN,
      );

      const doc = (await Paths.insurer(insurerA).get()).data()!;
      expect(doc['status']).toBe('suspended');
      expect(doc['statusReason']).toBe('Pago pendiente');

      // Sessions revoked: the refresh token no longer works.
      for (const uid of [managerA, operatorA]) {
        const after = await auth.getUser(uid);
        expect(new Date(after.tokensValidAfterTime!).getTime()).toBeGreaterThanOrEqual(suspendedAt);
      }

      const r = await refusal(guards.requireActiveInsurer(request({}, token)));
      expect(r.code).toBe('failed-precondition');
      expect(r.message).toMatch(/suspendida/);

      // A suspended company's manager cannot manage its people either.
      const r2 = await refusal(
        call(
          fns.createInsurerUser,
          { insurerId: insurerA, name: 'Nuevo', email: email('nuevo'), insurerRole: 'operator' },
          token,
        ),
      );
      expect(r2.code).toBe('failed-precondition');

      await call(fns.updateInsurer, { insurerId: insurerA, status: 'active' }, ADMIN);
      const reopened = (await Paths.insurer(insurerA).get()).data()!;
      expect(reopened['status']).toBe('active');
      expect(reopened['statusReason']).toBe('');
      await guards.requireActiveInsurer(request({}, token));
    });

    it('refuses to take another company’s RNC on edit', async () => {
      const rncB = (await Paths.insurer(insurerB).get()).data()!['rnc'] as string;
      const r = await refusal(call(fns.updateInsurer, { insurerId: insurerA, rnc: rncB }, ADMIN));
      expect(r.code).toBe('failed-precondition');
    });
  });

  describe('the rest of the system', () => {
    it('will not make an insurer’s person office staff', async () => {
      const r = await refusal(
        call(admin.setAdminRole, { uid: operatorB, role: 'admin' }, ADMIN),
      );
      expect(r.code).toBe('failed-precondition');
      expect((await auth.getUser(operatorB)).customClaims?.['role']).toBe('insurer');
    });

    it('will not give an insurer’s person a customer profile', async () => {
      const r = await refusal(call(profile.ensureProfile, {}, await tokenOf(operatorB)));
      expect(r.code).toBe('permission-denied');
      expect((await Paths.user(operatorB).get()).exists).toBe(false);
    });

    it('tells the panel which company the person belongs to', async () => {
      const me = (await call(admin.whoAmI, {}, await tokenOf(managerA))) as Record<string, unknown>;
      expect(me['role']).toBe('insurer');
      expect(me['insurerId']).toBe(insurerA);
      expect(me['insurerRole']).toBe('manager');
      expect(me['canManageInsurers']).toBe(false);
      expect(me['canAssignServices']).toBe(false);
    });

    it('clears the change-password flag for the person who changed it, and only them', async () => {
      expect((await Paths.insurerMember(insurerA, managerA).get()).get('mustChangePassword')).toBe(true);
      await call(fns.insurerPasswordChanged, {}, await tokenOf(managerA));
      const member = (await Paths.insurerMember(insurerA, managerA).get()).data()!;
      expect(member['mustChangePassword']).toBe(false);
      expect(member['passwordChangedAt']).toBeDefined();
      // Nobody else's flag moved.
      expect((await Paths.insurerMember(insurerA, operatorA).get()).get('mustChangePassword')).toBe(true);

      expect((await refusal(call(fns.insurerPasswordChanged, {}, ADMIN))).code).toBe('permission-denied');
    });

    it('still lets a customer create their profile', async () => {
      const uid = `client-${runId}`;
      const result = (await call(profile.ensureProfile, {}, { uid, token: {} })) as {
        created: boolean;
      };
      expect(result.created).toBe(true);
      await Paths.user(uid).delete();
    });
  });
});
