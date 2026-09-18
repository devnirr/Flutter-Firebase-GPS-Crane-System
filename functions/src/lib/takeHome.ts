import { logger } from 'firebase-functions/v2';

import { PaymentMethod } from './enums.js';
import { Paths } from './firestore.js';
import { DEFAULT_DRIVER_PAYOUT_BPS, payoutSplit } from './insurerService.js';
import { type PricingConfig, commissionCents } from './pricing.js';

/**
 * What a chofer earns on a job, and what the company keeps.
 *
 * Two rules, one question. A customer's tow: the chofer keeps the total less
 * the platform commission. An insurer's tow: the chofer's share of the zone
 * price, fixed when the tow was ordered and kept where the insurance company
 * cannot read it.
 */
export interface TakeHome {
  /** What the job is worth before the split. */
  grossCents: number;
  /** The chofer's. */
  netCents: number;
  /** The company's. */
  commissionCents: number;
}

export const isInsurerJob = (service: FirebaseFirestore.DocumentData): boolean =>
  (service['payment'] as Record<string, unknown> | undefined)?.['method'] ===
  PaymentMethod.insurer;

export async function takeHome(
  serviceId: string,
  service: FirebaseFirestore.DocumentData,
  pricing: PricingConfig,
): Promise<TakeHome> {
  if (isInsurerJob(service)) {
    const billing = (await Paths.serviceBilling(serviceId).get()).data();
    if (billing) {
      return {
        grossCents: billing['subtotalCents'] as number,
        netCents: billing['driverPayoutCents'] as number,
        commissionCents: billing['platformCents'] as number,
      };
    }

    // Should not happen: the order writes both documents together. Paying the
    // default share beats paying nothing, and the log says to look.
    const subtotal =
      ((service['billing'] as Record<string, unknown> | undefined)?.['subtotalCents'] as
        | number
        | undefined) ?? 0;
    logger.error('takeHome.missingBilling', { serviceId });
    const split = payoutSplit(subtotal, DEFAULT_DRIVER_PAYOUT_BPS);
    return {
      grossCents: subtotal,
      netCents: split.driverPayoutCents,
      commissionCents: split.platformCents,
    };
  }

  const gross =
    ((service['final'] as Record<string, unknown> | undefined)?.['totalCents'] as number) ??
    ((service['quote'] as Record<string, unknown> | undefined)?.['totalCents'] as number) ??
    0;
  const commission = commissionCents(pricing, gross);
  return { grossCents: gross, netCents: gross - commission, commissionCents: commission };
}
