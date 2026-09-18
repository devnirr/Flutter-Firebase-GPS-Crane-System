import { onCall } from 'firebase-functions/v2/https';
import { onSchedule } from 'firebase-functions/v2/scheduler';
import { logger } from 'firebase-functions/v2';
import { z } from 'zod';

import { PaymentStatus, ServiceStatus } from '../lib/enums.js';
import { Code, invalidArgument, notFound, precondition } from '../lib/errors.js';
import {
  NcfPrefix,
  formatNcf,
  issuerOf,
  ncfRegistryKey,
  sequenceOf,
  sequenceProblem,
} from '../lib/fiscal.js';
import { FieldValue, Paths, Timestamp, db } from '../lib/firestore.js';
import { requireAdmin } from '../lib/guards.js';
import {
  type InvoiceableService,
  InsurerInvoiceStatus,
  MAX_INVOICE_LINES,
  draftInsurerInvoice,
  dueDateFor,
  isPeriodKey,
  periodBounds,
  periodLabel,
  previousPeriodKey,
} from '../lib/insurerInvoice.js';
import { alertAdmins } from '../lib/push.js';
import { VehicleClass } from '../lib/zonePricing.js';
import { zoneTableFor } from '../lib/zoneTariff.js';
import { audit } from './admin.js';
import { region } from './region.js';

/**
 * Monthly invoices to insurance companies, numbered with an NCF.
 *
 * Made on the 1st of every month for the month before, or by the office at
 * any time. Only an admin makes, closes or voids one; a company's managers
 * read their own. See `lib/insurerInvoice.ts` for what goes on one and
 * `lib/fiscal.ts` for the numbering.
 */

const pesos = (cents: number) =>
  `RD$ ${(cents / 100).toLocaleString('en-US', { minimumFractionDigits: 2 })}`;

const toDate = (value: unknown): Date | null =>
  value instanceof Timestamp ? value.toDate() : value instanceof Date ? value : null;

const text = (value: unknown): string => (typeof value === 'string' ? value : '');
const num = (value: unknown): number => (typeof value === 'number' && Number.isFinite(value) ? value : 0);

const VEHICLE_LABELS: Record<string, string> = {
  sedan: 'Carro',
  suv: 'Jeepeta',
  camioneta: 'Camioneta',
  camion: 'Camión 2 ejes',
  patana: 'Patana / Tráiler',
  equipo_pesado: 'Equipo pesado',
  motor: 'Motor',
};

const CLASS_LABELS: Record<string, string> = {
  light: 'Vehículo ligero',
  suv: 'SUV / Jeepeta',
  heavy: 'Vehículo pesado',
};

/** A service document as an invoice reads it. */
export function invoiceableOf(id: string, data: FirebaseFirestore.DocumentData): InvoiceableService {
  const get = (path: string): unknown =>
    path.split('.').reduce<unknown>(
      (value, key) => (value && typeof value === 'object' ? (value as Record<string, unknown>)[key] : undefined),
      data,
    );
  const status = text(data['status']);
  const finishedAt =
    status === ServiceStatus.cancelled
      ? toDate(get('timeline.cancelledAt'))
      : (toDate(get('timeline.completedAt')) ?? toDate(get('timeline.closedAt')));
  const minKm = num(get('billing.zoneMinKm'));
  const maxKm = get('billing.zoneMaxKm');
  const type = text(get('vehicle.type'));
  const makeModel = [text(get('vehicle.make')), text(get('vehicle.model'))]
    .filter((p) => p !== '')
    .join(' ');

  return {
    serviceId: id,
    serviceCode: text(data['code']),
    status,
    finishedAt,
    subtotalCents: num(get('billing.subtotalCents')) || num(get('quote.subtotalCents')),
    feeCents: num(get('cancellation.feeCents')),
    claimNumber: text(get('insurance.claimNumber')),
    policyNumber: text(get('insurance.policyNumber')),
    insuredName: text(get('insurance.insuredName')),
    plate: text(get('vehicle.plate')),
    vehicle: makeModel || VEHICLE_LABELS[type] || '',
    pickupAddress: text(get('pickup.address')),
    dropoffAddress: text(get('dropoff.address')),
    distanceKm: num(get('billing.distanceKm')) || num(get('route.distanceKm')),
    zoneLabel: typeof maxKm === 'number' ? `${minKm}–${maxKm} km` : `+${minKm} km`,
    vehicleClass: CLASS_LABELS[text(get('billing.vehicleClass'))] ?? '',
    tariff: text(get('billing.tariff')),
    baseCents: num(get('billing.baseCents')),
    extraKm: num(get('billing.extraKm')),
    extraCents: num(get('billing.extraCents')),
  };
}

