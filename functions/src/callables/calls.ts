import { onCall } from 'firebase-functions/v2/https';
import { logger } from 'firebase-functions/v2';
import { z } from 'zod';

import {
  ACTIVE_CALL_STATES,
  CallState,
  assertAnswerable,
  endedState,
  joinFor,
  partiesFor,
  partiesForChatRequest,
  type CallParties,
} from '../lib/calls.js';
import { Code, invalidArgument, notFound, precondition } from '../lib/errors.js';
import { FieldValue, Paths, Timestamp, db } from '../lib/firestore.js';
import { requireAuth } from '../lib/guards.js';
import { notify } from '../lib/push.js';
import { livekitApiKey, livekitApiSecret, livekitUrl } from '../lib/secrets.js';
import { region } from './region.js';

/**
 * Voice and video calls between a customer and their chofer.
 *
 * A call is a document at `calls/{callId}` that both apps watch, plus a LiveKit
 * room the two of them join. The document is the ringing: the other party's
 * app sees it appear and shows Answer and Decline. The room is the audio, and
 * the picture when `video` is set. The server owns both — it decides who may
 * call, writes every state change, and is the only thing holding the LiveKit
 * secret.
 */

const secrets = [livekitApiKey, livekitApiSecret, livekitUrl];

const millis = (value: unknown): number | null =>
  value instanceof Timestamp ? value.toMillis() : null;

/**
 * Starts a call to the other party, and joins the caller.
 *
 * On a service ([serviceId]) or in a conversation opened from a nearby truck
 * before any job ([chatRequestId]) — exactly one of the two.
 */
