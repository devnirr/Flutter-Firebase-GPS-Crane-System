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
  type CallParties,
} from '../lib/calls.js';
import { Code, invalidArgument, notFound, precondition } from '../lib/errors.js';
import { FieldValue, Paths, db } from '../lib/firestore.js';
import { requireAuth } from '../lib/guards.js';
import { notify } from '../lib/push.js';
import { livekitApiKey, livekitApiSecret, livekitUrl } from '../lib/secrets.js';
import { region } from './region.js';

/**
 * Voice calls between a customer and their chofer.
 *
 * A call is a document at `calls/{callId}` that both apps watch, plus a LiveKit
 * room the two of them join. The document is the ringing: the other party's
 * app sees it appear and shows Answer and Decline. The room is the audio. The
 * server owns both — it decides who may call, writes every state change, and
 * is the only thing holding the LiveKit secret.
 */

const secrets = [livekitApiKey, livekitApiSecret, livekitUrl];

/** Starts a call to the other party on a service, and joins the caller. */
export const startCall = onCall({ region, cors: true, secrets }, async (request) => {
  const parsed = z.object({ serviceId: z.string().min(1).max(64) }).safeParse(request.data);
  if (!parsed.success) throw invalidArgument('Servicio inválido.');

  const { uid } = requireAuth(request);
  const { serviceId } = parsed.data;

  const service = (await Paths.service(serviceId).get()).data();
  if (!service) throw notFound('Este servicio ya no existe.');

  const parties: CallParties = partiesFor(service, uid);

  const callRef = Paths.calls().doc();

  // One call per service at a time. Checked and written in one transaction so
  // two people pressing call at the same moment get one call, not two rooms
  // with one person waiting in each.
  await db.runTransaction(async (transaction) => {
    const open = await transaction.get(
      Paths.calls()
        .where('serviceId', '==', serviceId)
        .where('state', 'in', ACTIVE_CALL_STATES)
        .limit(1),
    );
    if (!open.empty) {
      throw precondition(Code.invalidTransition, 'Ya hay una llamada en curso.', {
        callId: open.docs[0]!.id,
      });
    }

    transaction.create(callRef, {
      serviceId,
      ...parties,
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
    title: 'Llamada entrante',
    body: `${parties.callerName} te está llamando.`,
    data: { type: 'incoming_call', callId: callRef.id, serviceId },
  }).catch((error: unknown) => logger.warn('call.pushFailed', { error: String(error) }));

  const join = await joinFor(callRef.id, uid, parties.callerName);
  logger.info('call.started', { callId: callRef.id, serviceId });

  return { callId: callRef.id, peerName: parties.calleeName, ...join };
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

  return { callId, peerName: call['callerName'] as string, ...join };
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
      data: { type: 'missed_call', callId, serviceId: outcome.data['serviceId'] as string },
    }).catch((error: unknown) => logger.warn('call.pushFailed', { error: String(error) }));
  }

  logger.info('call.ended', { callId, state: outcome.next ?? 'already-ended' });
  return { state: outcome.next ?? (outcome.data['state'] as string) };
});