export interface InvoiceTariffRow {
  vehicleClass: string;
  zoneMinKm: number;
  zoneMaxKm: number | null;
  baseCents: number;
  extraKmCents: number;
  /** `insurer` or `default`. */
  source: string;
}

/**
 * The zone prices [insurerId] is billed on, every class, as they stand now:
 * printed on the invoice's spreadsheet next to the lines they priced.
 *
 * A class whose stored table is broken is left out rather than stopping the
 * invoice: the lines already carry their own price.
 */
export async function tariffSnapshot(insurerId: string): Promise<InvoiceTariffRow[]> {
  const rows: InvoiceTariffRow[] = [];
  for (const vehicleClass of [VehicleClass.light, VehicleClass.suv, VehicleClass.heavy]) {
    try {
      const table = await zoneTableFor(insurerId, vehicleClass);
      for (const rule of [...table.rules].sort((a, b) => a.zoneMinKm - b.zoneMinKm)) {
        rows.push({
          vehicleClass,
          zoneMinKm: rule.zoneMinKm,
          zoneMaxKm: rule.zoneMaxKm,
          baseCents: rule.baseCents,
          extraKmCents: rule.extraKmCents,
          source: table.tariff,
        });
      }
    } catch (error) {
      logger.warn('insurerInvoice.tariffUnreadable', { insurerId, vehicleClass, error });
    }
  }
  return rows;
}

export interface IssuedInvoice {
  invoiceId: string;
  insurerId: string;
  ncf: string;
  isTestNcf: boolean;
  totalCents: number;
  lineCount: number;
  /** Billable services still waiting, beyond this invoice's lines. */
  leftover: number;
}

/**
 * Writes one invoice for [insurerId]'s services that finished before
 * [cutoff], or nothing when there are none.
 *
 * One transaction reads the waiting services, takes the next NCF, writes the
 * invoice and marks each service with its id. Two runs at once serialise on
 * the NCF range: the second finds the services gone, and never the number.
 */
