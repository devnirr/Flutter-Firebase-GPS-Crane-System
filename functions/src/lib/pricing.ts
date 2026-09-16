import { createHmac, timingSafeEqual } from 'node:crypto';

import { TruckType, VehicleType, isHeavyVehicle } from './enums.js';
import { Paths } from './firestore.js';
import type { RoadStretch } from './routes.js';
import { dateKey, localHour } from './time.js';

/**
 * The pricing formula and the quote signature.
 *
 * Ported from `packages/grua_core/lib/src/data/pricing.dart`. The app runs the
 * same arithmetic to show a customer what a tow will cost before they commit;
 * this side decides what they are actually charged. When the two disagree the
 * server wins and the customer sees the price change at the worst possible
 * moment, so an edit here is an edit there.
 *
 * The tariff:
 *
 * 1. Every vehicle type has a tarifa base, which includes the first
 *    [PricingConfig.includedKm] kilometres of the trip. No service costs less
 *    than [PricingConfig.minimumCents].
 * 2. After those, each kilometre is charged at the city or the carretera rate,
 *    by the kind of road it is driven on. Heavy vehicles have one rate per type.
 * 3. Between 22:00 and 06:00 a night surcharge goes on top: 30% for a light
 *    vehicle, 40% for a heavy one.
 * 4. A heavy vehicle's price is only an estimate until an operator confirms it.
 *
 * Everything is integer Dominican peso cents.
 */

export interface PricingConfig {
  version: number;
  /** Tarifa base per vehicle type, keyed by its wire value. */
  baseCentsByVehicleType: Record<string, number>;
  /** Per kilometre past the included ones, on city streets. */
  cityPerKmCentsByVehicleType: Record<string, number>;
  /** Per kilometre past the included ones, on carretera and autopista. */
  highwayPerKmCentsByVehicleType: Record<string, number>;
  includedKm: number;
  /** The least any service costs, before surcharges. */
  minimumCents: number;
  /** On the total, for a light vehicle. 3000 = 30%. */
  lightNightSurchargeBps: number;
  /** On the total, for a heavy vehicle. 4000 = 40%. */
  heavyNightSurchargeBps: number;
  nightStartHour: number;
  nightEndHour: number;
  holidaySurchargeBps: number;
  holidayDates: string[];
  freeWaitingMinutes: number;
  perWaitingMinuteCents: number;
  commissionBps: number;
  cancellationFeeCents: number;
  cancellationGraceMinutes: number;
  maxCashOwedCents: number;
  chargeItbis: boolean;
}

export const DEFAULT_PRICING: PricingConfig = {
  version: 2,
  baseCentsByVehicleType: {
    [VehicleType.sedan]: 150000,
    [VehicleType.suv]: 180000,
    [VehicleType.camioneta]: 200000,
    [VehicleType.motor]: 150000,
    [VehicleType.camion]: 500000,
    [VehicleType.patana]: 800000,
    [VehicleType.equipoPesado]: 1000000,
  },
  cityPerKmCentsByVehicleType: {
    [VehicleType.sedan]: 7000,
    [VehicleType.suv]: 7000,
    [VehicleType.camioneta]: 7000,
    [VehicleType.motor]: 7000,
    [VehicleType.camion]: 25000,
    [VehicleType.patana]: 40000,
    [VehicleType.equipoPesado]: 60000,
  },
  highwayPerKmCentsByVehicleType: {
    [VehicleType.sedan]: 13000,
    [VehicleType.suv]: 13000,
    [VehicleType.camioneta]: 13000,
    [VehicleType.motor]: 13000,
    [VehicleType.camion]: 25000,
    [VehicleType.patana]: 40000,
    [VehicleType.equipoPesado]: 60000,
  },
  includedKm: 5,
  minimumCents: 150000,
  lightNightSurchargeBps: 3000,
  heavyNightSurchargeBps: 4000,
  nightStartHour: 22,
  nightEndHour: 6,
  holidaySurchargeBps: 2000,
  holidayDates: [],
  freeWaitingMinutes: 10,
  perWaitingMinuteCents: 2500,
  commissionBps: 2000,
  cancellationFeeCents: 50000,
  cancellationGraceMinutes: 3,
  maxCashOwedCents: 1500000,
  chargeItbis: true,
};

export interface Surcharge {
  code: string;
  label: string;
  cents: number;
}

