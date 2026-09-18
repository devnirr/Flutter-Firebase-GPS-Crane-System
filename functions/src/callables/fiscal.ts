import { onCall } from 'firebase-functions/v2/https';
import { logger } from 'firebase-functions/v2';

import { Code, invalidArgument, precondition } from '../lib/errors.js';
import {
  expiryInstant,
  fiscalIssuerInput,
  formatNcf,
  ncfRegistryKey,
  ncfSequenceInput,
} from '../lib/fiscal.js';
import { FieldValue, Paths, db } from '../lib/firestore.js';
import { requireAdmin } from '../lib/guards.js';
import { audit } from './admin.js';
import { region } from './region.js';

/**
 * The company's fiscal details and its NCF ranges. Admin only.
 *
 * This is the whole switch from test receipts to real ones: when the DGII
 * authorises a range, the office enters it here — first number, last number,
 * expiry — with "prueba" unticked, and the next invoice is numbered from it.
 */

const firstIssue = (
  error: { issues: { message: string }[] },
  fallback: string,
): string => error.issues[0]?.message ?? fallback;

/** Razón social, RNC, address and payment terms printed on every invoice. */
export const saveFiscalIssuer = onCall({ region, cors: true }, async (request) => {
  const parsed = fiscalIssuerInput.safeParse(request.data);
  if (!parsed.success) throw invalidArgument(firstIssue(parsed.error, 'Datos fiscales inválidos.'));

  const caller = requireAdmin(request);
  await Paths.fiscalIssuer().set(
    {
      ...parsed.data,
      updatedAt: FieldValue.serverTimestamp(),
      updatedBy: caller.uid,
    },
    { merge: true },
  );

  await audit(caller.uid, 'saveFiscalIssuer', 'issuer', {
    name: parsed.data.name,
    rnc: parsed.data.rnc,
  });
  logger.info('fiscal.issuerSaved', { by: caller.uid });
  return { ok: true };
});

/**
 * Sets the range a kind of receipt is numbered from.
 *
 * A real range is refused when its first number was already issued as a real
 * NCF: that is a typo, and a repeated NCF is a fiscal problem. A test range
 * may start anywhere; test numbers are registered apart.
 */
export const saveNcfSequence = onCall({ region, cors: true }, async (request) => {
  const parsed = ncfSequenceInput.safeParse(request.data);
  if (!parsed.success) throw invalidArgument(firstIssue(parsed.error, 'Secuencia inválida.'));

  const caller = requireAdmin(request);
  const { prefix, nextNumber, lastNumber, isTest } = parsed.data;
  const expiresOn = parsed.data.expiresOn ?? null;
  const first = formatNcf(prefix, nextNumber);
  if (expiresOn && expiryInstant(expiresOn).getTime() <= Date.now()) {
    throw invalidArgument('Esa fecha de vencimiento ya pasó.');
  }

  await db.runTransaction(async (tx) => {
    const used = await tx.get(Paths.ncfRegistry(ncfRegistryKey(first, isTest)));
    if (used.exists) {
      throw precondition(
        Code.ncfUnavailable,
        `El NCF ${first} ya fue emitido${isTest ? ' como prueba' : ''}. La secuencia debe empezar en un número sin usar.`,
      );
    }
    tx.set(
      Paths.ncfSequence(prefix),
      {
        prefix,
        nextNumber,
        lastNumber,
        expiresOn,
        isTest,
        updatedAt: FieldValue.serverTimestamp(),
        updatedBy: caller.uid,
      },
      { merge: true },
    );
  });

  await audit(caller.uid, 'saveNcfSequence', prefix, {
    first,
    last: formatNcf(prefix, lastNumber),
    expiresOn,
    isTest,
  });
  logger.info('fiscal.sequenceSaved', { prefix, first, isTest, by: caller.uid });
  return { ok: true, next: first };
});