export async function issueInsurerInvoice(options: {
  insurerId: string;
  periodKey: string;
  cutoff: Date;
  actorId: string;
}): Promise<IssuedInvoice | null> {
  const { insurerId, periodKey, cutoff, actorId } = options;
  const prefix = NcfPrefix.creditoFiscal;
  const ref = Paths.insurerInvoices().doc();
  const { start: periodStart, end: periodEnd } = periodBounds(periodKey);
  const tariffTable = await tariffSnapshot(insurerId);

  return db.runTransaction(async (tx) => {
    const [insurerSnap, issuerSnap, sequenceSnap] = await tx.getAll(
      Paths.insurer(insurerId),
      Paths.fiscalIssuer(),
      Paths.ncfSequence(prefix),
    );
    const insurer = insurerSnap?.data();
    if (!insurer) throw notFound('No encontramos esa aseguradora.');

    const waiting = await tx.get(
      Paths.services()
        .where('insurerId', '==', insurerId)
        .where('payment.status', '==', PaymentStatus.toInvoice)
        .limit(MAX_INVOICE_LINES * 3),
    );
    const draft = draftInsurerInvoice(
      waiting.docs.map((doc) => invoiceableOf(doc.id, doc.data())),
      { cutoff },
    );
    if (!draft) return null;

    const now = new Date();
    const sequence = sequenceOf(prefix, sequenceSnap?.data());
    const problem = sequenceProblem(sequence, now);
    if (problem) throw precondition(Code.ncfUnavailable, problem);

    const ncf = formatNcf(prefix, sequence.nextNumber);
    const registryRef = Paths.ncfRegistry(ncfRegistryKey(ncf, sequence.isTest));
    if ((await tx.get(registryRef)).exists) {
      throw precondition(
        Code.ncfUnavailable,
        `El NCF ${ncf} ya fue emitido. Revisa el número siguiente de la secuencia.`,
      );
    }

    const issuer = issuerOf(issuerSnap?.data());
    const stamp = FieldValue.serverTimestamp();

    tx.create(ref, {
      insurerId,
      insurerName: text(insurer['name']),
      insurerRnc: text(insurer['rnc']),
      insurerAddress: text(insurer['address']),
      billingEmail: text(insurer['billingEmail']),
      periodKey,
      periodLabel: periodLabel(periodKey),
      periodStart: Timestamp.fromDate(periodStart),
      periodEnd: Timestamp.fromDate(periodEnd),
      cutoff: Timestamp.fromDate(cutoff),
      ncf,
      ncfType: '01',
      ncfPrefix: prefix,
      isTestNcf: sequence.isTest,
      ncfExpiresOn: sequence.expiresOn,
      issuer: {
        name: issuer.name,
        rnc: issuer.rnc,
        address: issuer.address,
        phone: issuer.phone,
        email: issuer.email,
      },
      lines: draft.lines.map((line) => ({
        ...line,
        finishedAt: Timestamp.fromDate(line.finishedAt),
      })),
      tariffTable,
      lineCount: draft.lines.length,
      towCount: draft.towCount,
      cancellationCount: draft.cancellationCount,
      subtotalCents: draft.subtotalCents,
      itbisCents: draft.itbisCents,
      totalCents: draft.totalCents,
      currency: 'DOP',
      status: InsurerInvoiceStatus.issued,
      paymentTermsDays: issuer.paymentTermsDays,
      dueAt: Timestamp.fromDate(dueDateFor(now, issuer.paymentTermsDays)),
      paymentReference: '',
      note: '',
      voidReason: '',
      createdBy: actorId,
      issuedAt: stamp,
      createdAt: stamp,
      updatedAt: stamp,
    });

    tx.create(registryRef, {
      ncf,
      isTest: sequence.isTest,
      kind: 'insurer_invoice',
      documentId: ref.id,
      insurerId,
      issuedAt: stamp,
    });

    tx.set(
      Paths.ncfSequence(prefix),
      {
        prefix,
        nextNumber: sequence.nextNumber + 1,
        lastNumber: sequence.lastNumber,
        expiresOn: sequence.expiresOn,
        isTest: sequence.isTest,
        lastIssued: ncf,
        lastIssuedAt: stamp,
        updatedAt: stamp,
      },
      { merge: true },
    );

    for (const line of draft.lines) {
      tx.update(Paths.service(line.serviceId), {
        'payment.status': PaymentStatus.invoiced,
        invoiceId: ref.id,
        'payment.invoicedAt': stamp,
        updatedAt: stamp,
      });
    }

    return {
      invoiceId: ref.id,
      insurerId,
      ncf,
      isTestNcf: sequence.isTest,
      totalCents: draft.totalCents,
      lineCount: draft.lines.length,
      leftover: draft.leftover,
    };
  });
}

