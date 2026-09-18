import { readFileSync } from 'node:fs';

import { describe, expect, it } from 'vitest';

import {
  type NcfPrefix,
  DEFAULT_ISSUER,
  fiscalIssuerInput,
  formatNcf,
  issuerOf,
  ncfRegistryKey,
  ncfSequenceInput,
  parseNcf,
  remainingIn,
  sequenceOf,
  sequenceProblem,
  testSequence,
} from '../src/lib/fiscal.js';
import {
  type InvoiceableService,
  draftInsurerInvoice,
  dueDateFor,
  isPeriodKey,
  periodBounds,
  periodKeyOf,
  periodLabel,
  previousPeriodKey,
} from '../src/lib/insurerInvoice.js';
import { freshRnc } from './support/rnc.js';

/**
 * Monthly invoices and NCF numbering, on the cases the app runs too.
 */

interface Cases {
  ncf: { prefix: NcfPrefix; sequence: number; ncf: string }[];
  badNcf: string[];
  periods: { key: string; start: string; end: string; label: string }[];
  periodOf: { instant: string; key: string; previous: string }[];
  due: { issuedAt: string; termsDays: number; dueAt: string }[];
  sequences: {
    name: string;
    sequence: { nextNumber: number; lastNumber: number; expiresOn: string | null };
    now: string;
    blocked: boolean;
    remaining: number;
  }[];
  invoices: {
    name: string;
    cutoff: string;
    maxLines?: number;
    services: {
      id: string;
      status: string;
      finishedAt: string | null;
      subtotalCents: number;
      feeCents: number;
    }[];
    expect: null | {
      lines: string[];
      kinds: string[];
      amounts: number[];
      towCount: number;
      cancellationCount: number;
      subtotalCents: number;
      itbisCents: number;
      totalCents: number;
      leftover: number;
    };
  }[];
}

const cases = JSON.parse(
  readFileSync(
    new URL('../../packages/grua_core/test/fixtures/insurer_invoice_cases.json', import.meta.url),
    'utf8',
  ),
) as Cases;

const service = (s: Cases['invoices'][number]['services'][number]): InvoiceableService => ({
  serviceId: s.id,
  serviceCode: `GR-${s.id}`,
  status: s.status,
  finishedAt: s.finishedAt ? new Date(s.finishedAt) : null,
  subtotalCents: s.subtotalCents,
  feeCents: s.feeCents,
  claimNumber: `SIN-${s.id}`,
  policyNumber: '',
  insuredName: '',
  plate: '',
  vehicle: '',
  pickupAddress: '',
  dropoffAddress: '',
  distanceKm: 0,
  zoneLabel: '0–10 km',
  vehicleClass: '',
});

describe('NCF numbering', () => {
  it.each(cases.ncf)('$prefix + $sequence is $ncf', ({ prefix, sequence, ncf }) => {
    expect(formatNcf(prefix, sequence)).toBe(ncf);
    expect(parseNcf(ncf)).toEqual({ prefix, sequence });
  });

  it.each(cases.badNcf)('"%s" is not an NCF', (bad) => {
    expect(parseNcf(bad)).toBeNull();
  });

  it('refuses a number outside the eight digits', () => {
    expect(() => formatNcf('B01', 0)).toThrow(RangeError);
    expect(() => formatNcf('B01', 100_000_000)).toThrow(RangeError);
    expect(() => formatNcf('B01', 1.5)).toThrow(RangeError);
  });

  it.each(cases.sequences)('$name', ({ sequence, now, blocked, remaining }) => {
    const seq = { prefix: 'B01' as const, isTest: false, ...sequence };
    expect(sequenceProblem(seq, new Date(now)) !== null).toBe(blocked);
    expect(remainingIn(seq)).toBe(remaining);
  });

  it('starts on test numbers, B0100000001 first', () => {
    const seq = sequenceOf('B01', undefined);
    expect(seq).toEqual(testSequence('B01'));
    expect(seq.isTest).toBe(true);
    expect(formatNcf(seq.prefix, seq.nextNumber)).toBe('B0100000001');
  });

  it('treats a stored range as test unless it says otherwise', () => {
    expect(sequenceOf('B01', { nextNumber: 5, lastNumber: 9 }).isTest).toBe(true);
    expect(sequenceOf('B01', { nextNumber: 5, lastNumber: 9, isTest: false }).isTest).toBe(false);
    // Unreadable numbers fall back to the test range rather than guessing.
    expect(sequenceOf('B01', { nextNumber: '5', lastNumber: 9, isTest: false })).toEqual(
      testSequence('B01'),
    );
  });

  it('registers test and real numbers apart', () => {
    expect(ncfRegistryKey('B0100000001', true)).toBe('TEST-B0100000001');
    expect(ncfRegistryKey('B0100000001', false)).toBe('B0100000001');
  });

  it('asks a real range for its expiry, and a sane span', () => {
    const real = { prefix: 'B01', nextNumber: 1, lastNumber: 500, isTest: false };
    expect(ncfSequenceInput.safeParse(real).success).toBe(false);
    expect(ncfSequenceInput.safeParse({ ...real, expiresOn: '2027-12-31' }).success).toBe(true);
    expect(ncfSequenceInput.safeParse({ ...real, expiresOn: '2027-02-30' }).success).toBe(false);
    expect(
      ncfSequenceInput.safeParse({ ...real, expiresOn: '2027-12-31', lastNumber: 0 }).success,
    ).toBe(false);
    expect(
      ncfSequenceInput.safeParse({
        ...real,
        nextNumber: 20,
        lastNumber: 10,
        expiresOn: '2027-12-31',
      }).success,
    ).toBe(false);
    expect(ncfSequenceInput.safeParse({ ...real, isTest: true }).success).toBe(true);
    expect(ncfSequenceInput.safeParse({ ...real, prefix: 'B99', isTest: true }).success).toBe(
      false,
    );
  });
});

