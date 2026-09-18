import { z } from 'zod';

import { VehicleType } from './enums.js';
import { ITBIS_BPS, bps, toPeso } from './pricing.js';

/**
 * The tariff insurance companies are billed on: fixed prices by distance zone.
 *
 * Mirrored in `packages/grua_core/lib/src/data/zone_pricing.dart`. Both sides
 * run the cases in `packages/grua_core/test/fixtures/zone_pricing_cases.json`,
 * so an edit here that is not made there fails a test on one side.
 *
 * A trip falls in exactly one zone by its road distance, pickup to dropoff:
 *
 *     price = base + (km past the start of the zone) × extra rate
 *
 * The default table charges a flat price inside 0–10, 10–25 and 25–50 km (an
 * extra rate of zero), and past 50 km the 25–50 price plus a rate per
 * kilometre. Every number is data, stored in `pricingRules`, so a negotiated
 * price for one insurance company is a set of rows, not a code change.
 *
 * Prices here are before ITBIS. The tax goes on once, at the foot of the
 * invoice — see [withItbis].
 *
 * Everything is integer DOP cents; distances are worked in tenths of a
 * kilometre, like the customer tariff.
 */

export const VehicleClass = {
  /** Carro, motor. */
  light: 'light',
  /** SUV / jeepeta, camioneta. */
  suv: 'suv',
  /** Camión, patana, autobús, equipo pesado. */
  heavy: 'heavy',
} as const;

export type VehicleClass = (typeof VehicleClass)[keyof typeof VehicleClass];

const CLASS_BY_VEHICLE: Record<VehicleType, VehicleClass> = {
  [VehicleType.sedan]: VehicleClass.light,
  [VehicleType.motor]: VehicleClass.light,
  [VehicleType.suv]: VehicleClass.suv,
  [VehicleType.camioneta]: VehicleClass.suv,
  [VehicleType.camion]: VehicleClass.heavy,
  [VehicleType.patana]: VehicleClass.heavy,
  [VehicleType.equipoPesado]: VehicleClass.heavy,
};

/** The column of the table a vehicle is priced in, or `null` if it has none. */
export function vehicleClassOf(type: string): VehicleClass | null {
  return CLASS_BY_VEHICLE[type as VehicleType] ?? null;
}

/** One row of the tariff: one zone, for one class of vehicle. */
export interface PricingRule {
  zoneMinKm: number;
  /** `null` for the last, open-ended zone. */
  zoneMaxKm: number | null;
  vehicleClass: VehicleClass;
  baseCents: number;
  /** Per kilometre past [zoneMinKm]. Zero for a flat-priced zone. */
  extraKmCents: number;
  /** `null` for the default table every company is billed on. */
  insurerId: string | null;
}

const row = (
  vehicleClass: VehicleClass,
  zoneMinKm: number,
  zoneMaxKm: number | null,
  basePesos: number,
  extraKmPesos = 0,
): PricingRule => ({
  zoneMinKm,
  zoneMaxKm,
  vehicleClass,
  baseCents: basePesos * 100,
  extraKmCents: extraKmPesos * 100,
  insurerId: null,
});

/**
 * The base price list, "Tabla de precios base — sin ITBIS".
 *
 * Used for any class of vehicle the `pricingRules` collection has no default
 * rows for, so a fresh project can bill before anyone has opened the editor.
 */
export const DEFAULT_PRICING_RULES: readonly PricingRule[] = [
  row(VehicleClass.light, 0, 10, 2_500),
  row(VehicleClass.light, 10, 25, 3_500),
  row(VehicleClass.light, 25, 50, 5_500),
  row(VehicleClass.light, 50, null, 5_500, 120),

  row(VehicleClass.suv, 0, 10, 3_200),
  row(VehicleClass.suv, 10, 25, 4_500),
  row(VehicleClass.suv, 25, 50, 7_000),
  row(VehicleClass.suv, 50, null, 7_000, 150),

  row(VehicleClass.heavy, 0, 10, 5_500),
  row(VehicleClass.heavy, 10, 25, 7_000),
  row(VehicleClass.heavy, 25, 50, 11_000),
  row(VehicleClass.heavy, 50, null, 11_000, 250),
];

/** What a `pricingRules` document must look like, on read and on write. */
export const pricingRuleSchema = z.object({
  zoneMinKm: z.number().int().min(0).max(10_000),
  zoneMaxKm: z.number().int().min(1).max(10_000).nullable(),
  vehicleClass: z.nativeEnum(VehicleClass),
  baseCents: z.number().int().min(0).max(100_000_000),
  extraKmCents: z.number().int().min(0).max(10_000_000),
  insurerId: z.string().min(1).max(64).nullable(),
});

/**
 * The document id for a row. Deterministic, so the same zone cannot be stored
 * twice for the same table.
 */
export const pricingRuleId = (rule: PricingRule): string =>
  `${rule.insurerId ?? 'default'}__${rule.vehicleClass}__${rule.zoneMinKm}`;