export const startCall = onCall({ region, cors: true, secrets }, async (request) => {
  const parsed = z
    .object({
      serviceId: z.string().min(1).max(64).optional(),
      chatRequestId: z.string().min(1).max(64).optional(),
      // Absent from builds that only knew voice, which is what they placed.
      video: z.boolean().default(false),
    })
    .refine((data) => Boolean(data.serviceId) !== Boolean(data.chatRequestId))
    .safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Llamada inválida.');

  const { uid } = requireAuth(request);
  const { serviceId, chatRequestId, video } = parsed.data;

  let parties: CallParties;
  // Which conversation the call belongs to, on the call and in its lookup.
  let scope: { field: 'serviceId' | 'chatRequestId'; id: string };

  if (serviceId) {
    const service = (await Paths.service(serviceId).get()).data();
    if (!service) throw notFound('Este servicio ya no existe.');
    parties = partiesFor(service, uid);
    scope = { field: 'serviceId', id: serviceId };
  } else {
    const id = chatRequestId!;
    const chat = (await Paths.chatRequest(id).get()).data();
    if (!chat) throw notFound('Esta conversación ya no existe.');
    parties = partiesForChatRequest(
      {
        ...chat,
        expiresAtMs: millis(chat['expiresAt']),
        closesAtMs: millis(chat['closesAt']),
      },
      uid,
      Date.now(),
    );
    // Two strangers until a job exists: a block stops the phone ringing as
    // well as the messages, whichever of the two did the blocking.
    const [blockedByCallee, blockedByCaller] = await Promise.all([
      Paths.user(parties.calleeId).collection('blocked').doc(uid).get(),
      Paths.user(uid).collection('blocked').doc(parties.calleeId).get(),
    ]);
    if (blockedByCallee.exists || blockedByCaller.exists) {
      throw precondition(Code.invalidTransition, 'No puedes llamar a esta persona.');
    }
    scope = { field: 'chatRequestId', id };
  }

  const callRef = Paths.calls().doc();

  // One call per conversation at a time. Checked and written in one
  // transaction so two people pressing call at the same moment get one call,
  // not two rooms with one person waiting in each.
  await db.runTransaction(async (transaction) => {
    const open = await transaction.get(
      Paths.calls()
        .where(scope.field, '==', scope.id)
        .where('state', 'in', ACTIVE_CALL_STATES)
        .limit(1),
    );
    if (!open.empty) {
      throw precondition(Code.invalidTransition, 'Ya hay una llamada en curso.', {
        callId: open.docs[0]!.id,
      });
    }

    transaction.create(callRef, {
      [scope.field]: scope.id,
      ...parties,
      video,
      state: CallState.ringing,
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
  });

  // After commit: a push inside the transaction would fire twice on a retry.
  // The app on screen sees the document anyway; the push is for a phone whose
  // app is in the background.
  await notify({
    uid: parties.calleeId,
    audience: parties.calleeRole,
    title: video ? 'Videollamada entrante' : 'Llamada entrante',
    body: `${parties.callerName} te está ${video ? 'videollamando' : 'llamando'}.`,
    data: {
      type: 'incoming_call',
      callId: callRef.id,
      [scope.field]: scope.id,
      video: String(video),
    },
  }).catch((error: unknown) => logger.warn('call.pushFailed', { error: String(error) }));

  const join = await joinFor(callRef.id, uid, parties.callerName);
  logger.info('call.started', { callId: callRef.id, [scope.field]: scope.id, video });

  return { callId: callRef.id, peerName: parties.calleeName, video, ...join };
});

/** Answers a ringing call and joins the callee. */
export const answerCall = onCall({ region, cors: true, secrets }, async (request) => {
  const parsed = z.object({ callId: z.string().min(1).max(64) }).safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Llamada inválida.');

  const { uid } = requireAuth(request);
  const { callId } = parsed.data;
  const ref = Paths.call(callId);

  const call = await db.runTransaction(async (transaction) => {
    const data = (await transaction.get(ref)).data();
    if (!data) throw notFound('Esta llamada ya no existe.');

    assertAnswerable(
      {
        state: data['state'] as CallState,
        calleeId: data['calleeId'] as string,
        createdAtMs:
          (data['createdAt'] as FirebaseFirestore.Timestamp | undefined)?.toMillis() ??
          Date.now(),
      },
      uid,
      Date.now(),
    );

    transaction.update(ref, {
      state: CallState.accepted,
      answeredAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    return data;
  });

  const join = await joinFor(callId, uid, call['calleeName'] as string);
  logger.info('call.answered', { callId });

  return {
    callId,
    peerName: call['callerName'] as string,
    video: call['video'] === true,
    ...join,
  };
});

/** Ends a call — hang up, decline, cancel, or give up after ringing out. */
export const endCall = onCall({ region, cors: true }, async (request) => {
  const parsed = z
    .object({
      callId: z.string().min(1).max(64),
      reason: z.enum(['hangup', 'declined', 'missed', 'cancelled']).default('hangup'),
    })
    .safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Llamada inválida.');

  const { uid } = requireAuth(request);
  const { callId, reason } = parsed.data;
  const ref = Paths.call(callId);

  const outcome = await db.runTransaction(async (transaction) => {
    const data = (await transaction.get(ref)).data();
    if (!data) throw notFound('Esta llamada ya no existe.');

    const next = endedState(
      {
        state: data['state'] as CallState,
        callerId: data['callerId'] as string,
        calleeId: data['calleeId'] as string,
      },
      uid,
      reason,
    );
    if (next === null) return { next: null, data };

    transaction.update(ref, {
      state: next,
      endedBy: uid,
      endedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    return { next, data };
  });

  // Somebody who was rung and did not pick up should find out they missed it.
  if (outcome.next === CallState.missed) {
    await notify({
      uid: outcome.data['calleeId'] as string,
      audience: outcome.data['calleeRole'] as 'client' | 'driver',
      title: 'Llamada perdida',
      body: `${outcome.data['callerName'] as string} te llamó.`,
      // Whichever conversation it was: a call in a pre-job chat has no
      // service, and a push payload cannot carry an undefined value.
      data: {
        type: 'missed_call',
        callId,
        ...(typeof outcome.data['serviceId'] === 'string'
          ? { serviceId: outcome.data['serviceId'] }
          : {}),
        ...(typeof outcome.data['chatRequestId'] === 'string'
          ? { chatRequestId: outcome.data['chatRequestId'] }
          : {}),
      },
    }).catch((error: unknown) => logger.warn('call.pushFailed', { error: String(error) }));
  }

  logger.info('call.ended', { callId, state: outcome.next ?? 'already-ended' });
  return { state: outcome.next ?? (outcome.data['state'] as string) };
});
