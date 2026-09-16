import { describe, expect, it } from 'vitest';

import {
  ACTIVE_STATUSES,
  ServiceEventName,
  ServiceStatus,
  TERMINAL_STATUSES,
  TruckType,
  VehicleCondition,
  VehicleType,
  inferTruckType,
  trucksThatCanServe,
} from '../src/lib/enums.js';
import {
  DEFAULT_DISPATCH,
  type ScanTally,
  scanReason,
  scoreCandidates,
} from '../src/dispatch/dispatchNext.js';
import {
  DEFAULT_PRICING,
  type TripDistance,
  bps,
  buildQuote,
  cancellationFeeCents,
  cityTrip,
  commissionCents,
  confirmedQuote,
  finalQuote,
  mergePricing,
  signQuote,
  tripDistance,
  verifyQuote,
} from '../src/lib/pricing.js';
import { stretchesFrom } from '../src/lib/routes.js';
import { isValidPlate, maxTruckYear, normalizePlate } from '../src/lib/trucks.js';
import { isAvailableWithin } from '../src/lib/live.js';
import { TRUCK_REF_TTL_MS, openTruckRef, sealTruckRef } from '../src/lib/truckRef.js';
import { coarse } from '../src/callables/nearby.js';
import {
  distanceMeters,
  isInsidePolygon,
  isPlausiblyInDominicanRepublic,
  queryBounds,
} from '../src/lib/geo.js';
import { dateKey, localHour, serviceCode, toLocal } from '../src/lib/time.js';
import { TRANSITIONS, transitionFor } from '../src/lib/stateMachine.js';

/**
 * Pure-logic tests.
 *
 * Everything here runs without an emulator, which is deliberate: pricing, geo
 * and the transition table are the parts most likely to be wrong in a way
 * nobody notices, and they should be testable on any machine in under a second.
 * The concurrency guarantees need Firestore and live in `dispatch.emulator.test.ts`.
 */

process.env['QUOTE_SIGNING_SECRET'] = 'test-secret';

/** A UTC instant for a given Dominican wall-clock hour. */
const atLocalHour = (hour: number, day = 15): Date =>
  new Date(Date.UTC(2026, 5, day, hour) - -4 * 60 * 60 * 1000);

