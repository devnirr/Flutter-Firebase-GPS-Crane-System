import { onCall } from 'firebase-functions/v2/https';
import { logger } from 'firebase-functions/v2';
import { z } from 'zod';

import { invalidArgument, notFound } from '../lib/errors.js';
import { FieldValue, Paths, db } from '../lib/firestore.js';
import { requireAdmin } from '../lib/guards.js';
import {
  type PricingRule,
  VehicleClass,
  pricingRuleId,
  zoneTableProblem,
} from '../lib/zonePricing.js';
import { audit } from './admin.js';
import { region } from './region.js';

/**
 * Editing the zone tariff. Admin only.
 *
 * A table is saved whole — every zone of one class of vehicle, for the default
 * list or one company — and only if it covers every distance exactly once. A
 * half-saved table would stop every quote for that class, so the old rows are
 * replaced in the same transaction that writes the new ones.
 */

const tableKey = z.object({
  /** `null` for the default list. */
  insurerId: z.string().min(1).max(64).nullable(),
  vehicleClass: z.nativeEnum(VehicleClass),
});

const zoneRow = z.object({
  zoneMinKm: z.number().int().min(0).max(10_000),
  zoneMaxKm: z.number().int().min(1).max(10_000).nullable(),
  baseCents: z.number().int().min(0).max(100_000_000),
  extraKmCents: z.number().int().min(0).max(10_000_000),
});

async function assertInsurerExists(insurerId: string | null): Promise<void> {
  if (insurerId === null) return;
  const snap = await Paths.insurer(insurerId).get();
  if (!snap.exists) throw notFound('No encontramos esa aseguradora.');
}

async function replaceTable(
  insurerId: string | null,
  vehicleClass: VehicleClass,
  rules: PricingRule[],
  actorId: string,
): Promise<number> {
  return db.runTransaction(async (tx) => {
    const existing = await tx.get(
      Paths.pricingRules()
        .where('insurerId', '==', insurerId)
        .where('vehicleClass', '==', vehicleClass),
    );
    const keep = new Set(rules.map(pricingRuleId));
    for (const doc of existing.docs) {
      if (!keep.has(doc.id)) tx.delete(doc.ref);
    }
    for (const rule of rules) {
      tx.set(Paths.pricingRules().doc(pricingRuleId(rule)), {
        ...rule,
        updatedBy: actorId,
        updatedAt: FieldValue.serverTimestamp(),
      });
    }
    return existing.size;
  });
}

/** Saves one class's whole table, for the default list or one company. */
export const savePricingTable = onCall({ region, cors: true }, async (request) => {
  const parsed = tableKey
    .extend({ rows: z.array(zoneRow).min(1).max(20) })
    .safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Revisa los precios: deben ser montos enteros y positivos.');

  const caller = requireAdmin(request);
  const { insurerId, vehicleClass, rows } = parsed.data;
  await assertInsurerExists(insurerId);

  const rules: PricingRule[] = rows.map((row) => ({ ...row, vehicleClass, insurerId }));
  const problem = zoneTableProblem(rules);
  if (problem) throw invalidArgument(problem);

  const replaced = await replaceTable(insurerId, vehicleClass, rules, caller.uid);

  await audit(caller.uid, 'savePricingTable', `${insurerId ?? 'default'}/${vehicleClass}`, {
    rows: rules.map((r) => ({
      zone: `${r.zoneMinKm}-${r.zoneMaxKm ?? '+'}`,
      baseCents: r.baseCents,
      extraKmCents: r.extraKmCents,
    })),
    replaced,
  });
  logger.info('pricing.tableSaved', { insurerId, vehicleClass, rows: rules.length, by: caller.uid });
  return { ok: true, rows: rules.length };
});

/**
 * Removes one class's stored table.
 *
 * For a company, it goes back to the default list; for the default list, to
 * the built-in price list.
 */
export const resetPricingTable = onCall({ region, cors: true }, async (request) => {
  const parsed = tableKey.safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Datos inválidos.');

  const caller = requireAdmin(request);
  const { insurerId, vehicleClass } = parsed.data;
  await assertInsurerExists(insurerId);

  const removed = await replaceTable(insurerId, vehicleClass, [], caller.uid);

  await audit(caller.uid, 'resetPricingTable', `${insurerId ?? 'default'}/${vehicleClass}`, {
    removed,
  });
  logger.info('pricing.tableReset', { insurerId, vehicleClass, removed, by: caller.uid });
  return { ok: true, removed };
});
