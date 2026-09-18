import { z } from 'zod';

import { isValidCompanyRnc } from './insurers.js';
import { fromLocal, toLocal } from './time.js';

/**
 * Números de Comprobante Fiscal: the numbering the DGII authorises.
 *
 * A B-series NCF is the letter B, two digits for the kind of receipt and eight
 * for the sequence: `B0100000001`. The DGII hands a company a range — "from 1
 * to 500, valid until 31 December 2027" — and every receipt takes the next
 * number of it, once.
 *
 * Until the company has its RNC and its first real range, the office runs on a
 * **test sequence**: the same format, starting at `B0100000001`, with every
 * receipt marked `isTestNcf`. When the real range arrives the office enters it
 * in the panel and the next receipt uses it; nothing is reprogrammed. A test
 * number and a real number may look the same, so they are registered apart.
 *
 * Nothing here touches Firestore.
 */

export const NcfPrefix = {
  /** Crédito fiscal: a buyer with an RNC who deducts the ITBIS. Insurers. */
  creditoFiscal: 'B01',
  /** Consumo: final consumers. */
  consumo: 'B02',
  /** Nota de débito. */
  notaDebito: 'B03',
  /** Nota de crédito: corrects a receipt already delivered. */
  notaCredito: 'B04',
  /** Comprobante de compras. */
  compras: 'B11',
  /** Registro único de ingresos. */
  registroUnico: 'B12',
  /** Gastos menores. */
  gastosMenores: 'B13',
  /** Regímenes especiales. */
  regimenEspecial: 'B14',
  /** Gubernamental. */
  gubernamental: 'B15',
  /** Exportaciones. */
  exportaciones: 'B16',
  /** Pagos al exterior. */
  pagosExterior: 'B17',
} as const;

export type NcfPrefix = (typeof NcfPrefix)[keyof typeof NcfPrefix];

const PREFIXES = Object.values(NcfPrefix) as [NcfPrefix, ...NcfPrefix[]];

export const NCF_DIGITS = 8;
export const MAX_NCF_NUMBER = 99_999_999;

/** `B01` and 1 → `B0100000001`. */
export function formatNcf(prefix: NcfPrefix, sequence: number): string {
  if (!Number.isInteger(sequence) || sequence < 1 || sequence > MAX_NCF_NUMBER) {
    throw new RangeError(`NCF sequence out of range: ${sequence}`);
  }
  return `${prefix}${sequence.toString().padStart(NCF_DIGITS, '0')}`;
}

/** The parts of a B-series NCF, or null when it is not one. */
export function parseNcf(ncf: string): { prefix: NcfPrefix; sequence: number } | null {
  const match = /^(B\d{2})(\d{8})$/.exec(ncf.trim().toUpperCase());
  if (!match) return null;
  const prefix = match[1] as NcfPrefix;
  if (!PREFIXES.includes(prefix)) return null;
  const sequence = Number(match[2]);
  return sequence >= 1 ? { prefix, sequence } : null;
}

/** The range the office is numbering from, at `fiscal/ncf_{prefix}`. */
export interface NcfSequence {
  prefix: NcfPrefix;
  /** The number the next receipt takes. */
  nextNumber: number;
  /** The last number of the authorised range. */
  lastNumber: number;
  /** `2027-12-31`: the last day the range may be used. Null for none. */
  expiresOn: string | null;
  /** A made-up range, for working before the DGII authorises a real one. */
  isTest: boolean;
}

/** What the office numbers from before it has entered any range. */
export const testSequence = (prefix: NcfPrefix): NcfSequence => ({
  prefix,
  nextNumber: 1,
  lastNumber: MAX_NCF_NUMBER,
  expiresOn: null,
  isTest: true,
});

/** The end of [expiresOn] in Santo Domingo, as an instant. */
export function expiryInstant(expiresOn: string): Date {
  const [y, m, d] = expiresOn.split('-').map(Number) as [number, number, number];
  return fromLocal(new Date(Date.UTC(y, m - 1, d + 1)));
}

/** Why no receipt can be numbered from [sequence] at [now], or null. */
export function sequenceProblem(sequence: NcfSequence, now: Date): string | null {
  if (sequence.nextNumber > sequence.lastNumber) {
    return `Se agotó la secuencia de NCF ${sequence.prefix} (hasta ${formatNcf(
      sequence.prefix,
      sequence.lastNumber,
    )}). Registra la nueva secuencia autorizada por la DGII.`;
  }
  if (sequence.expiresOn && now.getTime() >= expiryInstant(sequence.expiresOn).getTime()) {
    return `La secuencia de NCF ${sequence.prefix} venció el ${sequence.expiresOn}. Registra la nueva secuencia autorizada por la DGII.`;
  }
  return null;
}

/** Receipts left in the range, the next one included. */
export const remainingIn = (sequence: NcfSequence): number =>
  Math.max(0, sequence.lastNumber - sequence.nextNumber + 1);