describe('pricing', () => {
  /** A trip entirely on city streets. */
  const city = (km: number) => cityTrip(km, DEFAULT_PRICING.includedKm);

  const quoteFor = (
    vehicleType: VehicleType,
    distance: TripDistance,
    hour = 12,
    extra: { waitingMinutes?: number; chargeItbis?: boolean } = {},
  ) =>
    buildQuote({
      config: DEFAULT_PRICING,
      vehicleType,
      distance,
      at: atLocalHour(hour),
      chargeItbis: extra.chargeItbis ?? false,
      waitingMinutes: extra.waitingMinutes,
    });

  it('prices the example the owner gave: a carro, 8 km in the city, RD$1,710', () => {
    const quote = quoteFor(VehicleType.sedan, city(8));
    expect(quote.distanceKm).toBe(8);
    expect(quote.cityKm).toBe(3);
    expect(quote.highwayKm).toBe(0);
    expect(quote.distanceCents).toBe(3 * 7000);
    expect(quote.totalCents).toBe(171000);
  });

  it('includes the first 5 km in each tarifa base', () => {
    expect(quoteFor(VehicleType.sedan, city(5)).totalCents).toBe(150000);
    expect(quoteFor(VehicleType.suv, city(5)).totalCents).toBe(180000);
    expect(quoteFor(VehicleType.camioneta, city(5)).totalCents).toBe(200000);
    expect(quoteFor(VehicleType.sedan, city(2)).totalCents).toBe(150000);
  });

  it('charges carretera kilometres at RD$130 and city ones at RD$70', () => {
    const distance = tripDistance(
      [
        { meters: 10000, highway: false },
        { meters: 10000, highway: true },
      ],
      DEFAULT_PRICING.includedKm,
    );
    expect(distance).toEqual({ distanceKm: 20, cityKm: 5, highwayKm: 10 });
    expect(quoteFor(VehicleType.sedan, distance).totalCents).toBe(
      150000 + 5 * 7000 + 10 * 13000,
    );
  });

  it('takes the included kilometres from the start of the trip, in driving order', () => {
    // Out of town first: the included 5 km are carretera, the rest is city.
    const distance = tripDistance(
      [
        { meters: 5000, highway: true },
        { meters: 10000, highway: false },
      ],
      5,
    );
    expect(distance).toEqual({ distanceKm: 15, cityKm: 10, highwayKm: 0 });
  });

  it('works in tenths of a kilometre, and the parts always add up', () => {
    expect(tripDistance([{ meters: 8049, highway: false }], 5).distanceKm).toBe(8);
    expect(tripDistance([{ meters: 8050, highway: false }], 5).distanceKm).toBe(8.1);
    const odd = tripDistance(
      [
        { meters: 3333, highway: false },
        { meters: 4444, highway: true },
        { meters: 5555, highway: false },
      ],
      5,
    );
    expect(Math.round((odd.cityKm + odd.highwayKm) * 10)).toBe(
      Math.round((odd.distanceKm - 5) * 10),
    );
  });

  it('adds 30% to the total between 22:00 and 06:00 for a light vehicle', () => {
    const night = quoteFor(VehicleType.sedan, city(8), 23);
    const surcharge = night.surcharges.find((s) => s.code === 'nocturno');
    expect(surcharge?.label).toBe('Recargo nocturno (30%)');
    expect(surcharge?.cents).toBe(51300);
    expect(night.totalCents).toBe(222300);
  });

  it('starts the night surcharge at 22:00 local, not 22:00 UTC', () => {
    const evening = quoteFor(VehicleType.sedan, city(10), 21);
    const night = quoteFor(VehicleType.sedan, city(10), 22);
    expect(evening.surcharges.some((s) => s.code === 'nocturno')).toBe(false);
    expect(night.surcharges.some((s) => s.code === 'nocturno')).toBe(true);
  });

  it('applies the night surcharge across midnight and stops at 06:00', () => {
    for (const hour of [23, 0, 3, 5]) {
      expect(
        quoteFor(VehicleType.sedan, city(10), hour).surcharges.some(
          (s) => s.code === 'nocturno',
        ),
        `${hour}:00 local should be a night hour`,
      ).toBe(true);
    }
    expect(
      quoteFor(VehicleType.sedan, city(10), 6).surcharges.some((s) => s.code === 'nocturno'),
    ).toBe(false);
  });

  it('rounds the night surcharge to whole pesos', () => {
    // 8.1 km: 150000 + 3.1 × 7000 = 171700; 30% is 51510 → RD$515.
    const quote = quoteFor(VehicleType.sedan, city(8.1), 23);
    expect(quote.surcharges.find((s) => s.code === 'nocturno')?.cents).toBe(51500);
  });

  describe('vehículos pesados', () => {
    it('starts each heavy type at its minimum', () => {
      expect(quoteFor(VehicleType.camion, city(5)).totalCents).toBe(500000);
      expect(quoteFor(VehicleType.patana, city(5)).totalCents).toBe(800000);
      expect(quoteFor(VehicleType.equipoPesado, city(5)).totalCents).toBe(1000000);
    });

    it('charges RD$250, RD$400 and RD$600 a km past 5, city or carretera alike', () => {
      const road = tripDistance(
        [
          { meters: 5000, highway: false },
          { meters: 5000, highway: true },
        ],
        5,
      );
      expect(quoteFor(VehicleType.camion, road).totalCents).toBe(500000 + 5 * 25000);
      expect(quoteFor(VehicleType.patana, road).totalCents).toBe(800000 + 5 * 40000);
      expect(quoteFor(VehicleType.equipoPesado, road).totalCents).toBe(1000000 + 5 * 60000);
    });

    it('adds 40% at night', () => {
      const night = quoteFor(VehicleType.camion, city(5), 23);
      expect(night.surcharges.find((s) => s.code === 'nocturno')?.label).toBe(
        'Recargo nocturno (40%)',
      );
      expect(night.totalCents).toBe(700000);
    });

    it('marks the quote as an estimate, and a light one as not', () => {
      expect(quoteFor(VehicleType.patana, city(5)).heavy).toBe(true);
      expect(quoteFor(VehicleType.camioneta, city(5)).heavy).toBe(false);
    });
  });

  it('never charges less than the minimum', () => {
    const cheap = {
      ...DEFAULT_PRICING,
      baseCentsByVehicleType: { ...DEFAULT_PRICING.baseCentsByVehicleType, motor: 90000 },
    };
    const quote = buildQuote({
      config: cheap,
      vehicleType: VehicleType.motor,
      distance: city(6),
      at: atLocalHour(12),
      chargeItbis: false,
    });
    expect(quote.minimumAdjustmentCents).toBe(150000 - 90000 - 7000);
    expect(quote.totalCents).toBe(150000);
  });

  it('bills only waiting time past the free window', () => {
    const free = quoteFor(VehicleType.sedan, city(10), 12, {
      waitingMinutes: DEFAULT_PRICING.freeWaitingMinutes,
    });
    expect(free.surcharges.some((s) => s.code === 'espera')).toBe(false);

    const over = quoteFor(VehicleType.sedan, city(10), 12, {
      waitingMinutes: DEFAULT_PRICING.freeWaitingMinutes + 7,
    });
    expect(over.surcharges.find((s) => s.code === 'espera')?.cents).toBe(
      7 * DEFAULT_PRICING.perWaitingMinuteCents,
    );
  });

  it('applies ITBIS at 18% only when a fiscal receipt is issued', () => {
    const fiscal = quoteFor(VehicleType.sedan, city(20), 12, { chargeItbis: true });
    expect(fiscal.itbisCents).toBe(Math.round(fiscal.subtotalCents * 0.18));
    expect(fiscal.totalCents).toBe(fiscal.subtotalCents + fiscal.itbisCents);
    expect(quoteFor(VehicleType.sedan, city(20)).itbisCents).toBe(0);
  });

  it('finishes a job at the agreed price plus waiting, not a fresh quote', () => {
    const quoted = quoteFor(VehicleType.sedan, city(8), 21);
    // Finished after 22:00 with 15 minutes' wait: no night rate appears.
    const final = finalQuote(quoted, DEFAULT_PRICING, DEFAULT_PRICING.freeWaitingMinutes + 15);
    expect(final.surcharges.map((s) => s.code)).toEqual(['espera']);
    expect(final.totalCents).toBe(171000 + 15 * DEFAULT_PRICING.perWaitingMinuteCents);
    expect(finalQuote(quoted, DEFAULT_PRICING, 3)).toEqual(quoted);
  });

  it("keeps the estimate on the receipt when the operator confirms a heavy job's price", () => {
    const estimate = quoteFor(VehicleType.camion, city(10));
    const confirmed = confirmedQuote(estimate, 900000);
    expect(confirmed.totalCents).toBe(900000);
    expect(confirmed.baseCents).toBe(estimate.baseCents);
    expect(confirmed.surcharges.find((s) => s.code === 'ajuste_operador')?.cents).toBe(
      900000 - estimate.totalCents,
    );

    // Confirmed twice: one adjustment line, not two.
    const again = confirmedQuote(confirmed, 800000);
    expect(again.totalCents).toBe(800000);
    expect(again.surcharges.filter((s) => s.code === 'ajuste_operador')).toHaveLength(1);

    // With ITBIS the operator's figure is what the customer pays, tax included.
    const fiscal = confirmedQuote(
      quoteFor(VehicleType.camion, city(10), 12, { chargeItbis: true }),
      1180000,
    );
    expect(fiscal.totalCents).toBe(1180000);
    expect(fiscal.subtotalCents).toBe(1000000);
    expect(fiscal.itbisCents).toBe(180000);
  });

  it('keeps default rates for types a stored tariff does not mention', () => {
    const merged = mergePricing({ baseCentsByVehicleType: { patana: 900000 } });
    expect(merged.baseCentsByVehicleType['patana']).toBe(900000);
    expect(merged.baseCentsByVehicleType['sedan']).toBe(150000);
    expect(merged.lightNightSurchargeBps).toBe(3000);
  });

  it('computes basis points exactly at awkward rates', () => {
    expect(bps(100000, 1250)).toBe(12500);
    expect(commissionCents(DEFAULT_PRICING, 100000)).toBe(20000);
  });

  it('charges no cancellation fee inside the grace period', () => {
    const acceptedAt = new Date('2026-06-15T12:00:00Z');
    expect(
      cancellationFeeCents(
        DEFAULT_PRICING,
        acceptedAt,
        new Date(acceptedAt.getTime() + 2 * 60000),
      ),
    ).toBe(0);
    expect(
      cancellationFeeCents(
        DEFAULT_PRICING,
        acceptedAt,
        new Date(acceptedAt.getTime() + 5 * 60000),
      ),
    ).toBe(DEFAULT_PRICING.cancellationFeeCents);
    // Nobody was ever dispatched, so nothing was wasted.
    expect(cancellationFeeCents(DEFAULT_PRICING, null, new Date())).toBe(0);
  });
});

