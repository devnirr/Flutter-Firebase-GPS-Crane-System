import { readFileSync } from 'node:fs';

import { describe, expect, it } from 'vitest';

import { VehicleType } from '../src/lib/enums.js';
import {
  DEFAULT_DRIVER_PAYOUT_BPS,
  claimKey,
  createInsurerServiceInput,
  driverPayoutBpsOf,
  insurerBilling,
  payoutSplit,
  quoteFromZone,
  signInsurerQuote,
  verifyInsurerQuote,
} from '../src/lib/insurerService.js';
import { signQuote } from '../src/lib/pricing.js';
import { defaultRulesFor, quoteZonePrice } from '../src/lib/zonePricing.js';

/**
 * An insurer's tow before it reaches the database: who gets what, what the
 * form must hold, and the signature that keeps the previewed price.
 */

process.env['QUOTE_SIGNING_SECRET'] ??= 'test-secret';

describe('payoutSplit', () => {
  it('pays the chofer 70% of a RD$2,500 tow: RD$1,750, and keeps RD$750', () => {
    expect(payoutSplit(250_000, 7000)).toEqual({
      driverPayoutBps: 7000,
      driverPayoutCents: 175_000,
      platformCents: 75_000,
    });
  });

  it('pays RD$2,450 of a RD$3,500 tow, and keeps RD$1,050', () => {
    const split = payoutSplit(350_000, 7000);
    expect(split.driverPayoutCents).toBe(245_000);
    expect(split.platformCents).toBe(105_000);
  });

  it('works on a price with extra kilometres', () => {
    // 62 km, light: RD$6,940.
    const split = payoutSplit(694_000, 7000);
    expect(split.driverPayoutCents).toBe(485_800);
    expect(split.platformCents).toBe(208_200);
  });

  it('honours a company’s own rate', () => {
    expect(payoutSplit(250_000, 6500).driverPayoutCents).toBe(162_500);
  });

  it('rounds the chofer’s share to the peso and always adds up', () => {
    for (const subtotal of [1, 99, 100, 12_345, 101_200, 184_567, 2_850_000]) {
      for (const rate of [0, 1, 3333, 6500, 7000, 9999, 10_000]) {
        const split = payoutSplit(subtotal, rate);
        expect(split.driverPayoutCents + split.platformCents).toBe(subtotal);
        expect(split.driverPayoutCents).toBeGreaterThanOrEqual(0);
        expect(split.platformCents).toBeGreaterThanOrEqual(0);
        if (split.driverPayoutCents < subtotal) expect(split.driverPayoutCents % 100).toBe(0);
      }
    }
  });
});

describe('payoutSplit on the shared examples', () => {
  const { payouts } = JSON.parse(
    readFileSync(
      new URL('../../packages/grua_core/test/fixtures/zone_pricing_cases.json', import.meta.url),
      'utf8',
    ),
  ) as {
    payouts: Array<{ subtotalCents: number; driverPayoutBps: number; driverPayoutCents: number }>;
  };

  for (const c of payouts) {
    it(`${c.driverPayoutBps / 100}% of ${c.subtotalCents} cents`, () => {
      const split = payoutSplit(c.subtotalCents, c.driverPayoutBps);
      expect(split.driverPayoutCents).toBe(c.driverPayoutCents);
      expect(split.platformCents).toBe(c.subtotalCents - c.driverPayoutCents);
    });
  }
});

describe('driverPayoutBpsOf', () => {
  it('is 70% when the company sets nothing', () => {
    expect(DEFAULT_DRIVER_PAYOUT_BPS).toBe(7000);
    expect(driverPayoutBpsOf(undefined)).toBe(7000);
    expect(driverPayoutBpsOf({})).toBe(7000);
  });

  it('uses the company’s rate', () => {
    expect(driverPayoutBpsOf({ driverPayoutBps: 6500 })).toBe(6500);
    expect(driverPayoutBpsOf({ driverPayoutBps: 0 })).toBe(0);
  });

  it('ignores a rate that is not one, rather than paying it', () => {
    for (const bad of [12_000, -1, 70.5, '7000', null]) {
      expect(driverPayoutBpsOf({ driverPayoutBps: bad })).toBe(7000);
    }
  });
});

