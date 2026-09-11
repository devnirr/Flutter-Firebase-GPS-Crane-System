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
} from '../src/lib/enums.js';
import {
  DEFAULT_PRICING,
  authorizationAmountCents,
  bps,
  buildQuote,
  cancellationFeeCents,
  commissionCents,
  signQuote,
  verifyQuote,
} from '../src/lib/pricing.js';
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
  it('charges nothing for distance inside the included kilometres', () => {
    const quote = buildQuote({
      config: DEFAULT_PRICING,
      truckType: TruckType.gancho,
      distanceKm: DEFAULT_PRICING.includedKm,
      at: atLocalHour(12),
      chargeItbis: false,
    });
    expect(quote.distanceCents).toBe(0);
    expect(quote.totalCents).toBe(DEFAULT_PRICING.baseCentsByTruckType['gancho']);
  });

  it('charges only the excess kilometres', () => {
    const quote = buildQuote({
      config: DEFAULT_PRICING,
      truckType: TruckType.gancho,
      distanceKm: DEFAULT_PRICING.includedKm + 10,
      at: atLocalHour(12),
      chargeItbis: false,
    });
    expect(quote.distanceCents).toBe(
      10 * DEFAULT_PRICING.perKmCentsByTruckType['gancho']!,
    );
  });

  it('starts the night surcharge at 22:00 local, not 22:00 UTC', () => {
    const evening = buildQuote({
      config: DEFAULT_PRICING,
      truckType: TruckType.gancho,
      distanceKm: 10,
      at: atLocalHour(21),
      chargeItbis: false,
    });
    const night = buildQuote({
      config: DEFAULT_PRICING,
      truckType: TruckType.gancho,
      distanceKm: 10,
      at: atLocalHour(22),
      chargeItbis: false,
    });

    expect(evening.surcharges.some((s) => s.code === 'nocturno')).toBe(false);
    expect(night.surcharges.some((s) => s.code === 'nocturno')).toBe(true);
    expect(night.totalCents).toBeGreaterThan(evening.totalCents);
  });

  it('applies the night surcharge across midnight and stops at 06:00', () => {
    for (const hour of [23, 0, 3, 5]) {
      const quote = buildQuote({
        config: DEFAULT_PRICING,
        truckType: TruckType.gancho,
        distanceKm: 10,
        at: atLocalHour(hour),
        chargeItbis: false,
      });
      expect(
        quote.surcharges.some((s) => s.code === 'nocturno'),
        `${hour}:00 local should be a night hour`,
      ).toBe(true);
    }

    const morning = buildQuote({
      config: DEFAULT_PRICING,
      truckType: TruckType.gancho,
      distanceKm: 10,
      at: atLocalHour(6),
      chargeItbis: false,
    });
    expect(morning.surcharges.some((s) => s.code === 'nocturno')).toBe(false);
  });

  it('bills only waiting time past the free window', () => {
    const free = buildQuote({
      config: DEFAULT_PRICING,
      truckType: TruckType.gancho,
      distanceKm: 10,
      at: atLocalHour(12),
      waitingMinutes: DEFAULT_PRICING.freeWaitingMinutes,
      chargeItbis: false,
    });
    expect(free.surcharges.some((s) => s.code === 'espera')).toBe(false);

    const over = buildQuote({
      config: DEFAULT_PRICING,
      truckType: TruckType.gancho,
      distanceKm: 10,
      at: atLocalHour(12),
      waitingMinutes: DEFAULT_PRICING.freeWaitingMinutes + 7,
      chargeItbis: false,
    });
    expect(over.surcharges.find((s) => s.code === 'espera')?.cents).toBe(
      7 * DEFAULT_PRICING.perWaitingMinuteCents,
    );
  });

  it('applies ITBIS at 18% only when a fiscal receipt is issued', () => {
    const fiscal = buildQuote({
      config: DEFAULT_PRICING,
      truckType: TruckType.gancho,
      distanceKm: 20,
      at: atLocalHour(12),
    });
    expect(fiscal.itbisCents).toBe(Math.round(fiscal.subtotalCents * 0.18));
    expect(fiscal.totalCents).toBe(fiscal.subtotalCents + fiscal.itbisCents);

    const consumo = buildQuote({
      config: DEFAULT_PRICING,
      truckType: TruckType.gancho,
      distanceKm: 20,
      at: atLocalHour(12),
      chargeItbis: false,
    });
    expect(consumo.itbisCents).toBe(0);
  });

  it('prices heavier trucks above lighter ones for the same distance', () => {
    const total = (type: TruckType): number =>
      buildQuote({
        config: DEFAULT_PRICING,
        truckType: type,
        distanceKm: 20,
        at: atLocalHour(12),
        chargeItbis: false,
      }).totalCents;

    expect(total(TruckType.pesada)).toBeGreaterThan(total(TruckType.plataforma));
    expect(total(TruckType.plataforma)).toBeGreaterThan(total(TruckType.gancho));
  });

  it('computes basis points exactly at awkward rates', () => {
    expect(bps(100000, 1250)).toBe(12500);
    expect(commissionCents(DEFAULT_PRICING, 100000)).toBe(20000);
    expect(authorizationAmountCents(DEFAULT_PRICING, 100000)).toBe(115000);
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

describe('quote signature', () => {
  const payload = {
    clientId: 'client-1',
    pickupGeohash: 'd7rj1',
    dropoffGeohash: 'd7rj2',
    totalCents: 250000,
    expiresAtMs: 1_800_000_000_000,
    pricingVersion: 1,
    truckType: TruckType.gancho,
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

  it('prefers the flatbed rule over the vehicle type', () => {
    // A rolled-over camión still cannot roll; condition wins.
    expect(inferTruckType(VehicleType.camion, VehicleCondition.volcado)).toBe(
      TruckType.plataforma,
    );
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