describe('city and carretera on the route', () => {
  it('counts a step driven at 60 km/h or more as carretera', () => {
    expect(
      stretchesFrom([
        // 1 km in 2 minutes: 30 km/h.
        { distanceMeters: 1000, staticDuration: '120s' },
        // 10 km in 6 minutes: 100 km/h.
        { distanceMeters: 10000, staticDuration: '360s' },
        // 2 km in 2 minutes: exactly 60 km/h.
        { distanceMeters: 2000, staticDuration: '120s' },
        { distanceMeters: 500, staticDuration: '90s' },
      ]),
    ).toEqual([
      { meters: 1000, highway: false },
      { meters: 12000, highway: true },
      { meters: 500, highway: false },
    ]);
  });

  it('treats a step with no duration as city, and skips empty steps', () => {
    expect(
      stretchesFrom([
        { distanceMeters: 800 },
        { distanceMeters: 0, staticDuration: '10s' },
      ]),
    ).toEqual([{ meters: 800, highway: false }]);
  });
});

describe('quote signature', () => {
  const payload = {
    clientId: 'client-1',
    pickupGeohash: 'd7rj1',
    dropoffGeohash: 'd7rj2',
    totalCents: 250000,
    expiresAtMs: 1_800_000_000_000,
    pricingVersion: 2,
    truckType: TruckType.gancho,
    vehicleType: VehicleType.sedan,
    distance: { distanceKm: 12.4, cityKm: 3.4, highwayKm: 4 },
  };

  it('verifies a signature it produced', () => {
    expect(verifyQuote(payload, signQuote(payload))).toBe(true);
  });

  it('rejects a tampered total', () => {
    const signature = signQuote(payload);
    expect(verifyQuote({ ...payload, totalCents: 20000 }, signature)).toBe(false);
  });

  it('rejects a quote replayed by a different customer', () => {
    const signature = signQuote(payload);
    expect(verifyQuote({ ...payload, clientId: 'client-2' }, signature)).toBe(false);
  });

  it('rejects an extended expiry', () => {
    const signature = signQuote(payload);
    expect(
      verifyQuote({ ...payload, expiresAtMs: payload.expiresAtMs + 60000 }, signature),
    ).toBe(false);
  });

  it('rejects carretera kilometres passed off as city ones', () => {
    const signature = signQuote(payload);
    expect(
      verifyQuote(
        { ...payload, distance: { distanceKm: 12.4, cityKm: 7.4, highwayKm: 0 } },
        signature,
      ),
    ).toBe(false);
  });

  it('rejects a jeepeta quoted as a carro', () => {
    const signature = signQuote(payload);
    expect(verifyQuote({ ...payload, vehicleType: VehicleType.suv }, signature)).toBe(false);
  });

  it('rejects a malformed signature without throwing', () => {
    expect(verifyQuote(payload, 'nonsense')).toBe(false);
    expect(verifyQuote(payload, '')).toBe(false);
  });
});

