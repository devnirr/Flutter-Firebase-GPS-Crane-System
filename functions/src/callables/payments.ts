import { logger } from 'firebase-functions/v2';
import { onCall } from 'firebase-functions/v2/https';
import { z } from 'zod';

import { PaymentStatus } from '../lib/enums.js';
import { Code, invalidArgument, notFound, precondition } from '../lib/errors.js';
import { FieldValue, Paths, db } from '../lib/firestore.js';
import { requireStaff } from '../lib/guards.js';
import { unsettledCash, type CashJob } from '../payments/cashSettlement.js';
import { region } from './region.js';

/**
 * Paying for a tow.
 *
 * Cash, to the chofer, who then owes it to GRUAS RD 24/7 SRL until the office
 * makes a corte. There is no card rail: Stripe does not onboard businesses
 * domiciled in the Dominican Republic, and no local acquirer is wired up yet.
 *
 * The chofer confirms "Cobrado en efectivo RD$X" at the end of the job
 * (`confirmCashCollected`, in `lifecycle.ts`), which marks it paid and adds
 * the amount to what they hold. This file is the other half: the office
 * receiving that money.
 */

/**
 * The corte: the office receives the cash a chofer holds.
 *
 * Counts every cash job the chofer confirmed collecting that no earlier corte
 * counted, records them together, and marks each one so it is never counted
 * twice. Also clears the commission the chofer owed on those jobs, since the
 * company now has the whole amount, and settles their earnings entries so the
 * weekly corte does not charge that commission again.
 *
 * Jobs a weekly corte already charged are left out: under the weekly corte
 * the chofer keeps the cash and pays only the commission.
 */
export const settleDriverCash = onCall({ region, cors: true }, async (request) => {
  const parsed = z
    .object({
      driverId: z.string().min(1).max(128),
      note: z.string().max(300).default(''),
    })
    .safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Datos inválidos.');

  const caller = requireStaff(request);
  const { driverId, note } = parsed.data;
  const settlementRef = Paths.cashSettlements().doc();

  const result = await db.runTransaction(async (tx) => {
    const driverSnap = await tx.get(Paths.driver(driverId));
    const driver = driverSnap.data();
    if (!driver) throw notFound('Chofer no encontrado.');

    const snap = await tx.get(
      Paths.services()
        .where('driverId', '==', driverId)
        .where('payment.status', '==', PaymentStatus.cashCollected)
        .limit(400),
    );
    const { serviceIds, totalCents } = unsettledCash(
      snap.docs.map((doc) => ({ id: doc.id, payment: doc.get('payment') }) as CashJob),
    );
    if (serviceIds.length === 0) {
      throw precondition(Code.invalidTransition, 'Este chofer no tiene efectivo por entregar.');
    }
    const entries = await tx.getAll(...serviceIds.map((id) => Paths.earningEntry(driverId, id)));
    // A weekly corte that took the entry is the one that settles it.
    const open = entries.filter((e) => e.exists && e.get('settled') !== true);
    const commissionCents = open.reduce(
      (sum, e) => sum + ((e.get('commissionCents') as number | undefined) ?? 0),
      0,
    );

    tx.create(settlementRef, {
      driverId,
      driverName: driver['name'] ?? '',
      amountCents: totalCents,
      serviceCount: serviceIds.length,
      serviceIds,
      note,
      settledBy: caller.uid,
      createdAt: FieldValue.serverTimestamp(),
    });
    for (const id of serviceIds) {
      tx.update(Paths.service(id), {
        'payment.cashSettlementId': settlementRef.id,
        'payment.cashSettledAt': FieldValue.serverTimestamp(),
      });
    }
    for (const entry of open) {
      tx.update(entry.ref, {
        settled: true,
        cashSettlementId: settlementRef.id,
        retiredReason: 'cash_corte',
        settledAt: FieldValue.serverTimestamp(),
      });
    }
    const onHand = (driver['cashOnHandCents'] as number | undefined) ?? 0;
    // Only the commission of these jobs: a weekly corte may still be counting
    // commission on others.
    const owedLeft = Math.max(
      0,
      ((driver['cashOwedCents'] as number | undefined) ?? 0) - commissionCents,
    );
    tx.update(Paths.driver(driverId), {
      cashOnHandCents: Math.max(0, onHand - totalCents),
      cashOwedCents: owedLeft,
      lastCashSettlementAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    tx.set(
      Paths.earnings(driverId),
      { cashOwedCents: owedLeft, updatedAt: FieldValue.serverTimestamp() },
      { merge: true },
    );

    return { totalCents, serviceCount: serviceIds.length };
  });

  logger.info('cash.settled', { driverId, by: caller.uid, ...result });
  return { settlementId: settlementRef.id, ...result };
});
