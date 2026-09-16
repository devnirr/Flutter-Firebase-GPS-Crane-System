import { describe, expect, it } from 'vitest';

import { ServiceEventName } from '../src/lib/enums.js';
import { transitionFor } from '../src/lib/stateMachine.js';
import { unsettledCash } from '../src/payments/cashSettlement.js';

/**
 * Paying for a tow: cash to the chofer, and what they owe at the corte.
 */

describe('unsettledCash', () => {
  it('counts only cash collected and not yet in a corte', () => {
    const { serviceIds, totalCents } = unsettledCash([
      { id: 'a', payment: { method: 'cash', status: 'cash_collected', capturedCents: 250000 } },
      { id: 'b', payment: { method: 'cash', status: 'cash_collected', capturedCents: 180000 } },
      // Already handed in at an earlier corte.
      {
        id: 'c',
        payment: {
          method: 'cash',
          status: 'cash_collected',
          capturedCents: 90000,
          cashSettlementId: 'set-1',
        },
      },
      // Collected by nobody yet.
      { id: 'd', payment: { method: 'cash', status: 'cash_pending', capturedCents: 0 } },
      // An old card job, from when there was a card rail: the company was
      // paid directly, so the chofer holds nothing for it.
      { id: 'e', payment: { method: 'card', status: 'captured', capturedCents: 300000 } },
    ]);

    expect(serviceIds).toEqual(['a', 'b']);
    expect(totalCents).toBe(430000);
  });
});

describe('starting a job', () => {
  it('waits on nothing: the money changes hands at the end', () => {
    // There used to be a card hold to wait for here. A chofer standing at the
    // curb must not be blocked by a payment that only happens on delivery.
    expect(transitionFor(ServiceEventName.startService).guard).toBeUndefined();
  });
});