/** Every invoice [insurerId] is owed for [periodKey]: one, or more when busy. */
async function invoiceCompany(
  insurerId: string,
  periodKey: string,
  cutoff: Date,
  actorId: string,
): Promise<IssuedInvoice[]> {
  const issued: IssuedInvoice[] = [];
  // A bound, not a loop that trusts itself: 20 × 400 tows is a year's work.
  for (let round = 0; round < 20; round++) {
    const invoice = await issueInsurerInvoice({ insurerId, periodKey, cutoff, actorId });
    if (!invoice) break;
    issued.push(invoice);
    logger.info('insurerInvoice.issued', { ...invoice, periodKey, by: actorId });
    if (invoice.leftover === 0) break;
  }
  return issued;
}

export interface InvoiceRun {
  created: IssuedInvoice[];
  failed: { insurerId: string; message: string }[];
}

/** Invoices every company for [periodKey]; one failure does not stop the rest. */
async function invoiceAll(periodKey: string, cutoff: Date, actorId: string): Promise<InvoiceRun> {
  const companies = await Paths.insurers().get();
  const run: InvoiceRun = { created: [], failed: [] };
  for (const doc of companies.docs) {
    try {
      run.created.push(...(await invoiceCompany(doc.id, periodKey, cutoff, actorId)));
    } catch (error) {
      logger.error('insurerInvoice.failed', { insurerId: doc.id, periodKey, error });
      run.failed.push({
        insurerId: doc.id,
        message: error instanceof Error ? error.message : String(error),
      });
      // A range that ran out stops every company alike; say it once.
      if ((error as { details?: { code?: string } }).details?.code === Code.ncfUnavailable) break;
    }
  }
  return run;
}

/** The end of [periodKey], or now when the month is still running. */
function cutoffFor(periodKey: string, now: Date): Date {
  const { end } = periodBounds(periodKey);
  return end.getTime() < now.getTime() ? end : now;
}

/**
 * Makes monthly invoices now. Admin only.
 *
 * [periodKey] defaults to last month. The current month may be invoiced too —
 * a company that wants its invoice early — and then covers what finished so
 * far; the rest goes on the next one.
 */
export const generateInsurerInvoices = onCall({ region, cors: true }, async (request) => {
  const parsed = z
    .object({
      insurerId: z.string().min(1).max(128).nullish(),
      periodKey: z.string().refine(isPeriodKey, 'Mes inválido').nullish(),
    })
    .safeParse(request.data ?? {});
  if (!parsed.success) throw invalidArgument('Datos inválidos.');

  const caller = requireAdmin(request);
  const now = new Date();
  const periodKey = parsed.data.periodKey ?? previousPeriodKey(now);
  if (periodBounds(periodKey).start.getTime() > now.getTime()) {
    throw invalidArgument('No se puede facturar un mes que no ha empezado.');
  }
  const cutoff = cutoffFor(periodKey, now);
  const { insurerId } = parsed.data;

  let run: InvoiceRun;
  if (insurerId) {
    if (!(await Paths.insurer(insurerId).get()).exists) {
      throw notFound('No encontramos esa aseguradora.');
    }
    // One company: its refusal is the answer.
    run = { created: await invoiceCompany(insurerId, periodKey, cutoff, caller.uid), failed: [] };
  } else {
    run = await invoiceAll(periodKey, cutoff, caller.uid);
  }

  await audit(caller.uid, 'generateInsurerInvoices', insurerId ?? 'all', {
    periodKey,
    count: run.created.length,
    failed: run.failed.length,
  });
  return { periodKey, ...run };
});

/** The 1st of every month at 6:00, Dominican time, for the month before. */
export const monthlyInsurerInvoices = onSchedule(
  { schedule: '0 6 1 * *', region, timeZone: 'America/Santo_Domingo' },
  async () => {
    const now = new Date();
    const periodKey = previousPeriodKey(now);
    const run = await invoiceAll(periodKey, cutoffFor(periodKey, now), 'system');
    if (run.created.length === 0 && run.failed.length === 0) return;

    const total = run.created.reduce((sum, i) => sum + i.totalCents, 0);
    const test = run.created.some((i) => i.isTestNcf) ? ' (NCF de prueba)' : '';
    await alertAdmins(
      'Facturas del mes listas',
      run.failed.length > 0
        ? `${run.created.length} facturas${test} por ${pesos(total)}. ${run.failed.length} no se pudieron hacer: ${run.failed[0]!.message}`
        : `${run.created.length} facturas${test} por ${pesos(total)}.`,
      { type: 'insurer_invoices', periodKey },
    );
  },
);

