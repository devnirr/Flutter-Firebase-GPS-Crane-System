import { createHmac, timingSafeEqual } from 'node:crypto';

import { TruckType } from './enums.js';
import { Paths } from './firestore.js';
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
 * Everything is integer Dominican peso cents.
 */

export interface PricingConfig {
  version: number;
  baseCentsByTruckType: Record<string, number>;
  includedKm: number;
  perKmCentsByTruckType: Record<string, number>;
  nightSurchargeBps: number;
  nightStartHour: number;
  nightEndHour: number;
  holidaySurchargeBps: number;
  holidayDates: string[];
  freeWaitingMinutes: number;
  perWaitingMinuteCents: number;
  commissionBps: number;
  cancellationFeeCents: number;
  cancellationGraceMinutes: number;
  authorizationBufferBps: number;
  maxCashOwedCents: number;
  chargeItbis: boolean;
}

export const DEFAULT_PRICING: PricingConfig = {
  version: 1,
  baseCentsByTruckType: { plataforma: 180000, gancho: 150000, pesada: 450000 },
  includedKm: 5,
  perKmCentsByTruckType: { plataforma: 6500, gancho: 5500, pesada: 14000 },
  nightSurchargeBps: 2500,
  nightStartHour: 22,
  nightEndHour: 6,
  holidaySurchargeBps: 2000,
  holidayDates: [],
  freeWaitingMinutes: 10,
  perWaitingMinuteCents: 2500,
  commissionBps: 2000,
  cancellationFeeCents: 50000,
  cancellationGraceMinutes: 3,
  authorizationBufferBps: 1500,
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
  baseCents: number;
  includedKm: number;
  perKmCents: number;
  distanceKm: number;
  distanceCents: number;
  surcharges: Surcharge[];
  subtotalCents: number;
  itbisCents: number;
  totalCents: number;
  currency: 'DOP';
}

/** Applies a basis-point rate exactly — 12.5% is 1250, with no float drift. */
export const bps = (cents: number, basisPoints: number): number =>
  Math.round((cents * basisPoints) / 10000);

export const ITBIS_BPS = 1800;

export function baseCentsFor(config: PricingConfig, type: TruckType): number {
  return config.baseCentsByTruckType[type] ?? config.baseCentsByTruckType['gancho'] ?? 150000;
}

export function perKmCentsFor(config: PricingConfig, type: TruckType): number {
  return config.perKmCentsByTruckType[type] ?? config.perKmCentsByTruckType['gancho'] ?? 5500;
}

/** Night rate spans midnight, so this is an OR, not a range. */
export function isNightHour(config: PricingConfig, hour: number): boolean {
  return hour >= config.nightStartHour || hour < config.nightEndHour;
}

export interface QuoteInput {
  config: PricingConfig;
  truckType: TruckType;
  distanceKm: number;
  at: Date;
  chargeItbis?: boolean;
  waitingMinutes?: number;
  tollsCents?: number;
}

export function buildQuote(input: QuoteInput): Quote {
  const {
    config,
    truckType,
    distanceKm,
    at,
    chargeItbis = true,
    waitingMinutes = 0,
    tollsCents = 0,
  } = input;

  const baseCents = baseCentsFor(config, truckType);
  const perKmCents = perKmCentsFor(config, truckType);

  const billableKm = Math.max(0, distanceKm - config.includedKm);
  const distanceCents = Math.round(billableKm * perKmCents);

  const surcharges: Surcharge[] = [];

  // Evaluated in Dominican local time. Using the UTC hour here would start the
  // night rate at 6 p.m.
  if (isNightHour(config, localHour(at))) {
    surcharges.push({
      code: 'nocturno',
      label: 'Recargo nocturno',
      cents: bps(baseCents, config.nightSurchargeBps),
    });
  }

  if (config.holidayDates.includes(dateKey(at))) {
    surcharges.push({
      code: 'feriado',
      label: 'Recargo por día feriado',
      cents: bps(baseCents, config.holidaySurchargeBps),
    });
  }

  const billableWaiting = Math.max(0, waitingMinutes - config.freeWaitingMinutes);
  if (billableWaiting > 0) {
    surcharges.push({
      code: 'espera',
      label: `Tiempo de espera (${billableWaiting} min)`,
      cents: billableWaiting * config.perWaitingMinuteCents,
    });
  }

  if (tollsCents > 0) {
    surcharges.push({ code: 'peajes', label: 'Peajes', cents: tollsCents });
  }

  const surchargeTotal = surcharges.reduce((sum, s) => sum + s.cents, 0);
  const subtotalCents = baseCents + distanceCents + surchargeTotal;
  const itbisCents =
    chargeItbis && config.chargeItbis ? bps(subtotalCents, ITBIS_BPS) : 0;

  return {
    pricingVersion: config.version,
    baseCents,
    includedKm: config.includedKm,
    perKmCents,
    distanceKm,
    distanceCents,
    surcharges,
    subtotalCents,
    itbisCents,
    totalCents: subtotalCents + itbisCents,
    currency: 'DOP',
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

/**
 * What to hold on the card at accept time: the quote plus headroom for waiting
 * and reroutes, so a normal job needs one authorization and one capture rather
 * than a second charge the customer did not expect.
 */
export const authorizationAmountCents = (
  config: PricingConfig,
  quoteTotalCents: number,
): number => quoteTotalCents + bps(quoteTotalCents, config.authorizationBufferBps);

export const commissionCents = (
  config: PricingConfig,
  grossCents: number,
): number => bps(grossCents, config.commissionBps);

/** Reads the live tariff, falling back to defaults if it has not been seeded. */
export async function loadPricing(): Promise<PricingConfig> {
  const snap = await Paths.pricingConfig().get();
  return { ...DEFAULT_PRICING, ...(snap.data() as Partial<PricingConfig> | undefined) };
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
