import { getStorage } from 'firebase-admin/storage';
import { onCall } from 'firebase-functions/v2/https';
import { logger } from 'firebase-functions/v2';
import { z } from 'zod';

import { DriverDocumentType, LicenseVerificationState, UserRole } from '../lib/enums.js';
import { Code, invalidArgument, permissionDenied, precondition } from '../lib/errors.js';
import { FieldValue, Paths, Timestamp, db } from '../lib/firestore.js';
import { requireAdmin, requireAuth } from '../lib/guards.js';
import { type Image, licenseModel, readLicense } from '../lib/licenseAi.js';
import {
  type LicenseReading,
  type LicenseVerdict,
  afterAttempt,
  decideLicense,
} from '../lib/licenseCheck.js';
import { audit } from './admin.js';
import { region } from './region.js';

/**
 * The licence check a self-registered chofer goes through.
 *
 * It lives on the driver record as `licenseVerification`, which the chofer's
 * app and the roster already stream, so the waiting screen and the office's
 * list update the moment a verdict lands. Passing it does not activate the
 * account: that stays the office's decision, taken with `setDriverStatus`.
 */

/** A run older than this was lost to a crash or a timeout and may be retried. */
const STALE_RUN_MS = 5 * 60 * 1000;

const Field = 'licenseVerification';

interface StoredDocument {
  storagePath?: string;
  contentType?: string;
}

/**
 * Checks the chofer's licence photos. Called by the driver app once both sides
 * are attached, and again after a rejection with new photos.
 *
 * Runs the model inline rather than from a trigger: the chofer is looking at a
 * spinner, and a callable that answers in ten seconds is simpler to reason
 * about than a trigger racing a second upload.
 */
export const verifyDriverLicense = onCall(
  { region, cors: true, timeoutSeconds: 120, memory: '512MiB' },
  async (request) => {
    const caller = requireAuth(request);
    if (caller.role !== UserRole.driver) throw permissionDenied();
    const driverId = caller.uid;
    const driverRef = Paths.driver(driverId);
    const docs = Paths.driverDocuments(driverId);

    // Claimed in a transaction, so two taps — or a retry racing the first
    // call — run the model once.
    const claim = await db.runTransaction(async (tx) => {
      const [driverSnap, frontSnap, backSnap] = await Promise.all([
        tx.get(driverRef),
        tx.get(docs.doc(DriverDocumentType.licencia)),
        tx.get(docs.doc(DriverDocumentType.licenciaReverso)),
      ]);
      const driver = driverSnap.data();
      if (!driver) throw precondition(Code.notFound, 'Chofer no encontrado.');

      const current = driver[Field] as Record<string, unknown> | undefined;
      if (!current) {
        throw precondition(
          Code.invalidInput,
          'Tu cuenta la abrió la oficina y no necesita esta verificación.',
        );
      }

      const state = current['state'] as string;
      if (
        state === LicenseVerificationState.verified ||
        state === LicenseVerificationState.manualReview
      ) {
        return { run: false as const, state, reason: String(current['reason'] ?? '') };
      }
      if (state === LicenseVerificationState.processing) {
        const started = (current['startedAt'] as Timestamp | undefined)?.toMillis() ?? 0;
        if (Date.now() - started < STALE_RUN_MS) {
          return { run: false as const, state, reason: '' };
        }
      }

      const front = frontSnap.data() as StoredDocument | undefined;
      const back = backSnap.data() as StoredDocument | undefined;
      if (!front?.storagePath || !back?.storagePath) {
        throw precondition(
          Code.invalidInput,
          'Faltan fotos: sube el frente y el reverso de tu licencia.',
        );
      }

      const inputKey = `${front.storagePath}|${back.storagePath}`;
      if (state === LicenseVerificationState.rejected && current['inputKey'] === inputKey) {
        throw precondition(
          Code.invalidInput,
          'Estas fotos ya fueron revisadas. Sube fotos nuevas de tu licencia.',
        );
      }

      const attempt = Number(current['attempts'] ?? 0) + 1;
      tx.update(driverRef, {
        [`${Field}.state`]: LicenseVerificationState.processing,
        [`${Field}.attempts`]: attempt,
        [`${Field}.inputKey`]: inputKey,
        [`${Field}.reason`]: '',
        [`${Field}.startedAt`]: FieldValue.serverTimestamp(),
        [`${Field}.updatedAt`]: FieldValue.serverTimestamp(),
      });

      return {
        run: true as const,
        attempt,
        inputKey,
        front: front as Required<StoredDocument>,
        back: back as Required<StoredDocument>,
        claim: {
          name: String(driver['name'] ?? ''),
          cedula: String(driver['cedula'] ?? ''),
          licenseNumber: String(driver['licenseNumber'] ?? ''),
          licenseExpiry: (driver['licenseExpiry'] as Timestamp | null)?.toDate() ?? null,
        },
      };
    });

    if (!claim.run) return { state: claim.state, reason: claim.reason };

    let reading: LicenseReading | null = null;
    let verdict: LicenseVerdict;
    try {
      const [front, back, profile] = await Promise.all([
        download(claim.front.storagePath, claim.front.contentType),
        download(claim.back.storagePath, claim.back.contentType),
        profilePhoto(driverId),
      ]);
      reading = await readLicense(front, back, profile);
      verdict = afterAttempt(
        decideLicense(reading, claim.claim, new Date(), { hasProfilePhoto: profile !== null }),
        claim.attempt,
      );
    } catch (error) {
      // The model or the bucket failing is not the chofer's fault, and asking
      // them to try again would only burn an attempt. A person looks instead.
      logger.error('license.verifyFailed', { driverId, error: String(error) });
      verdict = {
        state: LicenseVerificationState.manualReview,
        reason: 'La oficina revisará tus documentos.',
        checks: [
          {
            key: 'automatic',
            label: 'Verificación automática',
            result: 'unclear',
            detail: 'No se pudo completar la verificación automática.',
          },
        ],
      };
    }

    // Written only if nobody else settled it meanwhile — an admin approving
    // by hand while the model was still reading keeps the admin's decision.
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(driverRef);
      const current = snap.data()?.[Field] as Record<string, unknown> | undefined;
      if (
        current?.['state'] !== LicenseVerificationState.processing ||
        current['inputKey'] !== claim.inputKey
      ) {
        return;
      }
      tx.update(driverRef, {
        [`${Field}.state`]: verdict.state,
        [`${Field}.reason`]: verdict.reason,
        [`${Field}.checks`]: verdict.checks,
        [`${Field}.extracted`]: reading
          ? {
              fullName: reading.fullName,
              cedula: reading.cedula,
              licenseNumber: reading.licenseNumber,
              expiryDate: reading.expiryDate,
            }
          : null,
        [`${Field}.notes`]: reading?.notes ?? '',
        [`${Field}.model`]: licenseModel,
        [`${Field}.completedAt`]: FieldValue.serverTimestamp(),
        [`${Field}.updatedAt`]: FieldValue.serverTimestamp(),
      });
    });

    logger.info('license.verified', {
      driverId,
      state: verdict.state,
      attempt: claim.attempt,
    });
    return { state: verdict.state, reason: verdict.reason };
  },
);