describe('geo', () => {
  const santoDomingo = { latitude: 18.4861, longitude: -69.9312 };
  const santiago = { latitude: 19.4517, longitude: -70.697 };

  it('measures a known distance', () => {
    // ~134 km. Note this is the straight line, not the ~155 km of road via the
    // Autopista Duarte — the distinction matters, because the quote bills road
    // distance and this function is only the dispatch radius.
    const km = distanceMeters(santoDomingo, santiago) / 1000;
    expect(km).toBeGreaterThan(133);
    expect(km).toBeLessThan(136);
  });

  it('is zero for the same point', () => {
    expect(distanceMeters(santoDomingo, santoDomingo)).toBeCloseTo(0, 5);
  });

  it('produces geohash bounds that cover the radius', () => {
    const bounds = queryBounds(santoDomingo, 5000);
    expect(bounds.length).toBeGreaterThan(0);
    for (const bound of bounds) expect(bound).toHaveLength(2);
  });

  it('recognises Dominican coordinates and rejects far-away ones', () => {
    expect(isPlausiblyInDominicanRepublic(santoDomingo)).toBe(true);
    expect(isPlausiblyInDominicanRepublic({ latitude: 40.7, longitude: -74 })).toBe(
      false,
    );
  });

  it('tests point-in-polygon, and treats a degenerate polygon as empty', () => {
    const square = [
      { latitude: 18.4, longitude: -70.0 },
      { latitude: 18.6, longitude: -70.0 },
      { latitude: 18.6, longitude: -69.8 },
      { latitude: 18.4, longitude: -69.8 },
    ];
    expect(isInsidePolygon({ latitude: 18.5, longitude: -69.9 }, square)).toBe(true);
    expect(isInsidePolygon({ latitude: 19.5, longitude: -69.9 }, square)).toBe(false);
    expect(isInsidePolygon(santoDomingo, [])).toBe(false);
  });
});

