import { readFileSync } from 'node:fs';

import { describe, expect, it } from 'vitest';

import {
  DEFAULT_PRICING_RULES,
  type PricingRule,
  ZoneTableError,
  defaultRulesFor,
  pricingRuleId,
  pricingRuleSchema,
  quoteZonePrice,
  vehicleClassOf,
  withItbis,
  zoneTableProblem,
} from '../src/lib/zonePricing.js';

/**
 * The insurer zone tariff, run against the examples the Dart port also runs.
 * A number that changes here without changing there fails one of the two.
 */

interface Fixture {
  defaultRules: PricingRule[];
  vehicleClasses: Record<string, string | null>;
  defaultCases: Array<{
    name: string;
    vehicleType: string;
    distanceKm: number;
    zoneMinKm: number;
    distanceOut: number;
    extraKm: number;
    extraCents: number;
    subtotalCents: number;
  }>;
  customTables: Array<{
    name: string;
    rules: PricingRule[];
    cases: Array<{ distanceKm: number; zoneMinKm: number; extraCents: number; subtotalCents: number }>;
  }>;
  invalidTables: Array<{ name: string; rules: PricingRule[] }>;
  itbis: Array<{ subtotalCents: number; itbisCents: number; totalCents: number }>;
}

const fixture = JSON.parse(
  readFileSync(
    new URL('../../packages/grua_core/test/fixtures/zone_pricing_cases.json', import.meta.url),
    'utf8',
  ),
) as Fixture;

describe('the default table', () => {
  it('is the table in the shared examples', () => {
    expect([...DEFAULT_PRICING_RULES]).toEqual(fixture.defaultRules);
  });

  it('is a complete table for every class', () => {
    for (const vehicleClass of ['light', 'suv', 'heavy'] as const) {
      expect(zoneTableProblem(defaultRulesFor(vehicleClass))).toBeNull();
    }
  });

  it('holds only rows a pricingRules document may hold', () => {
    for (const rule of DEFAULT_PRICING_RULES) {
      expect(pricingRuleSchema.safeParse(rule).success).toBe(true);
    }
  });

  it('matches the printed price list', () => {
    const at = (vehicleClass: 'light' | 'suv' | 'heavy', zoneMinKm: number) =>
      DEFAULT_PRICING_RULES.find(
        (r) => r.vehicleClass === vehicleClass && r.zoneMinKm === zoneMinKm,
      )!;
    // "Tabla de precios base — Titan Grúas RD (sin ITBIS)", in pesos.
    expect(at('light', 0).baseCents / 100).toBe(2_500);
    expect(at('suv', 10).baseCents / 100).toBe(4_500);
    expect(at('heavy', 25).baseCents / 100).toBe(11_000);
    expect(at('light', 50).extraKmCents / 100).toBe(120);
    expect(at('suv', 50).extraKmCents / 100).toBe(150);
    expect(at('heavy', 50).extraKmCents / 100).toBe(250);
  });
});

describe('vehicleClassOf', () => {
  for (const [vehicleType, vehicleClass] of Object.entries(fixture.vehicleClasses)) {
    it(`prices ${vehicleType} as ${vehicleClass ?? 'nothing'}`, () => {
      expect(vehicleClassOf(vehicleType)).toBe(vehicleClass);
    });
  }

  it('has no column for a value it does not know', () => {
    expect(vehicleClassOf('bicicleta')).toBeNull();
    expect(vehicleClassOf('')).toBeNull();
  });
});

