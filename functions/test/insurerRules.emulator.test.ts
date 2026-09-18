import { readFileSync } from 'node:fs';

import type { RulesTestContext, RulesTestEnvironment } from '@firebase/rules-unit-testing';
import { afterAll, beforeAll, describe, it } from 'vitest';

/**
 * What a person of an insurance company can and cannot read.
 *
 * Runs the real `firestore.rules` and `database.rules.json` in the emulators:
 *
 *     npm run test:emulator
 *
 * The promise to an insurance company is that its people see its tows and
 * nothing else — not another company's, not a private customer's, not the
 * fleet. Every refusal below is one way that promise could break.
 */

const FIRESTORE = process.env['FIRESTORE_EMULATOR_HOST'];
const DATABASE = process.env['FIREBASE_DATABASE_EMULATOR_HOST'];
const describeEmulator = FIRESTORE ? describe : describe.skip;

function hostPort(value: string): { host: string; port: number } {
  const at = value.lastIndexOf(':');
  return { host: value.slice(0, at), port: Number(value.slice(at + 1)) };
}

let rut: typeof import('@firebase/rules-unit-testing');
let env: RulesTestEnvironment;

const insurerToken = (insurerId: string, insurerRole: string) => ({
  role: 'insurer',
  insurerId,
  insurerRole,
});