async function download(path: string, contentType: string | undefined): Promise<Image> {
  const [bytes] = await getStorage().bucket().file(path).download();
  return { bytes, mimeType: contentType || 'image/jpeg' };
}

/** The chofer's current profile photo; `setDriverPhoto` keeps only one. */
async function profilePhoto(driverId: string): Promise<Image | null> {
  const [files] = await getStorage()
    .bucket()
    .getFiles({ prefix: `drivers/${driverId}/avatar/` });
  const file = files[0];
  if (!file) return null;
  const [bytes] = await file.download();
  return { bytes, mimeType: String(file.metadata.contentType || 'image/jpeg') };
}

const reviewInput = z.object({
  driverId: z.string().min(1).max(64),
  decision: z.enum(['approve', 'reject']),
  reason: z.string().trim().max(300).default(''),
});

/**
 * The office's word on a licence, overriding the model either way.
 *
 * Rejecting hands the chofer a fresh set of tries: the office has said what is
 * wrong, and the next photos deserve a check of their own.
 */
export const reviewLicenseVerification = onCall({ region, cors: true }, async (request) => {
  const parsed = reviewInput.safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Datos inválidos.');

  const caller = requireAdmin(request);
  const { driverId, decision, reason } = parsed.data;
  if (decision === 'reject' && reason.length < 3) {
    throw invalidArgument('Escribe el motivo del rechazo.');
  }

  const driverRef = Paths.driver(driverId);
  const snap = await driverRef.get();
  const driver = snap.data();
  if (!driver) throw precondition(Code.notFound, 'Chofer no encontrado.');
  if (!driver[Field]) {
    throw precondition(Code.invalidInput, 'Este chofer no tiene verificación de licencia.');
  }

  await driverRef.update({
    [`${Field}.state`]:
      decision === 'approve'
        ? LicenseVerificationState.verified
        : LicenseVerificationState.rejected,
    [`${Field}.reason`]: decision === 'approve' ? '' : reason,
    ...(decision === 'reject' ? { [`${Field}.attempts`]: 0 } : {}),
    [`${Field}.reviewedBy`]: caller.uid,
    [`${Field}.reviewedAt`]: FieldValue.serverTimestamp(),
    [`${Field}.updatedAt`]: FieldValue.serverTimestamp(),
  });

  await audit(caller.uid, 'reviewLicenseVerification', driverId, { decision, reason });
  logger.info('license.reviewed', { driverId, decision, by: caller.uid });
  return { ok: true };
});