/**
 * The key an NCF is registered under, so none is ever issued twice.
 *
 * Test numbers have their own space: the real `B0100000001` must still be
 * issuable after the test one was.
 */
export const ncfRegistryKey = (ncf: string, isTest: boolean): string =>
  isTest ? `TEST-${ncf}` : ncf;

const isoDay = z
  .string()
  .regex(/^\d{4}-\d{2}-\d{2}$/, 'Fecha inválida')
  .refine((s) => {
    const [y, m, d] = s.split('-').map(Number) as [number, number, number];
    const date = new Date(Date.UTC(y, m - 1, d));
    return date.getUTCFullYear() === y && date.getUTCMonth() === m - 1 && date.getUTCDate() === d;
  }, 'Fecha inválida');

/** What the office types when the DGII authorises a range, or a test one. */
export const ncfSequenceInput = z
  .object({
    prefix: z.enum(PREFIXES),
    /** The number the next receipt takes: the start of a new range. */
    nextNumber: z.number().int().min(1).max(MAX_NCF_NUMBER),
    lastNumber: z.number().int().min(1).max(MAX_NCF_NUMBER),
    expiresOn: isoDay.nullish(),
    isTest: z.boolean(),
  })
  .superRefine((value, ctx) => {
    if (value.lastNumber < value.nextNumber) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['lastNumber'],
        message: 'El número final debe ser mayor o igual al inicial.',
      });
    }
    if (!value.isTest && !value.expiresOn) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['expiresOn'],
        message: 'Una secuencia real necesita su fecha de vencimiento.',
      });
    }
  });

export type NcfSequenceInput = z.infer<typeof ncfSequenceInput>;

/** The company that issues the receipts, at `fiscal/issuer`. */
export interface FiscalIssuer {
  name: string;
  /** Empty while the company is still being registered. */
  rnc: string;
  address: string;
  phone: string;
  email: string;
  /** Days an insurer has to pay a monthly invoice. */
  paymentTermsDays: number;
}

export const DEFAULT_PAYMENT_TERMS_DAYS = 30;

/** What the receipts say before the office fills anything in. */
export const DEFAULT_ISSUER: FiscalIssuer = {
  name: 'GRÚAS RD, SRL (en constitución)',
  rnc: '',
  address: 'Santo Domingo, República Dominicana',
  phone: '',
  email: '',
  paymentTermsDays: DEFAULT_PAYMENT_TERMS_DAYS,
};

export const fiscalIssuerInput = z.object({
  name: z.string().trim().min(2, 'Escribe la razón social.').max(160),
  rnc: z
    .string()
    .trim()
    .max(20)
    .refine((v) => v === '' || isValidCompanyRnc(v), 'Ese RNC no es válido.')
    .transform((v) => v.replace(/\D/g, '')),
  address: z.string().trim().max(300).default(''),
  phone: z.string().trim().max(30).default(''),
  email: z.string().trim().email('Correo inválido').max(200).or(z.literal('')).default(''),
  paymentTermsDays: z.number().int().min(0).max(180).default(DEFAULT_PAYMENT_TERMS_DAYS),
});

/** An issuer as stored, with the defaults filling anything missing. */
export function issuerOf(data: Record<string, unknown> | undefined): FiscalIssuer {
  const text = (key: keyof FiscalIssuer) =>
    typeof data?.[key] === 'string' ? (data[key] as string) : (DEFAULT_ISSUER[key] as string);
  const terms = data?.['paymentTermsDays'];
  return {
    name: text('name') || DEFAULT_ISSUER.name,
    rnc: text('rnc'),
    address: text('address'),
    phone: text('phone'),
    email: text('email'),
    paymentTermsDays:
      typeof terms === 'number' && Number.isInteger(terms) && terms >= 0
        ? terms
        : DEFAULT_PAYMENT_TERMS_DAYS,
  };
}

/** A stored sequence, or the test one when there is none or it is unreadable. */
export function sequenceOf(prefix: NcfPrefix, data: Record<string, unknown> | undefined): NcfSequence {
  if (!data) return testSequence(prefix);
  const int = (v: unknown) => (typeof v === 'number' && Number.isInteger(v) ? v : null);
  const next = int(data['nextNumber']);
  const last = int(data['lastNumber']);
  if (next === null || last === null) return testSequence(prefix);
  const expiresOn = typeof data['expiresOn'] === 'string' ? (data['expiresOn'] as string) : null;
  return {
    prefix,
    nextNumber: next,
    lastNumber: last,
    expiresOn,
    // Anything but an explicit false is a test range: a real NCF is never
    // issued by accident.
    isTest: data['isTest'] !== false,
  };
}

/** `2026-09-16`, in Santo Domingo. */
export function localIsoDay(instant: Date): string {
  const local = toLocal(instant);
  return local.toISOString().slice(0, 10);
}