describeEmulator('insurer access rules', () => {
  beforeAll(async () => {
    rut = await import('@firebase/rules-unit-testing');
    env = await rut.initializeTestEnvironment({
      // Its own project, so these writes never meet the dispatch suite's.
      projectId: 'grua-insurer-rules',
      firestore: {
        ...hostPort(FIRESTORE!),
        rules: readFileSync(new URL('../../firestore.rules', import.meta.url), 'utf8'),
      },
      ...(DATABASE
        ? {
            database: {
              ...hostPort(DATABASE),
              rules: readFileSync(new URL('../../database.rules.json', import.meta.url), 'utf8'),
            },
          }
        : {}),
    });

    await env.clearFirestore();
    await env.withSecurityRulesDisabled(async (ctx) => {
      const db = ctx.firestore();
      const set = (path: string, data: Record<string, unknown>) => db.doc(path).set(data);

      await set('insurers/insA', { name: 'Aseguradora A', status: 'active' });
      await set('insurers/insB', { name: 'Aseguradora B', status: 'active' });
      await set('insurers/insS', { name: 'Aseguradora Suspendida', status: 'suspended' });

      await set('insurers/insA/members/mgrA', { insurerRole: 'manager', active: true });
      await set('insurers/insA/members/opA', { insurerRole: 'operator', active: true });
      await set('insurers/insA/members/offA', { insurerRole: 'manager', active: false });
      await set('insurers/insB/members/opB', { insurerRole: 'operator', active: true });
      await set('insurers/insS/members/opS', { insurerRole: 'manager', active: true });

      await set('services/svcA', { insurerId: 'insA', clientId: 'someone', status: 'accepted' });
      await set('services/svcB', { insurerId: 'insB', clientId: 'someone', status: 'accepted' });
      await set('services/svcS', { insurerId: 'insS', clientId: 'someone', status: 'accepted' });
      await set('services/svcRetail', { clientId: 'client1', status: 'accepted' });
      await set('services/svcA/events/e1', { name: 'requestService' });
      await set('services/svcB/events/e1', { name: 'requestService' });
      await set('services/svcA/offers/d1', { driverId: 'd1' });
      await set('services/svcA/messages/m1', { senderId: 'd1', text: 'hola' });
      await set('services/svcA/internal/billing', { driverPayoutCents: 175000, platformCents: 75000 });
      await set('tracking/svcA', { lat: 18.4, lng: -69.9 });
      await set('tracking/svcB', { lat: 18.4, lng: -69.9 });

      await set('drivers/d1', { name: 'Chofer' });
      await set('users/client1', { name: 'Cliente' });
      await set('trucks/t1', { plate: 'A000001', assignedDriverId: 'd1' });
      await set('invoices/i1', { clientId: 'client1' });
      await set('earnings/d1', { totalCents: 1 });
      await set('cashSettlements/c1', { driverId: 'd1' });
      await set('audit/a1', { action: 'x' });
      await set('reports/today', { services: 1 });
      await set('config/ncf/sequences/B01', { next: 1 });

      const rule = { vehicleClass: 'light', zoneMinKm: 0, zoneMaxKm: null, baseCents: 1, extraKmCents: 0 };
      await set('driverSettlements/s-d1', { driverId: 'd1', finalBalanceCents: 625000 });
      await set('driverSettlements/s-d2', { driverId: 'd2', finalBalanceCents: -180000 });
      await set('pricingRules/default__light__0', { ...rule, insurerId: null });
      await set('pricingRules/insA__light__0', { ...rule, insurerId: 'insA' });
      await set('pricingRules/insB__light__0', { ...rule, insurerId: 'insB' });

      const invoice = { status: 'issued', ncf: 'B0100000001', isTestNcf: true, totalCents: 295000 };
      await set('insurerInvoices/invA', { ...invoice, insurerId: 'insA' });
      await set('insurerInvoices/invB', { ...invoice, insurerId: 'insB' });
      await set('insurerInvoices/invS', { ...invoice, insurerId: 'insS' });
      await set('fiscal/issuer', { name: 'GRÚAS RD, SRL', rnc: '' });
      await set('fiscal/ncf_B01', { nextNumber: 2, lastNumber: 99999999, isTest: true });
      await set('ncfRegistry/TEST-B0100000001', { ncf: 'B0100000001', isTest: true });
    });

    if (DATABASE) {
      await env.withSecurityRulesDisabled(async (ctx) => {
        await ctx.database().ref('live/d1').set({ lat: 18.4, lng: -69.9, isOnline: true, updatedAt: 1 });
        await ctx.database().ref('presence/d1').set({ connected: true, lastChanged: 1 });
      });
    }
  });

  afterAll(async () => {
    await env?.cleanup();
  });

  const as = {
    operatorA: (): RulesTestContext =>
      env.authenticatedContext('opA', insurerToken('insA', 'operator')),
    managerA: (): RulesTestContext =>
      env.authenticatedContext('mgrA', insurerToken('insA', 'manager')),
    deactivatedA: (): RulesTestContext =>
      env.authenticatedContext('offA', insurerToken('insA', 'manager')),
    operatorB: (): RulesTestContext =>
      env.authenticatedContext('opB', insurerToken('insB', 'operator')),
    suspended: (): RulesTestContext =>
      env.authenticatedContext('opS', insurerToken('insS', 'manager')),
    // A token naming company A for somebody who is a member of B only.
    wrongCompany: (): RulesTestContext =>
      env.authenticatedContext('opB', insurerToken('insA', 'manager')),
    noCompany: (): RulesTestContext =>
      env.authenticatedContext('opA', { role: 'insurer' }),
    staff: (): RulesTestContext => env.authenticatedContext('ops1', { role: 'ops' }),
    client: (): RulesTestContext => env.authenticatedContext('client1'),
    stranger: (): RulesTestContext => env.unauthenticatedContext(),
  };

  const get = (ctx: RulesTestContext, path: string) => ctx.firestore().doc(path).get();
  const servicesOf = (ctx: RulesTestContext, insurerId: string) =>
    ctx.firestore().collection('services').where('insurerId', '==', insurerId).get();

  describe('their own company', () => {
    it('an operator reads the company record', async () => {
      await rut.assertSucceeds(get(as.operatorA(), 'insurers/insA'));
    });

    it('an operator reads their own member record, not a colleague’s', async () => {
      await rut.assertSucceeds(get(as.operatorA(), 'insurers/insA/members/opA'));
      await rut.assertFails(get(as.operatorA(), 'insurers/insA/members/mgrA'));
    });

    it('an operator cannot list the company’s people', async () => {
      await rut.assertFails(as.operatorA().firestore().collection('insurers/insA/members').get());
    });

    it('a manager lists the company’s people', async () => {
      await rut.assertSucceeds(as.managerA().firestore().collection('insurers/insA/members').get());
    });

    it('nobody from a company writes to it', async () => {
      await rut.assertFails(as.managerA().firestore().doc('insurers/insA').update({ status: 'active' }));
      await rut.assertFails(
        as.managerA().firestore().doc('insurers/insA/members/opA').update({ insurerRole: 'manager' }),
      );
      await rut.assertFails(
        as.managerA().firestore().doc('insurers/insA/members/new').set({ insurerRole: 'manager', active: true }),
      );
    });
  });

  describe('their own tows', () => {
    it('reads one of the company’s services', async () => {
      await rut.assertSucceeds(get(as.operatorA(), 'services/svcA'));
    });

    it('lists the company’s services when the query names the company', async () => {
      await rut.assertSucceeds(servicesOf(as.operatorA(), 'insA'));
    });

    it('lists this month’s tows, newest first, the way the portal asks', async () => {
      await rut.assertSucceeds(
        as.operatorA()
          .firestore()
          .collection('services')
          .where('insurerId', '==', 'insA')
          .where('createdAt', '>=', new Date('2026-01-01'))
          .orderBy('createdAt', 'desc')
          .limit(200)
          .get(),
      );
    });

    it('reads a company service’s history and live tracking', async () => {
      await rut.assertSucceeds(get(as.operatorA(), 'services/svcA/events/e1'));
      await rut.assertSucceeds(get(as.operatorA(), 'tracking/svcA'));
    });

    it('cannot write a service, even the company’s own', async () => {
      await rut.assertFails(as.managerA().firestore().doc('services/svcA').update({ status: 'closed' }));
      await rut.assertFails(
        as.managerA().firestore().doc('services/new').set({ insurerId: 'insA', clientId: 'mgrA' }),
      );
    });

    it('cannot read what the chofer is paid or what the office keeps', async () => {
      await rut.assertFails(get(as.managerA(), 'services/svcA/internal/billing'));
      await rut.assertFails(get(as.operatorA(), 'services/svcA/internal/billing'));
      await rut.assertFails(as.managerA().firestore().collection('services/svcA/internal').get());
    });

    it('cannot read the chofer’s offer or the job chat', async () => {
      await rut.assertFails(get(as.managerA(), 'services/svcA/offers/d1'));
      await rut.assertFails(get(as.managerA(), 'services/svcA/messages/m1'));
    });
  });

  describe('another company', () => {
    it('cannot read the other company or its people', async () => {
      await rut.assertFails(get(as.operatorA(), 'insurers/insB'));
      await rut.assertFails(get(as.managerA(), 'insurers/insB/members/opB'));
      await rut.assertFails(as.managerA().firestore().collection('insurers/insB/members').get());
    });

    it('cannot read the other company’s service, history or tracking', async () => {
      await rut.assertFails(get(as.operatorA(), 'services/svcB'));
      await rut.assertFails(get(as.operatorA(), 'services/svcB/events/e1'));
      await rut.assertFails(get(as.operatorA(), 'tracking/svcB'));
    });

    it('cannot list the other company’s services', async () => {
      await rut.assertFails(servicesOf(as.operatorA(), 'insB'));
    });

    it('cannot list all services', async () => {
      await rut.assertFails(as.operatorA().firestore().collection('services').get());
    });

    it('cannot list the company list', async () => {
      await rut.assertFails(as.managerA().firestore().collection('insurers').get());
    });
  });

  describe('everyone else’s data', () => {
    it('cannot read a private customer’s service', async () => {
      await rut.assertFails(get(as.managerA(), 'services/svcRetail'));
    });

    it('cannot read drivers, customers, trucks or money', async () => {
      const ctx = as.managerA();
      for (const path of [
        'drivers/d1',
        'users/client1',
        'trucks/t1',
        'invoices/i1',
        'earnings/d1',
        'cashSettlements/c1',
        'audit/a1',
        'reports/today',
        'config/ncf/sequences/B01',
      ]) {
        await rut.assertFails(get(ctx, path));
      }
    });

    it.skipIf(!DATABASE)('cannot read the fleet’s live positions or presence', async () => {
      const db = as.managerA().database();
      await rut.assertFails(db.ref('live').get());
      await rut.assertFails(db.ref('live/d1').get());
      await rut.assertFails(db.ref('presence').get());
    });
  });

  describe('zone prices', () => {
    const rulesWhere = (ctx: RulesTestContext, insurerId: string | null) =>
      ctx.firestore().collection('pricingRules').where('insurerId', '==', insurerId).get();

    it('a company reads the default list and its own prices', async () => {
      await rut.assertSucceeds(get(as.operatorA(), 'pricingRules/default__light__0'));
      await rut.assertSucceeds(get(as.operatorA(), 'pricingRules/insA__light__0'));
      await rut.assertSucceeds(rulesWhere(as.operatorA(), null));
      await rut.assertSucceeds(rulesWhere(as.operatorA(), 'insA'));
    });

    it('a company cannot read another company’s negotiated prices', async () => {
      await rut.assertFails(get(as.operatorA(), 'pricingRules/insB__light__0'));
      await rut.assertFails(rulesWhere(as.operatorA(), 'insB'));
      await rut.assertFails(as.operatorA().firestore().collection('pricingRules').get());
    });

    it('nobody from a company changes a price', async () => {
      const db = as.managerA().firestore();
      await rut.assertFails(db.doc('pricingRules/insA__light__0').update({ baseCents: 0 }));
      await rut.assertFails(db.doc('pricingRules/default__light__0').update({ baseCents: 0 }));
      await rut.assertFails(
        db.doc('pricingRules/insA__suv__0').set({
          vehicleClass: 'suv', zoneMinKm: 0, zoneMaxKm: null, baseCents: 0, extraKmCents: 0, insurerId: 'insA',
        }),
      );
    });

    it('a deactivated or suspended company reads no prices', async () => {
      await rut.assertFails(get(as.deactivatedA(), 'pricingRules/default__light__0'));
      await rut.assertFails(get(as.deactivatedA(), 'pricingRules/insA__light__0'));
      await rut.assertFails(get(as.suspended(), 'pricingRules/default__light__0'));
    });

    it('customers and strangers read no insurer prices', async () => {
      await rut.assertFails(get(as.client(), 'pricingRules/default__light__0'));
      await rut.assertFails(rulesWhere(as.client(), null));
      await rut.assertFails(get(as.stranger(), 'pricingRules/default__light__0'));
    });

    it('the office reads every table but writes none directly', async () => {
      await rut.assertSucceeds(as.staff().firestore().collection('pricingRules').get());
      await rut.assertFails(
        as.staff().firestore().doc('pricingRules/default__light__0').update({ baseCents: 0 }),
      );
    });
  });

  describe('weekly cortes', () => {
    const chofer = () => env.authenticatedContext('d1', { role: 'driver', driverId: 'd1' });
    const settlementsOf = (ctx: RulesTestContext, driverId: string) =>
      ctx.firestore().collection('driverSettlements').where('driverId', '==', driverId).get();

    it('a chofer reads their own cortes and nobody else’s', async () => {
      await rut.assertSucceeds(get(chofer(), 'driverSettlements/s-d1'));
      await rut.assertSucceeds(settlementsOf(chofer(), 'd1'));
      await rut.assertFails(get(chofer(), 'driverSettlements/s-d2'));
      await rut.assertFails(settlementsOf(chofer(), 'd2'));
      await rut.assertFails(chofer().firestore().collection('driverSettlements').get());
    });

    it('nobody writes a corte from an app, not even the office', async () => {
      await rut.assertFails(chofer().firestore().doc('driverSettlements/s-d1').update({ finalBalanceCents: 9 }));
      await rut.assertFails(
        chofer().firestore().doc('driverSettlements/new').set({ driverId: 'd1', finalBalanceCents: 9 }),
      );
      await rut.assertFails(as.staff().firestore().doc('driverSettlements/s-d1').update({ status: 'settled' }));
    });

    it('the office reads every corte; insurers, customers and strangers none', async () => {
      await rut.assertSucceeds(as.staff().firestore().collection('driverSettlements').get());
      for (const ctx of [as.managerA(), as.client(), as.stranger()]) {
        await rut.assertFails(get(ctx, 'driverSettlements/s-d1'));
      }
    });
  });

  describe('a person who may no longer act', () => {
    it('a deactivated member is refused everything, token or not', async () => {
      await rut.assertFails(get(as.deactivatedA(), 'insurers/insA'));
      await rut.assertFails(get(as.deactivatedA(), 'services/svcA'));
      await rut.assertFails(servicesOf(as.deactivatedA(), 'insA'));
      await rut.assertFails(get(as.deactivatedA(), 'insurers/insA/members/offA'));
    });

    it('a suspended company’s people are refused everything', async () => {
      await rut.assertFails(get(as.suspended(), 'insurers/insS'));
      await rut.assertFails(get(as.suspended(), 'services/svcS'));
      await rut.assertFails(servicesOf(as.suspended(), 'insS'));
    });

    it('a token naming a company the person does not belong to is refused', async () => {
      await rut.assertFails(get(as.wrongCompany(), 'insurers/insA'));
      await rut.assertFails(get(as.wrongCompany(), 'services/svcA'));
      await rut.assertFails(servicesOf(as.wrongCompany(), 'insA'));
    });

    it('an insurer token with no company is refused', async () => {
      await rut.assertFails(get(as.noCompany(), 'insurers/insA'));
      await rut.assertFails(get(as.noCompany(), 'services/svcA'));
    });
  });

  describe('monthly invoices and NCF numbering', () => {
    const invoicesOf = (ctx: RulesTestContext, insurerId: string) =>
      ctx.firestore().collection('insurerInvoices').where('insurerId', '==', insurerId).get();
    const admin = () => env.authenticatedContext('admin1', { role: 'admin' });
    const chofer = () => env.authenticatedContext('d1', { role: 'driver', driverId: 'd1' });

    it('a company’s manager reads its invoices and no other company’s', async () => {
      await rut.assertSucceeds(get(as.managerA(), 'insurerInvoices/invA'));
      await rut.assertSucceeds(invoicesOf(as.managerA(), 'insA'));
      await rut.assertFails(get(as.managerA(), 'insurerInvoices/invB'));
      await rut.assertFails(invoicesOf(as.managerA(), 'insB'));
      await rut.assertFails(as.managerA().firestore().collection('insurerInvoices').get());
    });

    it('an operator, a deactivated manager and a suspended company read none', async () => {
      await rut.assertFails(get(as.operatorA(), 'insurerInvoices/invA'));
      await rut.assertFails(invoicesOf(as.operatorA(), 'insA'));
      await rut.assertFails(get(as.deactivatedA(), 'insurerInvoices/invA'));
      await rut.assertFails(get(as.suspended(), 'insurerInvoices/invS'));
      await rut.assertFails(get(as.wrongCompany(), 'insurerInvoices/invA'));
    });

    it('customers, choferes and strangers read no invoice', async () => {
      for (const ctx of [as.client(), chofer(), as.stranger()]) {
        await rut.assertFails(get(ctx, 'insurerInvoices/invA'));
      }
    });

    it('the office reads every invoice, and nobody writes one from an app', async () => {
      await rut.assertSucceeds(as.staff().firestore().collection('insurerInvoices').get());
      await rut.assertFails(
        as.staff().firestore().doc('insurerInvoices/invA').update({ status: 'paid' }),
      );
      await rut.assertFails(
        as.managerA().firestore().doc('insurerInvoices/invA').update({ status: 'paid' }),
      );
      await rut.assertFails(
        admin().firestore().doc('insurerInvoices/new').set({ insurerId: 'insA', totalCents: 1 }),
      );
    });

    it('the office reads the fiscal settings; nobody else, and nobody writes them', async () => {
      await rut.assertSucceeds(get(as.staff(), 'fiscal/issuer'));
      await rut.assertSucceeds(get(admin(), 'fiscal/ncf_B01'));
      for (const ctx of [as.managerA(), as.client(), chofer(), as.stranger()]) {
        await rut.assertFails(get(ctx, 'fiscal/ncf_B01'));
      }
      await rut.assertFails(admin().firestore().doc('fiscal/ncf_B01').update({ nextNumber: 1 }));
    });

    it('only an admin reads the NCF registry, and nobody writes it', async () => {
      await rut.assertSucceeds(get(admin(), 'ncfRegistry/TEST-B0100000001'));
      await rut.assertFails(get(as.staff(), 'ncfRegistry/TEST-B0100000001'));
      await rut.assertFails(get(as.managerA(), 'ncfRegistry/TEST-B0100000001'));
      await rut.assertFails(
        admin().firestore().doc('ncfRegistry/B0100000009').set({ ncf: 'B0100000009' }),
      );
    });
  });

  describe('the other roles', () => {
    it('only the office reads an insurer tow’s split', async () => {
      await rut.assertSucceeds(get(as.staff(), 'services/svcA/internal/billing'));
      await rut.assertFails(get(env.authenticatedContext('d1', { role: 'driver' }), 'services/svcA/internal/billing'));
      await rut.assertFails(get(as.client(), 'services/svcA/internal/billing'));
      await rut.assertFails(
        as.staff().firestore().doc('services/svcA/internal/billing').update({ platformCents: 0 }),
      );
    });

    it('the office reads every company and its people', async () => {
      await rut.assertSucceeds(get(as.staff(), 'insurers/insA'));
      await rut.assertSucceeds(as.staff().firestore().collection('insurers').get());
      await rut.assertSucceeds(as.staff().firestore().collection('insurers/insB/members').get());
    });

    it('a customer and a stranger read no company', async () => {
      await rut.assertFails(get(as.client(), 'insurers/insA'));
      await rut.assertFails(as.client().firestore().collection('insurers').get());
      await rut.assertFails(get(as.stranger(), 'insurers/insA'));
    });

    it('a customer still reads their own service, and not a company’s', async () => {
      await rut.assertSucceeds(get(as.client(), 'services/svcRetail'));
      await rut.assertFails(get(as.client(), 'services/svcA'));
    });
  });
});