export interface Quote {
  pricingVersion: number;
  vehicleType: VehicleType;
  /** A heavy vehicle: the total is an estimate until an operator confirms it. */
  heavy: boolean;
  baseCents: number;
  includedKm: number;
  /** The whole trip, to a tenth of a kilometre. */
  distanceKm: number;
  /** Charged kilometres on city streets, past the included ones. */
  cityKm: number;
  /** Charged kilometres on carretera, past the included ones. */
  highwayKm: number;
  cityPerKmCents: number;
  highwayPerKmCents: number;
  /** The city rate, kept for readers of quotes written before the split. */
  perKmCents: number;
  distanceCents: number;
  /** What was added to bring a short, cheap trip up to the minimum. */
  minimumAdjustmentCents: number;
  surcharges: Surcharge[];
  subtotalCents: number;
  itbisCents: number;
  totalCents: number;
  currency: 'DOP';
}

/**
 * The trip as the tariff sees it: its length, and how many of the charged
 * kilometres — those past the included ones — are city and how many carretera.
 */
export interface TripDistance {
  distanceKm: number;
  cityKm: number;
  highwayKm: number;
}

/** Applies a basis-point rate exactly — 12.5% is 1250, with no float drift. */
export const bps = (cents: number, basisPoints: number): number =>
  Math.round((cents * basisPoints) / 10000);

/** To the nearest whole peso: nobody hands a chofer 51 centavos. */
export const toPeso = (cents: number): number => Math.round(cents / 100) * 100;

export const ITBIS_BPS = 1800;

const rateFor = (rates: Record<string, number>, type: VehicleType): number =>
  rates[type] ?? rates[VehicleType.sedan] ?? 0;

export const baseCentsFor = (config: PricingConfig, type: VehicleType): number =>
  rateFor(config.baseCentsByVehicleType, type);

/** Night rate spans midnight, so this is an OR, not a range. */
export function isNightHour(config: PricingConfig, hour: number): boolean {
  return hour >= config.nightStartHour || hour < config.nightEndHour;
}

/**
 * Which kilometres are charged, and on what kind of road.
 *
 * Literally "the first 5 km are included": the included distance is taken from
 * the start of the trip, in driving order, and what is left is charged at the
 * rate of the road it is on. Worked in tenths of a kilometre so the parts
 * always add up to the whole.
 */
export function tripDistance(stretches: RoadStretch[], includedKm: number): TripDistance {
  let skip = includedKm * 1000;
  let totalMeters = 0;
  let highwayMeters = 0;

  for (const stretch of stretches) {
    totalMeters += stretch.meters;
    const charged = Math.max(0, stretch.meters - skip);
    skip = Math.max(0, skip - stretch.meters);
    if (stretch.highway) highwayMeters += charged;
  }

  const totalTenths = Math.round(totalMeters / 100);
  const chargedTenths = Math.max(0, totalTenths - Math.round(includedKm * 10));
  const highwayTenths = Math.min(chargedTenths, Math.round(highwayMeters / 100));

  return {
    distanceKm: totalTenths / 10,
    cityKm: (chargedTenths - highwayTenths) / 10,
    highwayKm: highwayTenths / 10,
  };
}

/** A trip with no road information: all of it priced as city. */
export const cityTrip = (distanceKm: number, includedKm: number): TripDistance =>
  tripDistance([{ meters: distanceKm * 1000, highway: false }], includedKm);

export interface QuoteInput {
  config: PricingConfig;
  vehicleType: VehicleType;
  distance: TripDistance;
  at: Date;
  chargeItbis?: boolean;
  waitingMinutes?: number;
  tollsCents?: number;
}