/**
 * Records the company's payment of an invoice. Admin only. The transfer
 * reference is required, so the bank statement can be matched to it.
 */
export const markInsurerInvoicePaid = onCall({ region, cors: true }, async (request) => {
  const parsed = z
    .object({
      invoiceId: z.string().min(1).max(128),
      reference: z.string().trim().min(3).max(120),
      note: z.string().trim().max(300).default(''),
    })
    .safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Escribe el número de la transferencia.');

  const caller = requireAdmin(request);
  const { invoiceId, reference, note } = parsed.data;

  await db.runTransaction(async (tx) => {
    const ref = Paths.insurerInvoice(invoiceId);
    const invoice = (await tx.get(ref)).data();
    if (!invoice) throw notFound('No encontramos esa factura.');
    if (invoice['status'] !== InsurerInvoiceStatus.issued) {
      throw precondition(Code.invalidTransition, 'Solo se puede cobrar una factura pendiente.');
    }
    tx.update(ref, {
      status: InsurerInvoiceStatus.paid,
      paymentReference: reference,
      note,
      paidAt: FieldValue.serverTimestamp(),
      paidBy: caller.uid,
      updatedAt: FieldValue.serverTimestamp(),
    });
  });

  await audit(caller.uid, 'markInsurerInvoicePaid', invoiceId, { reference });
  logger.info('insurerInvoice.paid', { invoiceId, by: caller.uid });
  return { ok: true };
});

/**
 * Voids an unpaid invoice. Admin only.
 *
 * Its services go back to wait for the next invoice, which is how a wrong one
 * is corrected — or how the test invoices are made again with real NCFs. The
 * voided NCF stays used: the DGII has to be told about it in the 608 report.
 */
export const voidInsurerInvoice = onCall({ region, cors: true }, async (request) => {
  const parsed = z
    .object({
      invoiceId: z.string().min(1).max(128),
      reason: z.string().trim().min(3).max(300),
    })
    .safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Escribe por qué se anula la factura.');

  const caller = requireAdmin(request);
  const { invoiceId, reason } = parsed.data;

  const released = await db.runTransaction(async (tx) => {
    const ref = Paths.insurerInvoice(invoiceId);
    const invoice = (await tx.get(ref)).data();
    if (!invoice) throw notFound('No encontramos esa factura.');
    if (invoice['status'] !== InsurerInvoiceStatus.issued) {
      throw precondition(
        Code.invalidTransition,
        invoice['status'] === InsurerInvoiceStatus.paid
          ? 'Una factura cobrada no se anula: emite una nota de crédito.'
          : 'Esta factura ya está anulada.',
      );
    }

    const services = await tx.get(
      Paths.services().where('invoiceId', '==', invoiceId).limit(MAX_INVOICE_LINES + 50),
    );

    tx.update(ref, {
      status: InsurerInvoiceStatus.voided,
      voidReason: reason,
      voidedAt: FieldValue.serverTimestamp(),
      voidedBy: caller.uid,
      updatedAt: FieldValue.serverTimestamp(),
    });
    for (const service of services.docs) {
      tx.update(service.ref, {
        'payment.status': PaymentStatus.toInvoice,
        invoiceId: FieldValue.delete(),
        'payment.invoicedAt': FieldValue.delete(),
        updatedAt: FieldValue.serverTimestamp(),
      });
    }
    return services.size;
  });

  await audit(caller.uid, 'voidInsurerInvoice', invoiceId, { reason, released });
  logger.info('insurerInvoice.voided', { invoiceId, by: caller.uid, released });
  return { ok: true, released };
});

