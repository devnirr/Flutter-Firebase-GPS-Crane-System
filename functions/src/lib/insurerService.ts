import { createHmac, timingSafeEqual } from 'node:crypto';

import { z } from 'zod';

import { VehicleType, isHeavyVehicle } from './enums.js';
import { type Quote, bps, signingSecret } from './pricing.js';
import { type ZoneQuote, withItbis } from './zonePricing.js';

/**
 * A tow ordered by an insurance company, before it touches the database.
 *
 * Three things are decided here:
 *
 * - **What the form must hold.** The claim number is required: the insurer
 *   cannot bill its own policyholder's file without it.
 * - **Who gets what.** The chofer takes a share of the zone price — before
 *   ITBIS, before any surcharge — and the company keeps the rest. The share is
 *   fixed on the tow when it is ordered, so a later change to the company's
 *   rate never rewrites a job already done.
 * - **That the price the operator saw is the price billed.** The preview is
 *   signed; ordering with that signature bills the distance it was priced on,
 *   not a second answer from Google a minute later.
 */

/** The chofer's share of an insurer's tow when the company sets none: 70%. */
export const DEFAULT_DRIVER_PAYOUT_BPS = 7000;

/** A share in basis points, 0–100%. */
export const payoutBpsSchema = z.number().int().min(0).max(10_000);

export interface PayoutSplit {
  driverPayoutBps: number;
  /** What the chofer is owed. */
  driverPayoutCents: number;
  /** What the company keeps, before the ITBIS it collects and passes on. */
  platformCents: number;
}

/**
 * Splits a price between the chofer and the company.
 *
 * The chofer's share is rounded to the whole peso and the company keeps the
 * remainder, so the two always add up to the price exactly.
 */
export function payoutSplit(subtotalCents: number, driverPayoutBps: number): PayoutSplit {
  const raw = bps(subtotalCents, driverPayoutBps);
  const driverPayoutCents = Math.min(subtotalCents, Math.round(raw / 100) * 100);
  return {
    driverPayoutBps,
    driverPayoutCents,
    platformCents: subtotalCents - driverPayoutCents,
  };
}

/** The company's share setting, or the default when it has none. */
export function driverPayoutBpsOf(insurer: Record<string, unknown> | undefined): number {
  const parsed = payoutBpsSchema.safeParse(insurer?.['driverPayoutBps']);
  return parsed.success ? parsed.data : DEFAULT_DRIVER_PAYOUT_BPS;
}

const point = z.object({
  latitude: z.number().min(-90).max(90),
  longitude: z.number().min(-180).max(180),
});

const place = z.object({
  geo: point,
  address: z.string().trim().max(300).default(''),
  reference: z.string().trim().max(300).default(''),
  placeId: z.string().max(200).default(''),
  notes: z.string().trim().max(500).default(''),
});

// Digits, spaces and the punctuation people type in a Dominican number.
const phone = z
  .string()
  .trim()
  .max(20)
  .regex(/^[\d\s()+-]*$/, 'Teléfono inválido');

const pricedVehicleType = z
  .nativeEnum(VehicleType)
  .describe('The column of the tariff the tow is priced in.');

export const quoteInsurerServiceInput = z.object({
  pickup: place,
  dropoff: place,
  vehicleType: pricedVehicleType,
});

export const createInsurerServiceInput = z.object({
  pickup: place,
  dropoff: place,
  vehicle: z.object({
    type: pricedVehicleType,
    plate: z.string().trim().toUpperCase().max(20).default(''),
    make: z.string().trim().max(60).default(''),
    model: z.string().trim().max(60).default(''),
    color: z.string().trim().max(40).default(''),
    year: z.number().int().min(1900).max(2100).nullish(),
  }),
  insurance: z.object({
    claimNumber: z.string().trim().min(1).max(40),
    policyNumber: z.string().trim().max(40).default(''),
    insuredName: z.string().trim().max(120).default(''),
    insuredPhone: phone.default(''),
  }),
  notes: z.string().trim().max(500).default(''),
  /** From the preview, when the operator saw one. */
  priced: z
    .object({
      distanceKm: z.number().min(0).max(5000),
      expiresAtMs: z.number().int().positive(),
      signature: z.string().min(16).max(200),
    })
    .nullish(),
});

export type CreateInsurerServiceInput = z.infer<typeof createInsurerServiceInput>;

/**
 * The claim number as it is compared for duplicates: `sin-2024 01489` and
 * `SIN-2024-01489` are the same file.
 */
export const claimKey = (claimNumber: string): string =>
  claimNumber.toUpperCase().replace(/[^A-Z0-9]/g, '');

export interface InsurerQuotePayload {
  insurerId: string;
  vehicleType: string;
  pickupGeohash: string;
  dropoffGeohash: string;
  distanceKm: number;
  expiresAtMs: number;
}

function canonical(p: InsurerQuotePayload): string {
  return [
    'insurer',
    p.insurerId,
    p.vehicleType,
    p.pickupGeohash,
    p.dropoffGeohash,
    p.distanceKm.toFixed(1),
    p.expiresAtMs,
  ].join('|');
}

/**
 * Signs the distance a preview was priced on.
 *
 * Prefixed so a customer's quote signature can never be replayed as an
 * insurer's, or the other way round.
 */
export function signInsurerQuote(payload: InsurerQuotePayload): string {
  return createHmac('sha256', signingSecret()).update(canonical(payload)).digest('hex');
}

export function verifyInsurerQuote(payload: InsurerQuotePayload, signature: string): boolean {
  const expected = Buffer.from(signInsurerQuote(payload), 'utf8');
  const actual = Buffer.from(signature, 'utf8');
  return expected.length === actual.length && timingSafeEqual(expected, actual);
}

/**
 * The zone price in the shape every screen already reads a price in.
 *
 * The ITBIS shown is what this tow adds to the invoice, for display. The
 * invoice itself taxes its subtotal once — see `withItbis`.
 */
export function quoteFromZone(zone: ZoneQuote, vehicleType: VehicleType): Quote {
  const { itbisCents, totalCents } = withItbis(zone.subtotalCents);

  return {
    // Zero marks a price from the zone tariff rather than the customer tariff.
    pricingVersion: 0,
    vehicleType,
    heavy: isHeavyVehicle(vehicleType),
    baseCents: zone.baseCents,
    includedKm: 0,
    distanceKm: zone.distanceKm,
    cityKm: 0,
    highwayKm: 0,
    cityPerKmCents: 0,
    highwayPerKmCents: 0,
    perKmCents: zone.extraKmCents,
    distanceCents: zone.extraCents,
    minimumAdjustmentCents: 0,
    surcharges: [],
    subtotalCents: zone.subtotalCents,
    itbisCents,
    totalCents,
    currency: 'DOP',
  };
}

/** What the insurance company is shown on its own tow: no split, no margin. */
export function insurerBilling(insurerId: string, zone: ZoneQuote) {
  return {
    mode: 'insurer' as const,
    insurerId,
    tariff: zone.tariff,
    vehicleClass: zone.vehicleClass,
    zoneMinKm: zone.zoneMinKm,
    zoneMaxKm: zone.zoneMaxKm,
    distanceKm: zone.distanceKm,
    baseCents: zone.baseCents,
    extraKm: zone.extraKm,
    extraKmCents: zone.extraKmCents,
    extraCents: zone.extraCents,
    subtotalCents: zone.subtotalCents,
  };
}