describe('createInsurerServiceInput', () => {
  const valid = {
    pickup: { geo: { latitude: 18.47, longitude: -69.94 }, address: 'Av. 27 de Febrero' },
    dropoff: { geo: { latitude: 18.49, longitude: -69.93 }, address: 'Taller Autocentro' },
    vehicle: { type: 'sedan', plate: 'g-123456', make: 'Toyota', model: 'Corolla', color: 'Azul' },
    insurance: {
      claimNumber: ' SIN-2024-01489 ',
      policyNumber: 'POL-5789023-DR',
      insuredName: 'Juan Carlos Pérez',
      insuredPhone: '+1 (809) 555-0123',
    },
    notes: 'Portón azul',
  };

  it('accepts the form as the mockup fills it', () => {
    const parsed = createInsurerServiceInput.parse(valid);
    expect(parsed.insurance.claimNumber).toBe('SIN-2024-01489');
    expect(parsed.vehicle.plate).toBe('G-123456');
  });

  it('needs only the claim, the two places and the vehicle type', () => {
    const parsed = createInsurerServiceInput.parse({
      pickup: valid.pickup,
      dropoff: valid.dropoff,
      vehicle: { type: 'suv' },
      insurance: { claimNumber: 'SIN-1' },
    });
    expect(parsed.insurance.policyNumber).toBe('');
    expect(parsed.insurance.insuredName).toBe('');
    expect(parsed.notes).toBe('');
    expect(parsed.priced).toBeUndefined();
  });

  it('refuses a missing or blank claim number', () => {
    const { claimNumber: _, ...noClaim } = valid.insurance;
    expect(createInsurerServiceInput.safeParse({ ...valid, insurance: noClaim }).success).toBe(false);
    expect(
      createInsurerServiceInput.safeParse({
        ...valid,
        insurance: { ...valid.insurance, claimNumber: '   ' },
      }).success,
    ).toBe(false);
  });

  it('refuses a phone with letters in it', () => {
    expect(
      createInsurerServiceInput.safeParse({
        ...valid,
        insurance: { ...valid.insurance, insuredPhone: 'llamar a Juan' },
      }).success,
    ).toBe(false);
  });

  it('refuses a vehicle type the tariff does not know', () => {
    expect(
      createInsurerServiceInput.safeParse({ ...valid, vehicle: { type: 'bicicleta' } }).success,
    ).toBe(false);
  });
});

describe('claimKey', () => {
  it('treats spacing, dashes and case as the same claim', () => {
    expect(claimKey('SIN-2024-01489')).toBe('SIN202401489');
    expect(claimKey('sin 2024 01489')).toBe('SIN202401489');
    expect(claimKey(' Sin/2024.01489 ')).toBe('SIN202401489');
  });

  it('is empty for a claim with nothing in it', () => {
    expect(claimKey('--- ')).toBe('');
  });
});

describe('the preview signature', () => {
  const payload = {
    insurerId: 'ins-1',
    vehicleType: 'sedan',
    pickupGeohash: 'de2f7abc',
    dropoffGeohash: 'de2f7xyz',
    distanceKm: 12.3,
    expiresAtMs: 1_800_000_000_000,
  };
  const signature = signInsurerQuote(payload);

  it('verifies what it signed', () => {
    expect(verifyInsurerQuote(payload, signature)).toBe(true);
  });

  it('refuses any change to what was priced', () => {
    for (const change of [
      { insurerId: 'ins-2' },
      { vehicleType: 'camion' },
      { pickupGeohash: 'de2f7abd' },
      { dropoffGeohash: 'de2f7xyy' },
      { distanceKm: 12.4 },
      { expiresAtMs: payload.expiresAtMs + 1 },
    ]) {
      expect(verifyInsurerQuote({ ...payload, ...change }, signature)).toBe(false);
    }
  });

  it('refuses a malformed signature without throwing', () => {
    expect(verifyInsurerQuote(payload, 'short')).toBe(false);
    expect(verifyInsurerQuote(payload, signature.toUpperCase())).toBe(false);
  });

  it('is never the signature of a customer quote', () => {
    const customer = signQuote({
      clientId: payload.insurerId,
      pickupGeohash: payload.pickupGeohash,
      dropoffGeohash: payload.dropoffGeohash,
      totalCents: 0,
      expiresAtMs: payload.expiresAtMs,
      pricingVersion: 0,
      truckType: 'gancho',
      vehicleType: 'sedan',
      distance: { distanceKm: payload.distanceKm, cityKm: 0, highwayKm: 0 },
    });
    expect(verifyInsurerQuote(payload, customer)).toBe(false);
  });
});

describe('what the insurance company sees', () => {
  const zone = quoteZonePrice({
    rules: defaultRulesFor('light'),
    distanceKm: 8,
    tariff: 'default',
  });

  it('shows RD$2,500 + ITBIS = RD$2,950', () => {
    const quote = quoteFromZone(zone, VehicleType.sedan);
    expect(quote.subtotalCents).toBe(250_000);
    expect(quote.itbisCents).toBe(45_000);
    expect(quote.totalCents).toBe(295_000);
    expect(quote.surcharges).toEqual([]);
    expect(quote.heavy).toBe(false);
  });

  it('marks a heavy vehicle as heavy', () => {
    const heavy = quoteZonePrice({
      rules: defaultRulesFor('heavy'),
      distanceKm: 8,
      tariff: 'default',
    });
    expect(quoteFromZone(heavy, VehicleType.camion).heavy).toBe(true);
  });

  it('never carries the chofer’s share or the company’s margin', () => {
    const shown = JSON.stringify({
      quote: quoteFromZone(zone, VehicleType.sedan),
      billing: insurerBilling('ins-1', zone),
    }).toLowerCase();
    for (const word of ['payout', 'platform', 'commission', 'net']) {
      expect(shown).not.toContain(word);
    }
  });
});
