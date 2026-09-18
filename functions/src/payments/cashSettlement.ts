import { PaymentMethod, PaymentStatus } from '../lib/enums.js';

/**
 * The cash a chofer holds for the company: every cash job whose money they
 * confirmed collecting and that no corte has counted yet.
 *
 * Summed from the services themselves rather than a running counter, so a
 * corte always matches the jobs it lists — a counter drifts the first time a
 * write is retried or a service predates it.
 */
export interface CashJob {
  id: string;
  payment?: {
    method?: unknown;
    status?: unknown;
    capturedCents?: unknown;
    cashSettlementId?: unknown;
    /** The weekly corte that charged this job's commission instead. */
    weeklySettlementId?: unknown;
  } | null;
}

export function unsettledCash(jobs: readonly CashJob[]): {
  serviceIds: string[];
  totalCents: number;
} {
  const pending = jobs.filter((job) => {
    const payment = job.payment ?? {};
    return (
      payment.method === PaymentMethod.cash &&
      payment.status === PaymentStatus.cashCollected &&
      !payment.cashSettlementId &&
      // The chofer kept this cash and paid its commission at a weekly corte:
      // the company is not owed the money again.
      !payment.weeklySettlementId
    );
  });
  return {
    serviceIds: pending.map((job) => job.id),
    totalCents: pending.reduce(
      (sum, job) => sum + (Number(job.payment?.capturedCents) || 0),
      0,
    ),
  };
}