export function buildQuote(input: QuoteInput): Quote {
  const {
    config,
    vehicleType,
    distance,
    at,
    chargeItbis = true,
    waitingMinutes = 0,
    tollsCents = 0,
  } = input;

  const heavy = isHeavyVehicle(vehicleType);
  const baseCents = baseCentsFor(config, vehicleType);
  const cityPerKmCents = rateFor(config.cityPerKmCentsByVehicleType, vehicleType);
  const highwayPerKmCents = rateFor(config.highwayPerKmCentsByVehicleType, vehicleType);

  const distanceCents =
    Math.round(distance.cityKm * cityPerKmCents) +
    Math.round(distance.highwayKm * highwayPerKmCents);

  const minimumAdjustmentCents = Math.max(
    0,
    config.minimumCents - (baseCents + distanceCents),
  );
  // What the percentages are taken from: the tow itself, not waiting or tolls.
  const fareCents = baseCents + distanceCents + minimumAdjustmentCents;

  const surcharges: Surcharge[] = [];

  // Evaluated in Dominican local time. Using the UTC hour here would start the
  // night rate at 6 p.m.
  if (isNightHour(config, localHour(at))) {
    const rate = heavy ? config.heavyNightSurchargeBps : config.lightNightSurchargeBps;
    surcharges.push({
      code: 'nocturno',
      label: `Recargo nocturno (${rate / 100}%)`,
      cents: toPeso(bps(fareCents, rate)),
    });
  }

  if (config.holidayDates.includes(dateKey(at))) {
    surcharges.push({
      code: 'feriado',
      label: 'Recargo por día feriado',
      cents: toPeso(bps(fareCents, config.holidaySurchargeBps)),
    });
  }

  const billableWaiting = Math.max(0, waitingMinutes - config.freeWaitingMinutes);
  if (billableWaiting > 0) {
    surcharges.push(waitingSurcharge(config, billableWaiting));
  }

  if (tollsCents > 0) {
    surcharges.push({ code: 'peajes', label: 'Peajes', cents: tollsCents });
  }

  const surchargeTotal = surcharges.reduce((sum, s) => sum + s.cents, 0);
  const subtotalCents = fareCents + surchargeTotal;
  const itbisCents =
    chargeItbis && config.chargeItbis ? bps(subtotalCents, ITBIS_BPS) : 0;

  return {
    pricingVersion: config.version,
    vehicleType,
    heavy,
    baseCents,
    includedKm: config.includedKm,
    distanceKm: distance.distanceKm,
    cityKm: distance.cityKm,
    highwayKm: distance.highwayKm,
    cityPerKmCents,
    highwayPerKmCents,
    perKmCents: cityPerKmCents,
    distanceCents,
    minimumAdjustmentCents,
    surcharges,
    subtotalCents,
    itbisCents,
    totalCents: subtotalCents + itbisCents,
    currency: 'DOP',
  };
}

function waitingSurcharge(config: PricingConfig, billableMinutes: number): Surcharge {
  return {
    code: 'espera',
    label: `Tiempo de espera (${billableMinutes} min)`,
    cents: billableMinutes * config.perWaitingMinuteCents,
  };
}

/** Re-totals a quote after its lines changed, keeping ITBIS if it had it. */
function retotal(quote: Quote, subtotalCents: number): Quote {
  const itbisCents = quote.itbisCents > 0 ? bps(subtotalCents, ITBIS_BPS) : 0;
  return {
    ...quote,
    subtotalCents,
    itbisCents,
    totalCents: subtotalCents + itbisCents,
  };
}

/**
 * The price a finished job is charged: the one the customer agreed to, plus
 * any waiting past the free minutes.
 *
 * Not the formula run again at completion. A tow asked for at 21:50 and
 * finished at 22:40 was quoted without the night rate, and a heavy job's price
 * was set by an operator; re-running the tariff would undo both.
 */
export function finalQuote(
  quote: Quote,
  config: PricingConfig,
  waitingMinutes: number,
): Quote {
  const billable = Math.max(0, waitingMinutes - config.freeWaitingMinutes);
  if (billable <= 0) return quote;
  const line = waitingSurcharge(config, billable);
  return retotal(
    { ...quote, surcharges: [...(quote.surcharges ?? []), line] },
    quote.subtotalCents + line.cents,
  );
}

/**
 * The quote with the total an operator confirmed for a heavy job.
 *
 * The difference goes on as its own line, so the receipt still shows the
 * estimate it started from and what the operator changed. The operator types
 * what the customer pays, ITBIS included when there is any.
 */
export function confirmedQuote(quote: Quote, totalCents: number): Quote {
  const subtotalCents =
    quote.itbisCents > 0
      ? Math.round((totalCents * 10000) / (10000 + ITBIS_BPS))
      : totalCents;
  const adjustment = subtotalCents - quote.subtotalCents;
  const surcharges = (quote.surcharges ?? []).filter((s) => s.code !== 'ajuste_operador');
  const previous = (quote.surcharges ?? []).find((s) => s.code === 'ajuste_operador');
  const lineCents = adjustment + (previous?.cents ?? 0);
  if (lineCents !== 0) {
    surcharges.push({
      code: 'ajuste_operador',
      label: 'Ajuste confirmado por el operador',
      cents: lineCents,
    });
  }
  const itbisCents = quote.itbisCents > 0 ? totalCents - subtotalCents : 0;
  return {
    ...quote,
    surcharges,
    subtotalCents,
    itbisCents,
    totalCents: subtotalCents + itbisCents,
  };
}

