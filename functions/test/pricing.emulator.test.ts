import { beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { useIsolatedProject } from './support/emulator.js';

/**
 * Editing the zone tariff and a company's chofer share, on real Firestore:
 *
 *     npm run test:emulator
 */

const describeEmulator = process.env['FIRESTORE_EMULATOR_HOST'] ? describe : describe.skip;

interface Token {
  uid: string;
  token: Record<string, unknown>;
}

const ADMIN: Token = { uid: 'admin-1', token: { role: 'admin' } };
const OPS: Token = { uid: 'ops-1', token: { role: 'ops' } };

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

async function refusal(promise: Promise<unknown>): Promise<{ code: string; message: string }> {
  try {
    await promise;
  } catch (error) {
    const e = error as { code: string; message: string };
    return { code: e.code, message: e.message };
  }
  throw new Error('expected the call to be refused');
}

let pricing: typeof import('../src/callables/pricing.js');
let insurers: typeof import('../src/callables/insurers.js');
let tariff: typeof import('../src/lib/zoneTariff.js');
let Paths: typeof import('../src/lib/firestore.js')['Paths'];
let db: FirebaseFirestore.Firestore;

// Universal's negotiated light-vehicle price: RD$2,000 to 15 km, then RD$100/km.
const negotiated = [
  { zoneMinKm: 0, zoneMaxKm: 15, baseCents: 200_000, extraKmCents: 0 },
  { zoneMinKm: 15, zoneMaxKm: null, baseCents: 200_000, extraKmCents: 10_000 },
];

async function rowsOf(insurerId: string | null, vehicleClass: string) {
  const snap = await Paths.pricingRules()
    .where('insurerId', '==', insurerId)
    .where('vehicleClass', '==', vehicleClass)
    .get();
  return snap.docs.map((d) => ({ id: d.id, ...d.data() }) as Record<string, unknown> & { id: string });
}

describeEmulator('editing prices', () => {
  beforeAll(async () => {
    useIsolatedProject('grua-pricing');
    pricing = await import('../src/callables/pricing.js');
    insurers = await import('../src/callables/insurers.js');
    tariff = await import('../src/lib/zoneTariff.js');
    const firestore = await import('../src/lib/firestore.js');
    Paths = firestore.Paths;
    db = firestore.db;
  });

  beforeEach(async () => {
    for (const name of ['pricingRules', 'insurers', 'audit']) {
      await db.recursiveDelete(db.collection(name));
    }
    await Paths.insurer('universal').set({ name: 'Universal', status: 'active' });
  });

  it('saves a company’s table, and quotes on it at once', async () => {
    await call(
      pricing.savePricingTable,
      { insurerId: 'universal', vehicleClass: 'light', rows: negotiated },
      ADMIN,
    );

    const rows = await rowsOf('universal', 'light');
    expect(rows.map((r) => r.id).sort()).toEqual(['universal__light__0', 'universal__light__15']);
    expect(rows.every((r) => r['updatedBy'] === 'admin-1')).toBe(true);

    const quote = await tariff.quoteForInsurer({
      insurerId: 'universal',
      vehicleType: 'sedan',
      distanceKm: 20,
    });
    expect(quote.tariff).toBe('insurer');
    expect(quote.subtotalCents).toBe(250_000);

    const logged = await Paths.audit().where('action', '==', 'savePricingTable').get();
    expect(logged.size).toBe(1);
  });

  it('replaces the old table whole, leaving no stray zones', async () => {
    await call(
      pricing.savePricingTable,
      { insurerId: 'universal', vehicleClass: 'light', rows: negotiated },
      ADMIN,
    );
    await call(
      pricing.savePricingTable,
      {
        insurerId: 'universal',
        vehicleClass: 'light',
        rows: [{ zoneMinKm: 0, zoneMaxKm: null, baseCents: 180_000, extraKmCents: 9_000 }],
      },
      ADMIN,
    );
    const rows = await rowsOf('universal', 'light');
    expect(rows.map((r) => r.id)).toEqual(['universal__light__0']);
    expect(rows[0]!['baseCents']).toBe(180_000);
  });

  it('refuses a table with a gap, and keeps the old one', async () => {
    await call(
      pricing.savePricingTable,
      { insurerId: 'universal', vehicleClass: 'light', rows: negotiated },
      ADMIN,
    );
    const r = await refusal(
      call(
        pricing.savePricingTable,
        {
          insurerId: 'universal',
          vehicleClass: 'light',
          rows: [
            { zoneMinKm: 0, zoneMaxKm: 10, baseCents: 1, extraKmCents: 0 },
            { zoneMinKm: 12, zoneMaxKm: null, baseCents: 1, extraKmCents: 0 },
          ],
        },
        ADMIN,
      ),
    );
    expect(r.code).toBe('invalid-argument');
    expect(r.message).toMatch(/continuas/);
    expect(await rowsOf('universal', 'light')).toHaveLength(2);
  });

  it('refuses fractional pesos and negative prices', async () => {
    for (const bad of [{ baseCents: 100.5 }, { baseCents: -1 }, { extraKmCents: -5 }]) {
      const r = await refusal(
        call(
          pricing.savePricingTable,
          {
            insurerId: null,
            vehicleClass: 'suv',
            rows: [{ zoneMinKm: 0, zoneMaxKm: null, baseCents: 1, extraKmCents: 0, ...bad }],
          },
          ADMIN,
        ),
      );
      expect(r.code).toBe('invalid-argument');
    }
  });

  it('edits the default list, which every company without its own uses', async () => {
    await call(
      pricing.savePricingTable,
      {
        insurerId: null,
        vehicleClass: 'suv',
        rows: [{ zoneMinKm: 0, zoneMaxKm: null, baseCents: 400_000, extraKmCents: 0 }],
      },
      ADMIN,
    );
    expect(await rowsOf(null, 'suv')).toHaveLength(1);
    const quote = await tariff.quoteForInsurer({
      insurerId: 'universal',
      vehicleType: 'suv',
      distanceKm: 80,
    });
    expect(quote.subtotalCents).toBe(400_000);
  });

  it('resets a company to the default list, and the default to the built-in one', async () => {
    await call(
      pricing.savePricingTable,
      { insurerId: 'universal', vehicleClass: 'light', rows: negotiated },
      ADMIN,
    );
    const reset = await call(
      pricing.resetPricingTable,
      { insurerId: 'universal', vehicleClass: 'light' },
      ADMIN,
    );
    expect(reset.removed).toBe(2);
    const quote = await tariff.quoteForInsurer({
      insurerId: 'universal',
      vehicleType: 'sedan',
      distanceKm: 20,
    });
    expect(quote.tariff).toBe('default');
    expect(quote.subtotalCents).toBe(350_000);
  });

  it('refuses a company that does not exist, and anyone but an admin', async () => {
    expect(
      (
        await refusal(
          call(
            pricing.savePricingTable,
            { insurerId: 'nadie', vehicleClass: 'light', rows: negotiated },
            ADMIN,
          ),
        )
      ).code,
    ).toBe('not-found');
    expect(
      (
        await refusal(
          call(
            pricing.savePricingTable,
            { insurerId: null, vehicleClass: 'light', rows: negotiated },
            OPS,
          ),
        )
      ).code,
    ).toBe('permission-denied');
    expect(
      (
        await refusal(
          call(pricing.resetPricingTable, { insurerId: null, vehicleClass: 'light' }, OPS),
        )
      ).code,
    ).toBe('permission-denied');
  });

  describe('a company’s chofer share', () => {
    it('is set, changed and cleared back to the default', async () => {
      await call(
        insurers.updateInsurer,
        { insurerId: 'universal', driverPayoutBps: 6500 },
        ADMIN,
      );
      expect((await Paths.insurer('universal').get()).get('driverPayoutBps')).toBe(6500);

      await call(
        insurers.updateInsurer,
        { insurerId: 'universal', driverPayoutBps: null },
        ADMIN,
      );
      expect((await Paths.insurer('universal').get()).data()).not.toHaveProperty('driverPayoutBps');
    });

    it('refuses a share over 100%', async () => {
      const r = await refusal(
        call(insurers.updateInsurer, { insurerId: 'universal', driverPayoutBps: 12_000 }, ADMIN),
      );
      expect(r.code).toBe('invalid-argument');
      expect(r.message).toMatch(/porcentaje/);
    });
  });
});