const byZoneStart = (a: PricingRule, b: PricingRule) => a.zoneMinKm - b.zoneMinKm;

/**
 * Why [rules] cannot price one class of vehicle, or `null` when they can.
 *
 * A usable table covers every distance exactly once: it starts at 0 km, each
 * zone ends where the next begins, and only the last is open-ended.
 */
export function zoneTableProblem(rules: readonly PricingRule[]): string | null {
  if (rules.length === 0) return 'La tabla no tiene zonas.';

  const first = rules[0]!;
  if (
    rules.some(
      (r) => r.vehicleClass !== first.vehicleClass || r.insurerId !== first.insurerId,
    )
  ) {
    return 'La tabla mezcla tipos de vehículo o aseguradoras.';
  }

  const sorted = [...rules].sort(byZoneStart);
  if (sorted[0]!.zoneMinKm !== 0) return 'La primera zona debe empezar en 0 km.';

  for (let i = 0; i < sorted.length; i++) {
    const zone = sorted[i]!;
    const last = i === sorted.length - 1;

    if (zone.zoneMaxKm === null) {
      if (!last) return `Solo la última zona puede no tener límite (${zone.zoneMinKm} km).`;
      continue;
    }
    if (zone.zoneMaxKm <= zone.zoneMinKm) {
      return `La zona ${zone.zoneMinKm}–${zone.zoneMaxKm} km termina antes de empezar.`;
    }
    if (last) return 'La última zona debe quedar abierta (sin kilómetro máximo).';

    const next = sorted[i + 1]!;
    if (next.zoneMinKm !== zone.zoneMaxKm) {
      return `Las zonas no son continuas entre ${zone.zoneMaxKm} y ${next.zoneMinKm} km.`;
    }
  }
  return null;
}

export class ZoneTableError extends Error {}

/** Which table a price came from, so an invoice line can say so. */
export type TariffSource = 'insurer' | 'default';

export interface ZoneQuote {
  vehicleClass: VehicleClass;
  tariff: TariffSource;
  /** The road distance, to a tenth of a kilometre. */
  distanceKm: number;
  zoneMinKm: number;
  zoneMaxKm: number | null;
  baseCents: number;
  /** Kilometres past the start of the zone, to a tenth. */
  extraKm: number;
  extraKmCents: number;
  extraCents: number;
  /** Before ITBIS. */
  subtotalCents: number;
  currency: 'DOP';
}

/**
 * Prices one trip on one class's table.
 *
 * A trip of exactly 10 km is in 0–10, not 10–25: a zone includes its upper
 * bound. Throws [ZoneTableError] for a table [zoneTableProblem] refuses — a
 * broken table must stop the quote, never bill a wrong amount.
 */
export function quoteZonePrice(input: {
  rules: readonly PricingRule[];
  distanceKm: number;
  tariff: TariffSource;
}): ZoneQuote {
  const problem = zoneTableProblem(input.rules);
  if (problem) throw new ZoneTableError(problem);
  if (!Number.isFinite(input.distanceKm) || input.distanceKm < 0) {
    throw new RangeError(`distance must be a non-negative number, got ${input.distanceKm}`);
  }

  const tenths = Math.round(input.distanceKm * 10);
  const sorted = [...input.rules].sort(byZoneStart);
  const zone = sorted.find((r) => r.zoneMaxKm === null || tenths <= r.zoneMaxKm * 10)!;

  const extraTenths = Math.max(0, tenths - zone.zoneMinKm * 10);
  const extraCents = toPeso(Math.round((extraTenths * zone.extraKmCents) / 10));

  return {
    vehicleClass: zone.vehicleClass,
    tariff: input.tariff,
    distanceKm: tenths / 10,
    zoneMinKm: zone.zoneMinKm,
    zoneMaxKm: zone.zoneMaxKm,
    baseCents: zone.baseCents,
    extraKm: extraTenths / 10,
    extraKmCents: zone.extraKmCents,
    extraCents,
    subtotalCents: zone.baseCents + extraCents,
    currency: 'DOP',
  };
}

/** The rows for one class in the built-in default table. */
export const defaultRulesFor = (vehicleClass: VehicleClass): PricingRule[] =>
  DEFAULT_PRICING_RULES.filter((r) => r.vehicleClass === vehicleClass);

export interface ItbisTotals {
  subtotalCents: number;
  itbisCents: number;
  totalCents: number;
}

/**
 * Subtotal + ITBIS (18%) = Total, as the foot of an invoice shows it.
 *
 * Applied once to an invoice's subtotal, never per line and then summed: the
 * sum of rounded line taxes can differ from the tax on the sum by a few
 * centavos, and the DGII reads the foot.
 */
export function withItbis(subtotalCents: number): ItbisTotals {
  const itbisCents = bps(subtotalCents, ITBIS_BPS);
  return { subtotalCents, itbisCents, totalCents: subtotalCents + itbisCents };
}