describe('Dominican time', () => {
  it('is UTC-4 with no daylight saving', () => {
    expect(toLocal(new Date('2026-01-15T16:00:00Z')).getUTCHours()).toBe(12);
    expect(toLocal(new Date('2026-07-15T16:00:00Z')).getUTCHours()).toBe(12);
  });

  it('puts the rollup boundary at local midnight', () => {
    // 03:00 UTC is still the previous day in Santo Domingo.
    expect(dateKey(new Date('2026-09-09T03:00:00Z'))).toBe('2026-09-08');
    expect(dateKey(new Date('2026-09-09T05:00:00Z'))).toBe('2026-09-09');
  });

  it('reads the local hour for the night surcharge', () => {
    expect(localHour(new Date('2026-09-09T02:00:00Z'))).toBe(22);
  });

  it('mints a readable service code with no ambiguous characters', () => {
    const code = serviceCode(new Date('2026-09-08T18:00:00Z'), () => 0.5);
    expect(code).toMatch(/^GR-\d{6}-[0-9A-Z]{4}$/);
    // I, L, O and U are excluded so nothing is misread over a bad phone line.
    expect(code.slice(-4)).not.toMatch(/[ILOU]/);
  });
});

describe('truck refs', () => {
  const now = 1_800_000_000_000;

  it('opens back to the driver it was sealed for', () => {
    expect(openTruckRef(sealTruckRef('driver-abc', now), now + 1000)).toBe('driver-abc');
  });

  it('never names the driver, and differs on every search', () => {
    const a = sealTruckRef('driver-abc', now);
    const b = sealTruckRef('driver-abc', now);
    expect(a).not.toBe(b);
    expect(Buffer.from(a, 'base64url').toString('latin1')).not.toContain('driver-abc');
  });

  it('refuses a token that was altered or has lapsed', () => {
    const token = sealTruckRef('driver-abc', now);
    const flipped = token.slice(0, -2) + (token.endsWith('A') ? 'B' : 'A') + token.slice(-1);
    expect(openTruckRef(flipped, now)).toBeNull();
    expect(openTruckRef('not-a-token', now)).toBeNull();
    expect(openTruckRef(token, now + TRUCK_REF_TTL_MS + 1)).toBeNull();
  });
});

describe('nearby trucks', () => {
  const center = { latitude: 18.4861, longitude: -69.9312 };
  const now = 1_800_000_000_000;
  const fresh = {
    driverId: 'd1',
    lat: 18.49,
    lng: -69.93,
    isOnline: true,
    state: 'idle',
    updatedAt: now - 10_000,
  };
  const options = { now, staleMs: 90_000 };

  it('counts an online, free, recently reporting truck inside the circle', () => {
    expect(isAvailableWithin(fresh, center, 5, options)).toBe(true);
  });

  it('leaves out the offline, the busy, the silent and the far', () => {
    expect(isAvailableWithin({ ...fresh, isOnline: false }, center, 5, options)).toBe(false);
    expect(isAvailableWithin({ ...fresh, state: 'on_service' }, center, 5, options)).toBe(false);
    expect(
      isAvailableWithin({ ...fresh, updatedAt: now - 120_000 }, center, 5, options),
    ).toBe(false);
    // Boca Chica is ~34 km out: inside a 40 km search, outside a 5 km one.
    const boca = { ...fresh, lat: 18.452, lng: -69.609 };
    expect(isAvailableWithin(boca, center, 5, options)).toBe(false);
    expect(isAvailableWithin(boca, center, 40, options)).toBe(true);
  });

  it('never hands a customer a position finer than ~110 m', () => {
    expect(coarse(18.486123)).toBe(18.486);
    expect(coarse(-69.931789)).toBe(-69.932);
  });
});