describe('the issuer', () => {
  it('fills in what the office has not typed yet', () => {
    expect(issuerOf(undefined)).toEqual(DEFAULT_ISSUER);
    expect(issuerOf({ name: '', paymentTermsDays: -1 })).toEqual(DEFAULT_ISSUER);
    expect(issuerOf({ name: 'Titan, SRL', rnc: '130000001', paymentTermsDays: 15 })).toMatchObject(
      { name: 'Titan, SRL', rnc: '130000001', paymentTermsDays: 15 },
    );
  });

  it('takes an empty RNC while the company is being registered, and a valid one after', () => {
    expect(fiscalIssuerInput.safeParse({ name: 'Titan, SRL', rnc: '' }).success).toBe(true);
    const rnc = freshRnc();
    const parsed = fiscalIssuerInput.safeParse({
      name: 'Titan, SRL',
      rnc: `${rnc.slice(0, 1)}-${rnc.slice(1, 3)}-${rnc.slice(3, 8)}-${rnc.slice(8)}`,
    });
    expect(parsed.success && parsed.data.rnc).toBe(rnc);
    const wrongDigit = `${rnc.slice(0, 8)}${(Number(rnc[8]) + 1) % 10}`;
    expect(fiscalIssuerInput.safeParse({ name: 'Titan, SRL', rnc: wrongDigit }).success).toBe(
      false,
    );
    expect(fiscalIssuerInput.safeParse({ name: 'T', rnc: '' }).success).toBe(false);
  });
});

describe('billing periods', () => {
  it.each(cases.periods)('$key runs from $start to $end', ({ key, start, end, label }) => {
    expect(isPeriodKey(key)).toBe(true);
    const bounds = periodBounds(key);
    expect(bounds.start.toISOString()).toBe(start);
    expect(bounds.end.toISOString()).toBe(end);
    expect(periodLabel(key)).toBe(label);
  });

  it.each(cases.periodOf)('$instant is in $key', ({ instant, key, previous }) => {
    expect(periodKeyOf(new Date(instant))).toBe(key);
    expect(previousPeriodKey(new Date(instant))).toBe(previous);
  });

  it('refuses what is not a month', () => {
    for (const bad of ['2026-13', '2026-00', '2026-9', '26-09', '']) {
      expect(isPeriodKey(bad)).toBe(false);
    }
    expect(() => periodBounds('2026-13')).toThrow(RangeError);
  });

  it.each(cases.due)(
    'issued $issuedAt on $termsDays days is due $dueAt',
    ({ issuedAt, termsDays, dueAt }) => {
      expect(dueDateFor(new Date(issuedAt), termsDays).toISOString()).toBe(dueAt);
    },
  );
});

describe('the monthly invoice', () => {
  it.each(cases.invoices)('$name', ({ cutoff, maxLines, services, expect: want }) => {
    const draft = draftInsurerInvoice(services.map(service), {
      cutoff: new Date(cutoff),
      maxLines,
    });
    if (want === null) {
      expect(draft).toBeNull();
      return;
    }
    expect(draft).not.toBeNull();
    expect(draft!.lines.map((l) => l.serviceId)).toEqual(want.lines);
    expect(draft!.lines.map((l) => l.kind)).toEqual(want.kinds);
    expect(draft!.lines.map((l) => l.amountCents)).toEqual(want.amounts);
    expect(draft).toMatchObject({
      towCount: want.towCount,
      cancellationCount: want.cancellationCount,
      subtotalCents: want.subtotalCents,
      itbisCents: want.itbisCents,
      totalCents: want.totalCents,
      leftover: want.leftover,
    });
    // ITBIS once on the subtotal, and the foot adds up.
    expect(draft!.subtotalCents + draft!.itbisCents).toBe(draft!.totalCents);
  });

  it('carries what the insurer files each line under, and nothing internal', () => {
    const first = cases.invoices[0]!;
    const draft = draftInsurerInvoice(first.services.map(service), {
      cutoff: new Date(first.cutoff),
    })!;
    expect(draft.lines[0]).toMatchObject({ claimNumber: 'SIN-h', serviceCode: 'GR-h' });
    expect(draft.lines[0]).not.toHaveProperty('status');
    expect(draft.lines[0]).not.toHaveProperty('feeCents');
    expect(draft.lines[0]).not.toHaveProperty('subtotalCents');
  });
});
