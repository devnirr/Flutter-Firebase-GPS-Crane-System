import { beforeAll, beforeEach, describe, expect, it } from 'vitest';

import type { PricingRule } from '../src/lib/zonePricing.js';

/**
 * Which table an insurance company is billed on, read from real Firestore:
 *
 *     npm run test:emulator
 *
 * The pure arithmetic is in `zonePricing.test.ts`. What this proves is the
 * choice of rows: a company's own prices where it has them, the stored default
 * where it does not, the built-in list when nothing is stored — and a refusal,
 * never a silent fallback, when a stored table is broken.
 */

const describeEmulator = process.env['FIRESTORE_EMULATOR_HOST'] ? describe : describe.skip;

let tariff: typeof import('../src/lib/zoneTariff.js');
let pricing: typeof import('../src/lib/zonePricing.js');
let Paths: typeof import('../src/lib/firestore.js')['Paths'];

// Company ids unique to this run: the collection is shared with anything else
// running against the same emulator, and the default rows are cleared here.
const runId = Math.random().toString(36).slice(2, 8);
const NEGOTIATED = `ins-negotiated-${runId}`;
const BROKEN = `ins-broken-${runId}`;
const PLAIN = `ins-plain-${runId}`;

const rule = (over: Partial<PricingRule>): PricingRule => ({
  vehicleClass: 'light',
  zoneMinKm: 0,
  zoneMaxKm: null,
  baseCents: 0,
  extraKmCents: 0,
  insurerId: null,
  ...over,
});

async function store(rules: PricingRule[]): Promise<void> {
  for (const r of rules) await Paths.pricingRules().doc(pricing.pricingRuleId(r)).set(r);
}

async function clearDefaultRows(): Promise<void> {
  const snap = await Paths.pricingRules().where('insurerId', '==', null).get();
  await Promise.all(snap.docs.map((doc) => doc.ref.delete()));
}

describeEmulator('zone tariff resolution', () => {
  beforeAll(async () => {
    process.env['GCLOUD_PROJECT'] ??= 'grua-rd-test';
    tariff = await import('../src/lib/zoneTariff.js');
    pricing = await import('../src/lib/zonePricing.js');
    Paths = (await import('../src/lib/firestore.js')).Paths;

    // A company that negotiated light vehicles only: RD$2,000 flat to 10 km,
    // then RD$100 a km.
    await store([
      rule({ insurerId: NEGOTIATED, zoneMinKm: 0, zoneMaxKm: 10, baseCents: 200_000 }),
      rule({ insurerId: NEGOTIATED, zoneMinKm: 10, baseCents: 200_000, extraKmCents: 10_000 }),
    ]);

    // A company whose light table has a gap between 10 and 12 km.
    await store([
      rule({ insurerId: BROKEN, zoneMinKm: 0, zoneMaxKm: 10, baseCents: 1 }),
      rule({ insurerId: BROKEN, zoneMinKm: 12, baseCents: 1 }),
    ]);
  });

  beforeEach(clearDefaultRows);

  it('with nothing stored, bills on the built-in price list', async () => {
    const quote = await tariff.quoteForInsurer({
      insurerId: PLAIN,
      vehicleType: 'sedan',
      distanceKm: 62,
    });
    expect(quote.tariff).toBe('default');
    expect(quote.subtotalCents).toBe(694_000);
  });

  it('uses a company’s negotiated prices for the class it negotiated', async () => {
    const quote = await tariff.quoteForInsurer({
      insurerId: NEGOTIATED,
      vehicleType: 'sedan',
      distanceKm: 15,
    });
    expect(quote.tariff).toBe('insurer');
    expect(quote.subtotalCents).toBe(250_000);
  });

  it('bills the classes a company did not negotiate on the default list', async () => {
    const quote = await tariff.quoteForInsurer({
      insurerId: NEGOTIATED,
      vehicleType: 'suv',
      distanceKm: 15,
    });
    expect(quote.tariff).toBe('default');
    expect(quote.subtotalCents).toBe(450_000);
  });

  it('prefers the stored default list over the built-in one', async () => {
    // The office raised the light default to RD$3,000 flat.
    await store([rule({ zoneMinKm: 0, baseCents: 300_000 })]);

    const quote = await tariff.quoteForInsurer({
      insurerId: PLAIN,
      vehicleType: 'motor',
      distanceKm: 40,
    });
    expect(quote.tariff).toBe('default');
    expect(quote.subtotalCents).toBe(300_000);

    // A class the stored default says nothing about still has a price.
    const heavy = await tariff.quoteForInsurer({
      insurerId: PLAIN,
      vehicleType: 'camion',
      distanceKm: 5,
    });
    expect(heavy.subtotalCents).toBe(550_000);
  });

  it('never lets one company’s prices leak into another’s', async () => {
    const quote = await tariff.quoteForInsurer({
      insurerId: PLAIN,
      vehicleType: 'sedan',
      distanceKm: 15,
    });
    expect(quote.subtotalCents).toBe(350_000);
  });

  it('refuses to quote on a broken company table instead of falling back', async () => {
    await expect(
      tariff.quoteForInsurer({ insurerId: BROKEN, vehicleType: 'sedan', distanceKm: 5 }),
    ).rejects.toMatchObject({ code: 'internal' });
  });

  it('refuses to quote on a broken stored default', async () => {
    await store([rule({ zoneMinKm: 0, zoneMaxKm: 10, baseCents: 1 })]);
    await expect(
      tariff.quoteForInsurer({ insurerId: PLAIN, vehicleType: 'sedan', distanceKm: 5 }),
    ).rejects.toMatchObject({ code: 'internal' });
  });

  it('refuses to quote on a row that is not a price', async () => {
    await Paths.pricingRules()
      .doc('default__light__0')
      .set({ ...rule({}), baseCents: 'dos mil' });
    await expect(
      tariff.quoteForInsurer({ insurerId: PLAIN, vehicleType: 'sedan', distanceKm: 5 }),
    ).rejects.toMatchObject({ code: 'internal' });
  });

  it('asks for a vehicle type it can price', async () => {
    await expect(
      tariff.quoteForInsurer({ insurerId: PLAIN, vehicleType: 'unknown', distanceKm: 5 }),
    ).rejects.toMatchObject({ code: 'invalid-argument' });
  });
});