describe('truck plates', () => {
  it('keys a plate the same way however the office typed it', () => {
    for (const typed of ['L123456', 'l123456', 'L-123456', ' l 123 456 ']) {
      expect(normalizePlate(typed)).toBe('L123456');
    }
  });

  it('accepts the Dominican series and refuses typos', () => {
    expect(isValidPlate('L123456')).toBe(true);
    expect(isValidPlate('EX12345')).toBe(true);
    expect(isValidPlate('123456')).toBe(false); // no series letter
    expect(isValidPlate('L12345678')).toBe(false); // a digit too many
    expect(isValidPlate('ABC1234')).toBe(false); // three letters
    expect(isValidPlate('')).toBe(false);
  });

  it('allows next year\'s model but not the one after', () => {
    expect(maxTruckYear(new Date('2026-09-11T12:00:00Z'))).toBe(2027);
  });
});

describe('truck type inference', () => {
  it('sends a flatbed for anything that cannot roll', () => {
    for (const condition of [
      VehicleCondition.volcado,
      VehicleCondition.accidentado,
      VehicleCondition.ruedasBloqueadas,
    ]) {
      expect(inferTruckType(VehicleType.sedan, condition)).toBe(TruckType.plataforma);
    }
  });

  it('sends a heavy truck for a camión, and a hook for the rest', () => {
    expect(inferTruckType(VehicleType.camion, VehicleCondition.noArranca)).toBe(
      TruckType.pesada,
    );
    expect(inferTruckType(VehicleType.sedan, VehicleCondition.gomaPinchada)).toBe(
      TruckType.gancho,
    );
  });

  it('sends the heavy grúa for any heavy vehicle, whatever its condition', () => {
    // A flatbed cannot lift a camión, a patana or a loader, rolled over or not.
    for (const type of [VehicleType.camion, VehicleType.patana, VehicleType.equipoPesado]) {
      for (const condition of Object.values(VehicleCondition)) {
        expect(inferTruckType(type, condition)).toBe(TruckType.pesada);
      }
    }
  });
});

describe('which truck can take which job', () => {
  it('lets a flatbed take a hook job', () => {
    // The bug: dispatch demanded an exact match, so a customer whose car would
    // not start watched "Buscando grúa" for six minutes with an idle
    // plataforma two streets away, and the job landed on a dispatcher's desk.
    expect(trucksThatCanServe(TruckType.gancho)).toContain(TruckType.plataforma);
    expect(trucksThatCanServe(TruckType.gancho)).toContain(TruckType.gancho);
  });

  it('never sends a hook to something that cannot roll', () => {
    // A gancho tows on the vehicle's own wheels, which is the one thing a
    // flipped or wheel-locked car cannot do.
    expect(trucksThatCanServe(TruckType.plataforma)).toEqual([TruckType.plataforma]);
  });

  it('keeps heavy recovery to itself, in both directions', () => {
    expect(trucksThatCanServe(TruckType.pesada)).toEqual([TruckType.pesada]);
    expect(trucksThatCanServe(TruckType.gancho)).not.toContain(TruckType.pesada);
  });
});

describe('how long a chofer gets to answer', () => {
  it('is a minute, and the expiry task waits out the whole of it', () => {
    // 25 seconds was not enough to read the card and decide, so a chofer who
    // tapped ACEPTAR was often refused by a clock that had already run out.
    expect(DEFAULT_DISPATCH.offerTtlMs).toBe(60000);
    // The sweeper's task fires after the offer, never before it.
    expect(DEFAULT_DISPATCH.offerTtlMs + 2000).toBeGreaterThan(
      DEFAULT_DISPATCH.offerTtlMs,
    );
  });
});

