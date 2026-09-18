import { beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { loadRtdbRulesForAdmin, useIsolatedProject } from './support/emulator.js';
import { freshRnc } from './support/rnc.js';

/**
 * Monthly invoices with NCF, against real Firestore:
 *
 *     npm run test:emulator
 *
 * What only the database can prove: that every invoice takes the next NCF and
 * no two share one, even when made at the same moment; that a tow is billed on
 * exactly one live invoice; that voiding gives its tows back; and that
 * entering the DGII's real range is all it takes to leave the test numbers.
 */

const describeEmulator =
  process.env['FIRESTORE_EMULATOR_HOST'] && process.env['FIREBASE_DATABASE_EMULATOR_HOST']
    ? describe
    : describe.skip;

interface Token {
  uid: string;
  token: Record<string, unknown>;
}

const ADMIN: Token = { uid: 'admin-1', token: { role: 'admin' } };
const OPS: Token = { uid: 'ops-1', token: { role: 'ops' } };
const MANAGER: Token = {
  uid: 'mgr-a',
  token: { role: 'insurer', insurerId: 'ins-a', insurerRole: 'manager' },
};

function request(data: unknown, who?: Token) {
  return {
    data,
    auth: who ? { uid: who.uid, token: { uid: who.uid, ...who.token } } : undefined,
    rawRequest: {},
    acceptsStreaming: false,
  } as never;
}

async function call<T>(fn: { run: (req: never) => T | Promise<T> }, data: unknown, who?: Token) {
  return fn.run(request(data, who)) as Promise<Awaited<T>>;
}

async function refusal(
  promise: Promise<unknown>,
): Promise<{ code: string; message: string; details: Record<string, unknown> }> {
  try {
    await promise;
  } catch (error) {
    const e = error as { code: string; message: string; details?: Record<string, unknown> };
    return { code: e.code, message: e.message, details: e.details ?? {} };
  }
  throw new Error('expected the call to be refused');
}

let fns: typeof import('../src/callables/insurerInvoices.js');
let fiscal: typeof import('../src/callables/fiscal.js');
let lifecycle: typeof import('../src/callables/lifecycle.js');
let periods: typeof import('../src/lib/insurerInvoice.js');
let Paths: typeof import('../src/lib/firestore.js')['Paths'];
let Timestamp: typeof import('../src/lib/firestore.js')['Timestamp'];
let db: FirebaseFirestore.Firestore;

/** Last month, and an instant in the middle of it. */
let lastMonth: string;
let inLastMonth: (day: number) => Date;

async function wipe(): Promise<void> {
  for (const name of [
    'services',
    'drivers',
    'insurers',
    'insurerInvoices',
    'fiscal',
    'ncfRegistry',
    'pricingRules',
    'config',
    'audit',
  ]) {
    await db.recursiveDelete(db.collection(name));
  }
}

async function company(id: string, name = `Aseguradora ${id}`): Promise<string> {
  const rnc = freshRnc();
  await Paths.insurer(id).set({
    name,
    rnc,
    billingEmail: `facturas@${id}.test`,
    status: 'active',
  });
  return rnc;
}

interface TowOptions {
  status?: string;
  finishedAt?: Date;
  subtotalCents?: number;
  feeCents?: number;
  paymentStatus?: string;
}

async function tow(id: string, insurerId: string, options: TowOptions = {}): Promise<void> {
  const {
    status = 'closed',
    finishedAt = inLastMonth(10),
    subtotalCents = 250000,
    feeCents = 0,
    paymentStatus = 'to_invoice',
  } = options;
  const at = Timestamp.fromDate(finishedAt);
  await Paths.service(id).set({
    code: `GR-${id}`,
    status,
    clientId: '',
    insurerId,
    insurerName: `Aseguradora ${insurerId}`,
    insurance: {
      claimNumber: `SIN-${id}`,
      claimKey: `SIN${id}`.toUpperCase(),
      policyNumber: 'POL-5789023',
      insuredName: 'Juan Carlos Pérez',
      insuredPhone: '+18095550123',
    },
    vehicle: { type: 'sedan', plate: 'G123456', make: 'Toyota', model: 'Corolla' },
    pickup: { address: 'Av. 27 de Febrero' },
    dropoff: { address: 'Taller Autocentro' },
    billing: {
      mode: 'insurer',
      insurerId,
      tariff: 'default',
      vehicleClass: 'light',
      zoneMinKm: 0,
      zoneMaxKm: 10,
      distanceKm: 6.4,
      baseCents: subtotalCents,
      subtotalCents,
    },
    quote: { subtotalCents },
    payment: { method: 'insurer', status: paymentStatus },
    timeline: status === 'cancelled' ? { cancelledAt: at } : { completedAt: at },
    ...(feeCents > 0 ? { cancellation: { by: 'insurer', feeCents } } : {}),
    createdAt: at,
  });
}

async function service(id: string) {
  return (await Paths.service(id).get()).data()!;
}

async function invoice(id: string) {
  return (await Paths.insurerInvoice(id).get()).data()!;
}

async function generate(data: Record<string, unknown> = {}) {
  return call(fns.generateInsurerInvoices, { periodKey: lastMonth, ...data }, ADMIN);
}

describeEmulator('monthly insurer invoices', () => {
  beforeAll(async () => {
    useIsolatedProject('grua-insurer-invoices');

    fns = await import('../src/callables/insurerInvoices.js');
    fiscal = await import('../src/callables/fiscal.js');
    lifecycle = await import('../src/callables/lifecycle.js');
    periods = await import('../src/lib/insurerInvoice.js');
    const firestore = await import('../src/lib/firestore.js');
    Paths = firestore.Paths;
    Timestamp = firestore.Timestamp;
    db = firestore.db;

    lastMonth = periods.previousPeriodKey(new Date());
    const { start } = periods.periodBounds(lastMonth);
    inLastMonth = (day) => new Date(start.getTime() + (day - 1) * 86_400_000 + 15 * 3_600_000);

    await loadRtdbRulesForAdmin();
  });

  beforeEach(async () => {
    await wipe();
  });

  describe('making the invoice', () => {
    it('bills last month on test NCF B0100000001, the next company on B0100000002', async () => {
      const rncA = await company('ins-a', 'Seguros Universal');
      await company('ins-b');
      await tow('a1', 'ins-a', { finishedAt: inLastMonth(2) });
      await tow('a2', 'ins-a', { finishedAt: inLastMonth(9), subtotalCents: 350000 });
      await tow('a3', 'ins-a', { status: 'cancelled', finishedAt: inLastMonth(12), feeCents: 50000 });
      await tow('b1', 'ins-b', { finishedAt: inLastMonth(5), subtotalCents: 1100000 });
      // Not billable: waiting for nothing, or not the company's.
      await tow('a-open', 'ins-a', { status: 'in_progress', paymentStatus: 'none' });
      await tow('retail', '', { paymentStatus: 'cash_collected' });

      const result = await generate();

      expect(result.periodKey).toBe(lastMonth);
      expect(result.failed).toEqual([]);
      expect(result.created.map((c) => [c.insurerId, c.ncf, c.isTestNcf])).toEqual([
        ['ins-a', 'B0100000001', true],
        ['ins-b', 'B0100000002', true],
      ]);

      const a = await invoice(result.created[0]!.invoiceId);
      expect(a).toMatchObject({
        insurerId: 'ins-a',
        insurerName: 'Seguros Universal',
        insurerRnc: rncA,
        billingEmail: 'facturas@ins-a.test',
        periodKey: lastMonth,
        ncf: 'B0100000001',
        ncfType: '01',
        isTestNcf: true,
        ncfExpiresOn: null,
        status: 'issued',
        lineCount: 3,
        towCount: 2,
        cancellationCount: 1,
        // 2,500 + 3,500 + 500 = 6,500; ITBIS 1,170; total 7,670.
        subtotalCents: 650000,
        itbisCents: 117000,
        totalCents: 767000,
        paymentTermsDays: 30,
        currency: 'DOP',
      });
      expect(a['issuer']).toMatchObject({ name: 'GRÚAS RD, SRL (en constitución)', rnc: '' });
      expect(a['lines'].map((l: { serviceId: string }) => l.serviceId)).toEqual(['a1', 'a2', 'a3']);
      expect(a['lines'][0]).toMatchObject({
        kind: 'tow',
        serviceCode: 'GR-a1',
        claimNumber: 'SIN-a1',
        policyNumber: 'POL-5789023',
        insuredName: 'Juan Carlos Pérez',
        plate: 'G123456',
        vehicle: 'Toyota Corolla',
        zoneLabel: '0–10 km',
        vehicleClass: 'Vehículo ligero',
        amountCents: 250000,
      });
      expect(a['lines'][0]).toMatchObject({
        tariff: 'default',
        baseCents: 250000,
        extraKm: 0,
        extraCents: 0,
      });
      expect(a['lines'][2]).toMatchObject({ kind: 'cancellation', amountCents: 50000, baseCents: 0 });
      // The prices the lines came from, for the spreadsheet: the built-in list.
      expect(a['tariffTable']).toHaveLength(12);
      expect(a['tariffTable'][0]).toEqual({
        vehicleClass: 'light',
        zoneMinKm: 0,
        zoneMaxKm: 10,
        baseCents: 250000,
        extraKmCents: 0,
        source: 'default',
      });
      expect(a['tariffTable'][11]).toEqual({
        vehicleClass: 'heavy',
        zoneMinKm: 50,
        zoneMaxKm: null,
        baseCents: 1100000,
        extraKmCents: 25000,
        source: 'default',
      });
      // Due 30 days after it was issued.
      const due = (a['dueAt'] as FirebaseFirestore.Timestamp).toDate();
      expect(due.getTime() - Date.now()).toBeGreaterThan(29 * 86_400_000);
      expect(due.getTime() - Date.now()).toBeLessThan(32 * 86_400_000);

      for (const id of ['a1', 'a2', 'a3']) {
        expect(await service(id)).toMatchObject({
          invoiceId: result.created[0]!.invoiceId,
          payment: { status: 'invoiced' },
        });
      }
      expect((await service('a-open'))['invoiceId']).toBeUndefined();
      expect((await service('retail'))['payment']['status']).toBe('cash_collected');

      const sequence = (await Paths.ncfSequence('B01').get()).data()!;
      expect(sequence).toMatchObject({ nextNumber: 3, isTest: true, lastIssued: 'B0100000002' });
      expect((await Paths.ncfRegistry('TEST-B0100000001').get()).data()).toMatchObject({
        documentId: result.created[0]!.invoiceId,
        insurerId: 'ins-a',
      });
      // A test number never blocks the real one.
      expect((await Paths.ncfRegistry('B0100000001').get()).exists).toBe(false);
    });

    it('bills a tow once: a second run finds nothing and takes no number', async () => {
      await company('ins-a');
      await tow('a1', 'ins-a');
      expect((await generate()).created).toHaveLength(1);
      expect((await generate()).created).toEqual([]);
      expect((await Paths.ncfSequence('B01').get()).data()!['nextNumber']).toBe(2);
    });

    it('never gives two invoices the same number, made at the same moment', async () => {
      const ids = ['ins-1', 'ins-2', 'ins-3', 'ins-4', 'ins-5'];
      for (const id of ids) {
        await company(id);
        await tow(`${id}-t`, id);
      }
      const results = await Promise.all(ids.map((insurerId) => generate({ insurerId })));
      const ncfs = results.flatMap((r) => r.created.map((c) => c.ncf)).sort();
      expect(ncfs).toEqual([
        'B0100000001',
        'B0100000002',
        'B0100000003',
        'B0100000004',
        'B0100000005',
      ]);
      expect((await Paths.ncfSequence('B01').get()).data()!['nextNumber']).toBe(6);
    }, 30_000);

    it('leaves this month for next month, unless the office invoices it now', async () => {
      await company('ins-a');
      await tow('old', 'ins-a');
      await tow('now', 'ins-a', { finishedAt: new Date(Date.now() - 1000) });

      const last = await generate();
      const billed = await invoice(last.created[0]!.invoiceId);
      expect(billed['lines'].map((l: { serviceId: string }) => l.serviceId)).toEqual(['old']);
      expect((await service('now'))['payment']['status']).toBe('to_invoice');

      const current = await generate({ periodKey: periods.periodKeyOf(new Date()) });
      expect(current.created).toHaveLength(1);
      expect((await service('now'))['payment']['status']).toBe('invoiced');

      const next = periods.periodKeyOf(new Date(Date.now() + 40 * 86_400_000));
      const refused = await refusal(generate({ periodKey: next }));
      expect(refused.code).toBe('invalid-argument');
      expect(refused.message).toContain('no ha empezado');
    });

    it('bills a leftover from an earlier month with the next invoice', async () => {
      await company('ins-a');
      const { start } = periods.periodBounds(lastMonth);
      await tow('older', 'ins-a', { finishedAt: new Date(start.getTime() - 20 * 86_400_000) });
      await tow('last', 'ins-a');
      const result = await generate();
      const billed = await invoice(result.created[0]!.invoiceId);
      expect(billed['lines'].map((l: { serviceId: string }) => l.serviceId)).toEqual(['older', 'last']);
    });

    it('splits a month with more tows than one invoice holds', async () => {
      await company('ins-a');
      const batch = db.batch();
      for (let i = 0; i < 401; i++) {
        const id = `busy-${i.toString().padStart(3, '0')}`;
        batch.set(Paths.service(id), {
          code: `GR-${id}`,
          status: 'closed',
          insurerId: 'ins-a',
          billing: { subtotalCents: 250000, zoneMinKm: 0, zoneMaxKm: 10 },
          payment: { method: 'insurer', status: 'to_invoice' },
          timeline: { completedAt: Timestamp.fromDate(inLastMonth(3)) },
        });
      }
      await batch.commit();

      const result = await generate({ insurerId: 'ins-a' });
      expect(result.created.map((c) => [c.ncf, c.lineCount])).toEqual([
        ['B0100000001', 400],
        ['B0100000002', 1],
      ]);
    }, 60_000);

    it('keeps the company’s own prices with its invoice', async () => {
      await company('ins-a');
      const own = (zoneMinKm: number, zoneMaxKm: number | null, baseCents: number, extraKmCents = 0) => ({
        insurerId: 'ins-a',
        vehicleClass: 'light',
        zoneMinKm,
        zoneMaxKm,
        baseCents,
        extraKmCents,
      });
      await db.doc('pricingRules/ins-a__light__0').set(own(0, 20, 200000));
      await db.doc('pricingRules/ins-a__light__20').set(own(20, null, 400000, 10000));
      await tow('a', 'ins-a');

      const result = await generate();
      const billed = await invoice(result.created[0]!.invoiceId);
      const light = billed['tariffTable'].filter((r: { vehicleClass: string }) => r.vehicleClass === 'light');
      expect(light).toEqual([
        { vehicleClass: 'light', zoneMinKm: 0, zoneMaxKm: 20, baseCents: 200000, extraKmCents: 0, source: 'insurer' },
        { vehicleClass: 'light', zoneMinKm: 20, zoneMaxKm: null, baseCents: 400000, extraKmCents: 10000, source: 'insurer' },
      ]);
      // The other classes are still on the list.
      expect(billed['tariffTable']).toHaveLength(2 + 4 + 4);
      expect(
        billed['tariffTable'].every(
          (r: { vehicleClass: string; source: string }) =>
            r.vehicleClass === 'light' || r.source === 'default',
        ),
      ).toBe(true);
    });

    it('refuses a company that does not exist', async () => {
      const refused = await refusal(generate({ insurerId: 'nope' }));
      expect(refused.code).toBe('not-found');
    });
  });

  describe('the NCF range', () => {
    it('numbers from the real range once the office enters it', async () => {
      await company('ins-a');
      await tow('t1', 'ins-a');
      await generate();

      const saved = await call(
        fiscal.saveNcfSequence,
        { prefix: 'B01', nextNumber: 1, lastNumber: 2, expiresOn: '2099-12-31', isTest: false },
        ADMIN,
      );
      expect(saved.next).toBe('B0100000001');

      await tow('t2', 'ins-a');
      const real = await generate();
      expect(real.created[0]).toMatchObject({ ncf: 'B0100000001', isTestNcf: false });
      expect(await invoice(real.created[0]!.invoiceId)).toMatchObject({
        isTestNcf: false,
        ncfExpiresOn: '2099-12-31',
      });
      expect((await Paths.ncfRegistry('B0100000001').get()).exists).toBe(true);

      // The real B0100000001 is taken now: a range cannot start there again.
      const again = await refusal(
        call(
          fiscal.saveNcfSequence,
          { prefix: 'B01', nextNumber: 1, lastNumber: 2, expiresOn: '2099-12-31', isTest: false },
          ADMIN,
        ),
      );
      expect(again.code).toBe('failed-precondition');
      expect(again.details['code']).toBe('ncf_unavailable');
      expect(again.message).toContain('B0100000001');
    });

    it('stops at the end of the range and says so', async () => {
      await call(
        fiscal.saveNcfSequence,
        { prefix: 'B01', nextNumber: 7, lastNumber: 7, expiresOn: '2099-12-31', isTest: false },
        ADMIN,
      );
      await company('ins-a');
      await company('ins-b');
      await tow('a', 'ins-a');
      await tow('b', 'ins-b');

      const result = await generate();
      expect(result.created.map((c) => c.ncf)).toEqual(['B0100000007']);
      expect(result.failed).toHaveLength(1);
      expect(result.failed[0]!.message).toContain('Se agotó');
      // The company that could not be billed keeps its tow waiting.
      expect((await service('b'))['payment']['status']).toBe('to_invoice');

      const alone = await refusal(generate({ insurerId: 'ins-b' }));
      expect(alone.code).toBe('failed-precondition');
      expect(alone.details['code']).toBe('ncf_unavailable');
    });

    it('stops after the expiry date', async () => {
      // Saved while valid, then the day passed.
      await Paths.ncfSequence('B01').set({
        prefix: 'B01',
        nextNumber: 1,
        lastNumber: 50,
        expiresOn: '2020-01-31',
        isTest: false,
      });
      await company('ins-a');
      await tow('a', 'ins-a');
      const refused = await refusal(generate({ insurerId: 'ins-a' }));
      expect(refused.details['code']).toBe('ncf_unavailable');
      expect(refused.message).toContain('venció');
    });

    it('refuses a real range with no expiry, or one already expired', async () => {
      const noExpiry = await refusal(
        call(fiscal.saveNcfSequence, { prefix: 'B01', nextNumber: 1, lastNumber: 5, isTest: false }, ADMIN),
      );
      expect(noExpiry.code).toBe('invalid-argument');
      expect(noExpiry.message).toContain('vencimiento');

      const expired = await refusal(
        call(
          fiscal.saveNcfSequence,
          { prefix: 'B01', nextNumber: 1, lastNumber: 5, expiresOn: '2020-01-31', isTest: false },
          ADMIN,
        ),
      );
      expect(expired.code).toBe('invalid-argument');
      expect(expired.message).toContain('ya pasó');
    });

    it('prints the issuer the office entered', async () => {
      const rnc = freshRnc();
      await call(
        fiscal.saveFiscalIssuer,
        {
          name: 'Titan Grúas, SRL',
          rnc,
          address: 'Av. Luperón 25, Santo Domingo',
          phone: '809-555-0100',
          email: 'facturacion@titan.test',
          paymentTermsDays: 15,
        },
        ADMIN,
      );
      await company('ins-a');
      await tow('a', 'ins-a');
      const result = await generate();
      const billed = await invoice(result.created[0]!.invoiceId);
      expect(billed['issuer']).toEqual({
        name: 'Titan Grúas, SRL',
        rnc,
        address: 'Av. Luperón 25, Santo Domingo',
        phone: '809-555-0100',
        email: 'facturacion@titan.test',
      });
      expect(billed['paymentTermsDays']).toBe(15);

      const bad = await refusal(
        call(fiscal.saveFiscalIssuer, { name: 'Titan', rnc: '123' }, ADMIN),
      );
      expect(bad.code).toBe('invalid-argument');
      expect(bad.message).toContain('RNC');
    });
  });

  describe('after it is issued', () => {
    async function oneInvoice(): Promise<string> {
      await company('ins-a');
      await tow('a1', 'ins-a');
      await tow('a2', 'ins-a');
      return (await generate()).created[0]!.invoiceId;
    }

    it('records the transfer that paid it', async () => {
      const id = await oneInvoice();
      const noRef = await refusal(call(fns.markInsurerInvoicePaid, { invoiceId: id, reference: '' }, ADMIN));
      expect(noRef.code).toBe('invalid-argument');

      await call(fns.markInsurerInvoicePaid, { invoiceId: id, reference: 'TRF-889231' }, ADMIN);
      expect(await invoice(id)).toMatchObject({
        status: 'paid',
        paymentReference: 'TRF-889231',
        paidBy: 'admin-1',
      });

      const twice = await refusal(
        call(fns.markInsurerInvoicePaid, { invoiceId: id, reference: 'TRF-1' }, ADMIN),
      );
      expect(twice.code).toBe('failed-precondition');
      const voidPaid = await refusal(
        call(fns.voidInsurerInvoice, { invoiceId: id, reason: 'error' }, ADMIN),
      );
      expect(voidPaid.message).toContain('nota de crédito');
    });

    it('voids an unpaid one and bills its tows again on a new number', async () => {
      const id = await oneInvoice();
      const noReason = await refusal(call(fns.voidInsurerInvoice, { invoiceId: id, reason: '' }, ADMIN));
      expect(noReason.code).toBe('invalid-argument');

      const voided = await call(
        fns.voidInsurerInvoice,
        { invoiceId: id, reason: 'Precio equivocado' },
        ADMIN,
      );
      expect(voided.released).toBe(2);
      expect(await invoice(id)).toMatchObject({ status: 'voided', voidReason: 'Precio equivocado' });
      for (const t of ['a1', 'a2']) {
        const s = await service(t);
        expect(s['payment']['status']).toBe('to_invoice');
        expect(s['invoiceId']).toBeUndefined();
        expect(s['payment']['invoicedAt']).toBeUndefined();
      }

      const again = await generate();
      // The voided number stays used: it goes on the DGII's 608 report.
      expect(again.created[0]!.ncf).toBe('B0100000002');
      expect(await invoice(again.created[0]!.invoiceId)).toMatchObject({ lineCount: 2 });

      const twice = await refusal(
        call(fns.voidInsurerInvoice, { invoiceId: id, reason: 'otra vez' }, ADMIN),
      );
      expect(twice.message).toContain('ya está anulada');
    });

    it('answers "not found" for an invoice that does not exist', async () => {
      const paid = await refusal(
        call(fns.markInsurerInvoicePaid, { invoiceId: 'nope', reference: 'TRF-1' }, ADMIN),
      );
      expect(paid.code).toBe('not-found');
      const voided = await refusal(
        call(fns.voidInsurerInvoice, { invoiceId: 'nope', reason: 'error' }, ADMIN),
      );
      expect(voided.code).toBe('not-found');
    });
  });

  describe('who may', () => {
    it('only an admin makes, closes or voids invoices, or sets the numbering', async () => {
      await company('ins-a');
      await tow('a', 'ins-a');
      const id = (await generate()).created[0]!.invoiceId;

      for (const who of [OPS, MANAGER, undefined]) {
        // Valid requests, so the refusal is about who asks and nothing else.
        const attempts = [
          () => call(fns.generateInsurerInvoices, {}, who),
          () => call(fns.markInsurerInvoicePaid, { invoiceId: id, reference: 'TRF-1' }, who),
          () => call(fns.voidInsurerInvoice, { invoiceId: id, reason: 'Precio equivocado' }, who),
          () => call(fiscal.saveFiscalIssuer, { name: 'Otra, SRL', rnc: '' }, who),
          () =>
            call(
              fiscal.saveNcfSequence,
              { prefix: 'B01', nextNumber: 900, lastNumber: 901, isTest: true },
              who,
            ),
        ];
        for (const attempt of attempts) {
          const refused = await refusal(attempt());
          expect(['permission-denied', 'unauthenticated']).toContain(refused.code);
        }
      }
      expect((await invoice(id))['status']).toBe('issued');
      expect((await Paths.ncfSequence('B01').get()).data()!['nextNumber']).toBe(2);
    });
  });

  describe('cancellation fees', () => {
    const OPERATOR: Token = {
      uid: 'op-a',
      token: { role: 'insurer', insurerId: 'ins-a', insurerRole: 'operator' },
    };

    async function acceptedTow(id: string, acceptedMinutesAgo: number): Promise<void> {
      await Paths.insurerMember('ins-a', 'op-a').set({ insurerRole: 'operator', active: true });
      await Paths.driver('d1').set({ name: 'Chofer', currentServiceId: id });
      await tow(id, 'ins-a', { status: 'accepted', paymentStatus: 'none' });
      await Paths.service(id).update({
        driverId: 'd1',
        'timeline.acceptedAt': Timestamp.fromDate(
          new Date(Date.now() - acceptedMinutesAgo * 60_000),
        ),
      });
    }

    it('go on the invoice when the company cancels late, and nowhere when the office does', async () => {
      await company('ins-a');
      await acceptedTow('late', 60);
      await call(lifecycle.cancelService, { serviceId: 'late', reason: 'duplicado' }, OPERATOR);
      const late = await service('late');
      expect(late['cancellation']['feeCents']).toBeGreaterThan(0);
      expect(late['payment']['status']).toBe('to_invoice');

      await acceptedTow('office', 60);
      await call(lifecycle.cancelService, { serviceId: 'office', reason: 'error' }, OPS);
      const office = await service('office');
      expect(office['cancellation']['feeCents']).toBe(0);
      expect(office['payment']['status']).toBe('none');

      await acceptedTow('early', 0);
      await call(lifecycle.cancelService, { serviceId: 'early', reason: 'duplicado' }, OPERATOR);
      expect((await service('early'))['payment']['status']).toBe('none');

      // The late fee is billed with this month's tows.
      const result = await generate({ periodKey: periods.periodKeyOf(new Date()) });
      const billed = await invoice(result.created[0]!.invoiceId);
      expect(billed['lines']).toEqual([
        expect.objectContaining({
          serviceId: 'late',
          kind: 'cancellation',
          amountCents: late['cancellation']['feeCents'],
        }),
      ]);
    });
  });
});
