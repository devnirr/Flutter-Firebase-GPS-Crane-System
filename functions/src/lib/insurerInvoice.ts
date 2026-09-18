import { ServiceStatus } from './enums.js';
import { fromLocal, toLocal } from './time.js';
import { withItbis } from './zonePricing.js';

/**
 * The monthly invoice an insurance company receives for its tows.
 *
 * Every tow the company ordered that finished — and every cancellation the
 * company made after a chofer was already on the way, which carries a fee —
 * waits with `payment.status: to_invoice`. On the first of the month the
 * office invoices everything that finished before the month ended: one line
 * per tow, the subtotal, ITBIS 18% on the subtotal once, and the total.
 *
 * A tow left over from an earlier month (its invoice was voided, say) is
 * billed with the next one rather than lost. An invoice holds at most
 * [MAX_INVOICE_LINES] lines; a busier month gets a second invoice with its
 * own NCF.
 *
 * Nothing here touches Firestore.
 */

export const MAX_INVOICE_LINES = 400;

/** `2026-09`: a calendar month in Santo Domingo. */
export const isPeriodKey = (value: string): boolean => /^\d{4}-(0[1-9]|1[0-2])$/.test(value);

/** The month [periodKey] as instants: from its first midnight to the next month's. */
export function periodBounds(periodKey: string): { start: Date; end: Date } {
  if (!isPeriodKey(periodKey)) throw new RangeError(`Not a period: ${periodKey}`);
  const [y, m] = periodKey.split('-').map(Number) as [number, number];
  return {
    start: fromLocal(new Date(Date.UTC(y, m - 1, 1))),
    end: fromLocal(new Date(Date.UTC(y, m, 1))),
  };
}

/** The month [instant] falls in, in Santo Domingo. */
export function periodKeyOf(instant: Date): string {
  const local = toLocal(instant);
  return `${local.getUTCFullYear()}-${(local.getUTCMonth() + 1).toString().padStart(2, '0')}`;
}

/** The month before the one [instant] falls in: what the 1st invoices. */
export function previousPeriodKey(instant: Date): string {
  const { start } = periodBounds(periodKeyOf(instant));
  return periodKeyOf(new Date(start.getTime() - 1));
}

const MONTHS = [
  'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
  'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre',
];

/** `septiembre 2026`. */
export function periodLabel(periodKey: string): string {
  const [y, m] = periodKey.split('-').map(Number) as [number, number];
  return `${MONTHS[m - 1]} ${y}`;
}

/** What an invoice needs to know about one of the company's services. */
export interface InvoiceableService {
  serviceId: string;
  serviceCode: string;
  status: string;
  /** Completed, or cancelled. */
  finishedAt: Date | null;
  /** The zone price, before ITBIS. */
  subtotalCents: number;
  /** The cancellation fee, for a cancelled one. */
  feeCents: number;
  claimNumber: string;
  policyNumber: string;
  insuredName: string;
  plate: string;
  vehicle: string;
  pickupAddress: string;
  dropoffAddress: string;
  distanceKm: number;
  zoneLabel: string;
  vehicleClass: string;
  /** `insurer` for the company's negotiated prices, `default` for the list. */
  tariff?: string;
  /** The zone's price, and what the kilometres past its start added. */
  baseCents?: number;
  extraKm?: number;
  extraCents?: number;
}

export type InvoiceLineKind = 'tow' | 'cancellation';

export interface InvoiceLine extends Omit<InvoiceableService, 'status' | 'finishedAt' | 'feeCents' | 'subtotalCents'> {
  kind: InvoiceLineKind;
  finishedAt: Date;
  /** What this line adds, before ITBIS. */
  amountCents: number;
}

export interface InvoiceDraft {
  lines: InvoiceLine[];
  towCount: number;
  cancellationCount: number;
  subtotalCents: number;
  itbisCents: number;
  totalCents: number;
  /** Billable services left for another invoice, beyond [MAX_INVOICE_LINES]. */
  leftover: number;
}

const FINISHED: readonly string[] = [ServiceStatus.completed, ServiceStatus.closed];

/** Whether [service] is billed, and for how much. Null when it is not. */
function lineFor(service: InvoiceableService, cutoff: Date): InvoiceLine | null {
  const at = service.finishedAt;
  if (!at || at.getTime() >= cutoff.getTime()) return null;

  let kind: InvoiceLineKind;
  let amountCents: number;
  if (FINISHED.includes(service.status)) {
    kind = 'tow';
    amountCents = service.subtotalCents;
  } else if (service.status === ServiceStatus.cancelled && service.feeCents > 0) {
    kind = 'cancellation';
    amountCents = service.feeCents;
  } else {
    return null;
  }
  if (!Number.isInteger(amountCents) || amountCents <= 0) return null;

  const { status: _s, finishedAt: _f, feeCents: _fee, subtotalCents: _sub, ...rest } = service;
  return {
    ...rest,
    tariff: rest.tariff ?? '',
    baseCents: kind === 'tow' ? (rest.baseCents ?? 0) : 0,
    extraKm: kind === 'tow' ? (rest.extraKm ?? 0) : 0,
    extraCents: kind === 'tow' ? (rest.extraCents ?? 0) : 0,
    kind,
    finishedAt: at,
    amountCents,
  };
}

/**
 * The invoice for every billable service in [services] that finished before
 * [cutoff], oldest first, or null when there is none.
 */
export function draftInsurerInvoice(
  services: readonly InvoiceableService[],
  options: { cutoff: Date; maxLines?: number },
): InvoiceDraft | null {
  const maxLines = options.maxLines ?? MAX_INVOICE_LINES;
  const billable = services
    .map((s) => lineFor(s, options.cutoff))
    .filter((l): l is InvoiceLine => l !== null)
    .sort(
      (a, b) =>
        a.finishedAt.getTime() - b.finishedAt.getTime() ||
        // By code unit, as Dart's compareTo: Firestore ids mix cases.
        (a.serviceId < b.serviceId ? -1 : a.serviceId > b.serviceId ? 1 : 0),
    );
  if (billable.length === 0) return null;

  const lines = billable.slice(0, maxLines);
  const subtotal = lines.reduce((sum, l) => sum + l.amountCents, 0);
  const totals = withItbis(subtotal);

  return {
    lines,
    towCount: lines.filter((l) => l.kind === 'tow').length,
    cancellationCount: lines.filter((l) => l.kind === 'cancellation').length,
    ...totals,
    leftover: billable.length - lines.length,
  };
}

const DAY_MS = 24 * 60 * 60 * 1000;

/** The end of the day, in Santo Domingo, [termsDays] after [issuedAt]. */
export function dueDateFor(issuedAt: Date, termsDays: number): Date {
  const local = toLocal(issuedAt);
  const startOfDay = Date.UTC(local.getUTCFullYear(), local.getUTCMonth(), local.getUTCDate());
  return fromLocal(new Date(startOfDay + (termsDays + 1) * DAY_MS - 1));
}

export const InsurerInvoiceStatus = {
  /** Sent; waiting for the company's transfer. */
  issued: 'issued',
  paid: 'paid',
  /** Cancelled by the office; its services go back to be invoiced again. */
  voided: 'voided',
} as const;

export type InsurerInvoiceStatus =
  (typeof InsurerInvoiceStatus)[keyof typeof InsurerInvoiceStatus];