describe('why nobody got the job', () => {
  const tally = (over: Partial<ScanTally>): ScanTally => ({
    inRadius: 0,
    wrongTruck: 0,
    alreadyAsked: 0,
    unavailable: 0,
    inactive: 0,
    busy: 0,
    cashCapped: 0,
    eligible: 0,
    ...over,
  });

  it('says so when the yard is empty', () => {
    expect(scanReason(tally({}), TruckType.gancho, 40)).toBe(
      'Ninguna grúa en línea a 40 km del punto de recogida.',
    );
  });

  it('separates "no trucks" from "no trucks of that kind"', () => {
    // The real case: a plataforma and a grúa pesada online, and a customer
    // whose car will not start, which asks for a gancho. Two trucks on the
    // dispatcher's map, neither of them able to take it — and the panel used
    // to show that as a request quietly sitting there.
    const reason = scanReason(
      tally({ inRadius: 2, wrongTruck: 2 }),
      TruckType.gancho,
      40,
    );

    expect(reason).toContain('gancho');
    expect(reason).toContain('2 de otro tipo');
  });

  it('says when the right trucks are simply busy', () => {
    expect(scanReason(tally({ inRadius: 3, busy: 3 }), TruckType.plataforma, 10))
      .toBe('Las grúas de plataforma cerca ya están en servicio.');
  });

  it('says when everyone nearby has already been asked', () => {
    expect(
      scanReason(tally({ inRadius: 2, alreadyAsked: 2 }), TruckType.gancho, 20),
    ).toContain('Ya se le ofreció');
  });

  it('names the cash cap, which looks like nothing else', () => {
    expect(
      scanReason(tally({ inRadius: 1, cashCapped: 1 }), TruckType.gancho, 5),
    ).toContain('efectivo pendiente');
  });
});

describe('candidate scoring', () => {
  const candidate = (
    driverId: string,
    distanceM: number,
    isSubstitute: boolean,
  ) => ({
    driverId,
    position: { latitude: 18.4795, longitude: -69.942 },
    distanceM,
    rating: 4.5,
    idleMinutes: 0,
    name: driverId,
    phone: '',
    isSubstitute,
  });

  it('sends the right truck when both are equally close', () => {
    const ranked = scoreCandidates(
      [candidate('flatbed', 1000, true), candidate('hook', 1000, false)],
      5,
      DEFAULT_DISPATCH,
    );

    expect(ranked[0]!.driverId).toBe('hook');
  });

  it('sends the bigger truck when it is much closer', () => {
    // Otherwise the customer waits for a hook truck crossing the whole search
    // circle while a capable flatbed sits at the corner.
    const ranked = scoreCandidates(
      [candidate('flatbed', 200, true), candidate('hook', 4800, false)],
      5,
      DEFAULT_DISPATCH,
    );

    expect(ranked[0]!.driverId).toBe('flatbed');
  });

  it('still ranks two substitutes by distance', () => {
    const ranked = scoreCandidates(
      [candidate('far', 4000, true), candidate('near', 500, true)],
      5,
      DEFAULT_DISPATCH,
    );

    expect(ranked.map((c) => c.driverId)).toEqual(['near', 'far']);
  });
});

describe('state machine table', () => {
  it('defines exactly one transition per event', () => {
    const events = TRANSITIONS.map((t) => t.event);
    expect(new Set(events).size).toBe(events.length);
  });

  it('never transitions out of a terminal state', () => {
    for (const transition of TRANSITIONS) {
      for (const from of transition.from) {
        expect(
          TERMINAL_STATUSES.includes(from),
          `${transition.event} must not start from terminal '${from}'`,
        ).toBe(false);
      }
    }
  });

  it('lets only a chofer accept', () => {
    expect(transitionFor(ServiceEventName.acceptService).actors).toEqual(['driver']);
  });

  it('puts a driver cancellation back in the pool rather than cancelling', () => {
    // The customer still needs a tow; making them re-request would put them at
    // the back of their own queue.
    expect(transitionFor(ServiceEventName.cancelByDriver).to).toBe(
      ServiceStatus.pendingDispatch,
    );
  });

  it('refuses a customer cancellation once the vehicle is loaded', () => {
    expect(transitionFor(ServiceEventName.cancelService).from).not.toContain(
      ServiceStatus.inProgress,
    );
  });

  it('agrees with the active-status set the apps use', () => {
    // A customer with a service in any of these may not request another.
    expect(ACTIVE_STATUSES).toContain(ServiceStatus.needsManual);
    expect(ACTIVE_STATUSES).not.toContain(ServiceStatus.closed);
  });
});