describe('quoteZonePrice on the default table', () => {
  for (const c of fixture.defaultCases) {
    it(c.name, () => {
      const vehicleClass = vehicleClassOf(c.vehicleType)!;
      const quote = quoteZonePrice({
        rules: defaultRulesFor(vehicleClass),
        distanceKm: c.distanceKm,
        tariff: 'default',
      });

      expect(quote.vehicleClass).toBe(vehicleClass);
      expect(quote.zoneMinKm).toBe(c.zoneMinKm);
      expect(quote.distanceKm).toBe(c.distanceOut);
      expect(quote.extraKm).toBe(c.extraKm);
      expect(quote.extraCents).toBe(c.extraCents);
      expect(quote.subtotalCents).toBe(c.subtotalCents);
      expect(quote.baseCents + quote.extraCents).toBe(quote.subtotalCents);
      expect(quote.tariff).toBe('default');
      expect(quote.currency).toBe('DOP');
    });
  }

  it('never charges less for a longer trip', () => {
    for (const vehicleClass of ['light', 'suv', 'heavy'] as const) {
      let previous = 0;
      for (let tenths = 0; tenths <= 2000; tenths++) {
        const { subtotalCents } = quoteZonePrice({
          rules: defaultRulesFor(vehicleClass),
          distanceKm: tenths / 10,
          tariff: 'default',
        });
        expect(subtotalCents).toBeGreaterThanOrEqual(previous);
        previous = subtotalCents;
      }
    }
  });

  it('charges heavy more than SUV, and SUV more than light, at every distance', () => {
    for (let tenths = 0; tenths <= 2000; tenths += 7) {
      const price = (vehicleClass: 'light' | 'suv' | 'heavy') =>
        quoteZonePrice({
          rules: defaultRulesFor(vehicleClass),
          distanceKm: tenths / 10,
          tariff: 'default',
        }).subtotalCents;
      expect(price('suv')).toBeGreaterThan(price('light'));
      expect(price('heavy')).toBeGreaterThan(price('suv'));
    }
  });

  it('does not care what order the rows come in', () => {
    const shuffled = [...defaultRulesFor('light')].reverse();
    const quote = quoteZonePrice({ rules: shuffled, distanceKm: 62, tariff: 'default' });
    expect(quote.subtotalCents).toBe(694_000);
  });

  it('refuses a distance that is not a distance', () => {
    const rules = defaultRulesFor('light');
    for (const distanceKm of [-1, Number.NaN, Number.POSITIVE_INFINITY]) {
      expect(() => quoteZonePrice({ rules, distanceKm, tariff: 'default' })).toThrow(RangeError);
    }
  });
});

describe('quoteZonePrice on other tables', () => {
  for (const table of fixture.customTables) {
    for (const c of table.cases) {
      it(`${table.name}: ${c.distanceKm} km`, () => {
        const quote = quoteZonePrice({
          rules: table.rules,
          distanceKm: c.distanceKm,
          tariff: 'insurer',
        });
        expect(quote.zoneMinKm).toBe(c.zoneMinKm);
        expect(quote.extraCents).toBe(c.extraCents);
        expect(quote.subtotalCents).toBe(c.subtotalCents);
        expect(quote.tariff).toBe('insurer');
      });
    }
  }
});

describe('zoneTableProblem', () => {
  for (const table of fixture.invalidTables) {
    it(`refuses a table: ${table.name}`, () => {
      expect(zoneTableProblem(table.rules)).toEqual(expect.any(String));
      expect(() =>
        quoteZonePrice({ rules: table.rules, distanceKm: 5, tariff: 'default' }),
      ).toThrow(ZoneTableError);
    });
  }

  it('accepts a single open zone', () => {
    expect(zoneTableProblem(fixture.customTables[1]!.rules)).toBeNull();
  });
});

describe('pricingRuleSchema', () => {
  const valid = fixture.defaultRules[0]!;

  it('refuses fractional kilometres and cents', () => {
    expect(pricingRuleSchema.safeParse({ ...valid, zoneMinKm: 0.5 }).success).toBe(false);
    expect(pricingRuleSchema.safeParse({ ...valid, baseCents: 10.5 }).success).toBe(false);
  });

  it('refuses negative prices', () => {
    expect(pricingRuleSchema.safeParse({ ...valid, baseCents: -1 }).success).toBe(false);
    expect(pricingRuleSchema.safeParse({ ...valid, extraKmCents: -1 }).success).toBe(false);
  });

  it('refuses a class that is not in the table', () => {
    expect(pricingRuleSchema.safeParse({ ...valid, vehicleClass: 'moto' }).success).toBe(false);
  });

  it('requires insurerId to be present, even when it is null', () => {
    const { insurerId: _, ...rest } = valid;
    expect(pricingRuleSchema.safeParse(rest).success).toBe(false);
  });
});

describe('pricingRuleId', () => {
  it('names the table, the class and the zone', () => {
    expect(pricingRuleId(fixture.defaultRules[0]!)).toBe('default__light__0');
    expect(pricingRuleId(fixture.customTables[0]!.rules[1]!)).toBe('ins-demo__light__10');
  });

  it('is different for every default row', () => {
    const ids = new Set(DEFAULT_PRICING_RULES.map(pricingRuleId));
    expect(ids.size).toBe(DEFAULT_PRICING_RULES.length);
  });
});

describe('withItbis', () => {
  for (const c of fixture.itbis) {
    it(`RD$ cents ${c.subtotalCents} + 18%`, () => {
      expect(withItbis(c.subtotalCents)).toEqual(c);
    });
  }
});
