import { logger } from 'firebase-functions/v2';

import { internal, invalidArgument } from './errors.js';
import { Paths } from './firestore.js';
import {
  type PricingRule,
  type TariffSource,
  type VehicleClass,
  type ZoneQuote,
  defaultRulesFor,
  pricingRuleSchema,
  quoteZonePrice,
  vehicleClassOf,
  zoneTableProblem,
} from './zonePricing.js';

/**
 * Where an insurance company's zone prices come from.
 *
 * Resolved one class of vehicle at a time: a company that negotiated only its
 * light-vehicle prices has rows for `light` alone, and is billed on the default
 * table for SUVs and heavy vehicles. The default table is the `pricingRules`
 * rows with no `insurerId`, and the built-in list when there are none.
 */

async function storedRules(
  insurerId: string | null,
  vehicleClass: VehicleClass,
): Promise<PricingRule[]> {
  const snap = await Paths.pricingRules()
    .where('insurerId', '==', insurerId)
    .where('vehicleClass', '==', vehicleClass)
    .get();

  return snap.docs.map((doc) => {
    const parsed = pricingRuleSchema.safeParse(doc.data());
    if (!parsed.success) {
      logger.error('pricingRules.unreadable', { id: doc.id, issues: parsed.error.issues });
      throw internal('La tabla de precios tiene un error. Avisa a la oficina.');
    }
    return parsed.data;
  });
}

export interface ZoneTable {
  rules: PricingRule[];
  tariff: TariffSource;
}

/** The table one company's [vehicleClass] is billed on. */
export async function zoneTableFor(
  insurerId: string | null,
  vehicleClass: VehicleClass,
): Promise<ZoneTable> {
  if (insurerId !== null) {
    const own = await storedRules(insurerId, vehicleClass);
    if (own.length > 0) return checked({ rules: own, tariff: 'insurer' }, insurerId, vehicleClass);
  }

  const stored = await storedRules(null, vehicleClass);
  if (stored.length > 0) return checked({ rules: stored, tariff: 'default' }, null, vehicleClass);

  return { rules: defaultRulesFor(vehicleClass), tariff: 'default' };
}

/**
 * Refuses a stored table that does not cover every distance.
 *
 * Falling back to the default here would quietly bill a company that
 * negotiated its own prices at the list price, so a broken table stops the
 * quote and says so in the logs instead.
 */
function checked(table: ZoneTable, insurerId: string | null, vehicleClass: VehicleClass): ZoneTable {
  const problem = zoneTableProblem(table.rules);
  if (problem) {
    logger.error('pricingRules.incomplete', { insurerId, vehicleClass, problem });
    throw internal('La tabla de precios tiene un error. Avisa a la oficina.');
  }
  return table;
}

/** What [insurerId] is billed, before ITBIS, for one trip. */
export async function quoteForInsurer(input: {
  insurerId: string;
  vehicleType: string;
  distanceKm: number;
}): Promise<ZoneQuote> {
  const vehicleClass = vehicleClassOf(input.vehicleType);
  if (vehicleClass === null) {
    throw invalidArgument('Elige el tipo de vehículo.');
  }

  const table = await zoneTableFor(input.insurerId, vehicleClass);
  return quoteZonePrice({ ...table, distanceKm: input.distanceKm });
}
