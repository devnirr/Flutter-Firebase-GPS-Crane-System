import { logger } from 'firebase-functions/v2';
import { onCall } from 'firebase-functions/v2/https';
import { z } from 'zod';

import {
  CHAT_OPEN_MS,
  CHAT_REQUEST_TTL_MS,
  ChatRequestStatus,
  chatRequestPhase,
  closingStatus,
  type ChatRequestPhase,
} from '../lib/chatRequests.js';
import { DriverStatus } from '../lib/enums.js';
import { Code, invalidArgument, precondition } from '../lib/errors.js';
import { FieldValue, Paths, Timestamp, db } from '../lib/firestore.js';
import { requireActiveDriver, requireAuth, requireClient } from '../lib/guards.js';
import { notify } from '../lib/push.js';
import { quoteSigningSecret } from '../lib/secrets.js';
import { openTruckRef } from '../lib/truckRef.js';
import { region } from './region.js';

/**
 * "Chatear" on a nearby truck.
 *
 * The customer holds only the sealed truck ref the search handed out, so the
 * chofer stays anonymous until they choose to answer: the request carries the
 * customer's name to the chofer, and the chofer's name comes back only on
 * acceptance. Nothing here creates a job — a conversation is not a commitment,
 * and the tow itself still goes through `requestService` and dispatch.
 */

const millis = (value: unknown): number | null =>
  value instanceof Timestamp ? value.toMillis() : null;

const phaseOf = (data: FirebaseFirestore.DocumentData, now: number): ChatRequestPhase =>
  chatRequestPhase(
    String(data['status'] ?? ''),
    millis(data['expiresAt']),
    millis(data['closesAt']),
    now,
  );

/** First two words: what the other side sees, and no more. */
const shortName = (name: unknown): string =>
  String(name ?? '')
    .trim()
    .split(/\s+/)
    .slice(0, 2)
    .join(' ');

const requestOnly = z.object({ requestId: z.string().min(1).max(64) });

/**
 * The customer asks the chofer of a nearby truck to talk.
 *
 * Refused when the ref is stale or the chofer can no longer take work — the
 * same pool the map showed. Asking the same truck again returns the request
 * already waiting or open, so a double tap is one conversation, not two.
 */
export const requestChat = onCall(
  { region, cors: true, secrets: [quoteSigningSecret] },
  async (request) => {
    const parsed = z
      .object({ truckRef: z.string().min(1).max(400) })
      .safeParse(request.data);
    if (!parsed.success) throw invalidArgument('Datos inválidos.');

    const { uid, user } = await requireClient(request);

    const unavailable = () =>
      precondition(
        Code.chatRequestUnavailable,
        'Este chofer no puede chatear ahora. Prueba con otra grúa.',
      );

    const driverId = openTruckRef(parsed.data.truckRef);
    if (!driverId) throw unavailable();

    const driver = (await Paths.driver(driverId).get()).data();
    if (
      !driver ||
      driver['status'] !== DriverStatus.active ||
      driver['isOnline'] !== true ||
      driver['currentServiceId']
    ) {
      throw unavailable();
    }

    const now = Date.now();
    const recent = await Paths.chatRequests()
      .where('clientId', '==', uid)
      .orderBy('createdAt', 'desc')
      .limit(10)
      .get();
    const open = recent.docs.find(
      (doc) => doc.data()['driverId'] === driverId && phaseOf(doc.data(), now) !== 'over',
    );
    if (open) return { requestId: open.id };

    const clientName = shortName(user['name']) || 'Cliente';
    const ref = Paths.chatRequests().doc();
    await ref.create({
      clientId: uid,
      clientName,
      driverId,
      driverName: '',
      status: ChatRequestStatus.pending,
      createdAt: FieldValue.serverTimestamp(),
      expiresAt: Timestamp.fromMillis(now + CHAT_REQUEST_TTL_MS),
      respondedAt: null,
      closesAt: null,
    });
    logger.info('chatRequest.created', { requestId: ref.id, clientId: uid, driverId });

    // The chofer app shows the request from its own listener; the push is for
    // a phone with the app in the background.
    await notify({
      uid: driverId,
      audience: 'driver',
      title: 'Solicitud de chat',
      body: `${clientName} quiere hablar contigo`,
      data: { type: 'chat_request', requestId: ref.id },
      channel: 'chat',
    }).catch((error: unknown) =>
      logger.warn('chatRequest.pushFailed', { requestId: ref.id, error }),
    );

    return { requestId: ref.id };
  },
);

/** The chofer accepts or declines. Only theirs, only once, only in time. */
export const respondChatRequest = onCall({ region, cors: true }, async (request) => {
  const parsed = requestOnly.extend({ accept: z.boolean() }).safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Datos inválidos.');

  const { uid, driver } = await requireActiveDriver(request);
  const { requestId, accept } = parsed.data;
  const ref = Paths.chatRequest(requestId);
  const now = Date.now();

  const clientId = await db.runTransaction(async (tx) => {
    const data = (await tx.get(ref)).data();
    if (!data || data['driverId'] !== uid) {
      throw precondition(Code.notFound, 'Esta solicitud ya no existe.');
    }
    if (phaseOf(data, now) !== 'waiting') {
      throw precondition(
        Code.chatRequestExpired,
        'Esta solicitud ya venció o fue respondida.',
      );
    }

    tx.update(
      ref,
      accept
        ? {
            status: ChatRequestStatus.accepted,
            driverName: shortName(driver['name']) || 'Chofer',
            driverPhotoUrl: driver['photoUrl'] ?? '',
            respondedAt: FieldValue.serverTimestamp(),
            closesAt: Timestamp.fromMillis(now + CHAT_OPEN_MS),
          }
        : {
            status: ChatRequestStatus.declined,
            respondedAt: FieldValue.serverTimestamp(),
          },
    );
    return data['clientId'] as string;
  });

  logger.info('chatRequest.answered', { requestId, driverId: uid, accept });

  await notify({
    uid: clientId,
    audience: 'client',
    title: accept ? 'El chofer aceptó tu chat' : 'El chofer no puede chatear',
    body: accept ? 'Ya puedes escribirle.' : 'Prueba con otra grúa cercana.',
    data: { type: 'chat_request', requestId },
    channel: 'chat',
  }).catch((error: unknown) =>
    logger.warn('chatRequest.pushFailed', { requestId, error }),
  );

  return { ok: true };
});

/** Either side ends it: withdrawn or refused while waiting, closed once open. */
export const closeChatRequest = onCall({ region, cors: true }, async (request) => {
  const parsed = requestOnly.safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Datos inválidos.');

  const caller = requireAuth(request);
  const ref = Paths.chatRequest(parsed.data.requestId);
  const now = Date.now();

  await db.runTransaction(async (tx) => {
    const data = (await tx.get(ref)).data();
    const byClient = data?.['clientId'] === caller.uid;
    if (!data || (!byClient && data['driverId'] !== caller.uid)) {
      throw precondition(Code.notFound, 'Esta conversación ya no existe.');
    }

    const next = closingStatus(phaseOf(data, now), byClient);
    if (next) {
      tx.update(ref, { status: next, closedAt: FieldValue.serverTimestamp() });
    }
  });

  return { ok: true };
});