/** What a customer owes for cancelling after the grace period. */
export function cancellationFeeCents(
  config: PricingConfig,
  acceptedAt: Date | null,
  now: Date,
): number {
  if (!acceptedAt) return 0;
  const graceMs = config.cancellationGraceMinutes * 60 * 1000;
  if (now.getTime() - acceptedAt.getTime() <= graceMs) return 0;
  return config.cancellationFeeCents;
}

export const commissionCents = (
  config: PricingConfig,
  grossCents: number,
): number => bps(grossCents, config.commissionBps);

/**
 * Reads the live tariff, falling back to defaults for anything not set.
 *
 * The rate tables merge per vehicle type, so a stored document that sets only
 * the patana's base keeps every other type's default.
 */
export async function loadPricing(): Promise<PricingConfig> {
  const snap = await Paths.pricingConfig().get();
  return mergePricing(snap.data() as Partial<PricingConfig> | undefined);
}

export function mergePricing(stored: Partial<PricingConfig> | undefined): PricingConfig {
  const s = stored ?? {};
  return {
    ...DEFAULT_PRICING,
    ...s,
    baseCentsByVehicleType: {
      ...DEFAULT_PRICING.baseCentsByVehicleType,
      ...s.baseCentsByVehicleType,
    },
    cityPerKmCentsByVehicleType: {
      ...DEFAULT_PRICING.cityPerKmCentsByVehicleType,
      ...s.cityPerKmCentsByVehicleType,
    },
    highwayPerKmCentsByVehicleType: {
      ...DEFAULT_PRICING.highwayPerKmCentsByVehicleType,
      ...s.highwayPerKmCentsByVehicleType,
    },
  };
}

// ---------------------------------------------------------------------------
// Quote signing
// ---------------------------------------------------------------------------

/**
 * The secret backing the quote signature.
 *
 * In production this comes from Secret Manager. The development fallback is
 * deliberately obvious: a signature is only worth anything if the key is, and a
 * silent default in production would make the whole mechanism decorative.
 */
export function signingSecret(): string {
  const secret = process.env['QUOTE_SIGNING_SECRET'];
  if (secret && secret.length > 0) return secret;
  if (process.env.FUNCTIONS_EMULATOR === 'true') return 'emulator-only-secret';
  throw new Error(
    'QUOTE_SIGNING_SECRET is not set. Quotes cannot be signed, so requests ' +
      'would be priced by the caller.',
  );
}

export interface QuoteSignaturePayload {
  clientId: string;
  pickupGeohash: string;
  dropoffGeohash: string;
  totalCents: number;
  expiresAtMs: number;
  pricingVersion: number;
  truckType: TruckType;
  vehicleType: VehicleType;
  /**
   * The road split the quote was priced on. Signed because `requestService`
   * prices from these rather than asking Google again a minute later, when the
   * answer could differ by a few hundred metres and refuse the request.
   */
  distance: TripDistance;
}

/**
 * Signs the priced inputs.
 *
 * Without this a modified client could send back a quote of its own invention
 * and request a RD$200 tow to Puerto Plata. `requestService` recomputes the
 * price from the same inputs and refuses a mismatch, so the signature only has
 * to prove the inputs are the ones we priced.
 */
export function signQuote(payload: QuoteSignaturePayload): string {
  const canonical = [
    payload.clientId,
    payload.pickupGeohash,
    payload.dropoffGeohash,
    payload.totalCents,
    payload.expiresAtMs,
    payload.pricingVersion,
    payload.truckType,
    payload.vehicleType,
    payload.distance.distanceKm.toFixed(1),
    payload.distance.cityKm.toFixed(1),
    payload.distance.highwayKm.toFixed(1),
  ].join('|');

  return createHmac('sha256', signingSecret()).update(canonical).digest('hex');
}

/** Constant-time comparison, so a wrong signature leaks nothing by timing. */
export function verifyQuote(
  payload: QuoteSignaturePayload,
  signature: string,
): boolean {
  const expected = Buffer.from(signQuote(payload), 'utf8');
  const actual = Buffer.from(signature, 'utf8');
  if (expected.length !== actual.length) return false;
  return timingSafeEqual(expected, actual);
}
