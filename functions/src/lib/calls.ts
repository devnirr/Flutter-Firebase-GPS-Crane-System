import { AccessToken } from 'livekit-server-sdk';

import { chatRequestPhase } from './chatRequests.js';
import { CONTACT_OPEN_STATUSES, type ServiceStatus } from './enums.js';
import { Code, permissionDenied, precondition } from './errors.js';
import { livekitApiKey, livekitApiSecret, livekitUrl } from './secrets.js';

/**
 * Voice and video calls between a customer and a chofer: on a service, or in
 * a conversation opened from a nearby truck before any job.
 *
 * The call itself goes through LiveKit; everything here is what decides
 * whether a call may happen and what state it is in. Kept free of Firestore so
 * the rules can be tested on their own — the callables in
 * `callables/calls.ts` read and write, this decides.
 */

export const CallState = {
  ringing: 'ringing',
  accepted: 'accepted',
  declined: 'declined',
  missed: 'missed',
  cancelled: 'cancelled',
  ended: 'ended',
} as const;

export type CallState = (typeof CallState)[keyof typeof CallState];

export const ACTIVE_CALL_STATES: readonly CallState[] = [
  CallState.ringing,
  CallState.accepted,
];

/** How long a call may ring before nobody answering counts as missed. */
export const RING_TIMEOUT_MS = 45_000;

/** Why a party ended a call, as the app reports it. */
export type EndReason = 'hangup' | 'declined' | 'missed' | 'cancelled';

export interface CallParties {
  callerId: string;
  callerRole: 'client' | 'driver';
  callerName: string;
  calleeId: string;
  calleeRole: 'client' | 'driver';
  calleeName: string;
}

/**
 * Who is calling whom on this service, or a refusal.
 *
 * Only the two parties to a service, and only while contact is open — the same
 * window the chat button uses. A customer cannot ring a chofer before one has
 * accepted, and neither can ring the other once the tow is over.
 */
export function partiesFor(
  service: FirebaseFirestore.DocumentData,
  callerId: string,
): CallParties {
  const status = service['status'] as ServiceStatus;
  const clientId = service['clientId'] as string | undefined;
  const driverId = service['driverId'] as string | undefined;

  if (callerId !== clientId && callerId !== driverId) {
    throw permissionDenied('No formas parte de este servicio.');
  }
  // An insurer's tow has no customer account to ring; the chofer calls the
  // insured person's phone instead.
  if (!clientId) {
    throw precondition(
      Code.invalidTransition,
      'Este servicio no tiene un cliente en la app. Llama al asegurado por teléfono.',
    );
  }
  if (!driverId || !CONTACT_OPEN_STATUSES.includes(status)) {
    throw precondition(
      Code.invalidTransition,
      'Solo puedes llamar mientras el servicio está en curso.',
    );
  }

  const clientName = (service['clientName'] as string | undefined) || 'Cliente';
  const driverName = (service['driverName'] as string | undefined) || 'Chofer';

  return callerId === clientId
    ? {
        callerId: clientId,
        callerRole: 'client',
        callerName: clientName,
        calleeId: driverId,
        calleeRole: 'driver',
        calleeName: driverName,
      }
    : {
        callerId: driverId,
        callerRole: 'driver',
        callerName: driverName,
        calleeId: clientId!,
        calleeRole: 'client',
        calleeName: clientName,
      };
}

/**
 * Who is calling whom in a conversation opened from a nearby truck, before any
 * job, or a refusal.
 *
 * Only the customer and the chofer of that conversation, and only while it is
 * open — the chofer accepted and neither side has closed it. The same window
 * in which the two may write to each other, so a stranger's phone never rings
 * for a request the chofer did not answer.
 */
export function partiesForChatRequest(
  request: {
    status?: unknown;
    clientId?: unknown;
    clientName?: unknown;
    driverId?: unknown;
    driverName?: unknown;
    expiresAtMs: number | null;
    closesAtMs: number | null;
  },
  callerId: string,
  now: number,
): CallParties {
  const clientId = typeof request.clientId === 'string' ? request.clientId : '';
  const driverId = typeof request.driverId === 'string' ? request.driverId : '';

  if (!callerId || (callerId !== clientId && callerId !== driverId)) {
    throw permissionDenied('No formas parte de esta conversación.');
  }
  const phase = chatRequestPhase(
    String(request.status ?? ''),
    request.expiresAtMs,
    request.closesAtMs,
    now,
  );
  if (phase !== 'open') {
    throw precondition(
      Code.invalidTransition,
      'Solo puedes llamar mientras la conversación está abierta.',
    );
  }

  const clientName = (request.clientName as string | undefined) || 'Cliente';
  const driverName = (request.driverName as string | undefined) || 'Chofer';

  return callerId === clientId
    ? {
        callerId: clientId,
        callerRole: 'client',
        callerName: clientName,
        calleeId: driverId,
        calleeRole: 'driver',
        calleeName: driverName,
      }
    : {
        callerId: driverId,
        callerRole: 'driver',
        callerName: driverName,
        calleeId: clientId,
        calleeRole: 'client',
        calleeName: clientName,
      };
}

/**
 * The state a call moves to when [by] ends it for [reason], or null when it
 * has already ended and there is nothing to do.
 *
 * Idempotent on purpose: both phones hang up at once, a network retry repeats
 * the call, and the ring timeout fires on a call somebody already answered.
 * None of those may turn an ended call into a different kind of ended.
 */
export function endedState(
  call: { state: CallState; callerId: string; calleeId: string },
  by: string,
  reason: EndReason,
): CallState | null {
  if (by !== call.callerId && by !== call.calleeId) {
    throw permissionDenied('No formas parte de esta llamada.');
  }
  if (!ACTIVE_CALL_STATES.includes(call.state)) return null;

  if (call.state === CallState.accepted) return CallState.ended;

  // Still ringing.
  if (by === call.calleeId) return CallState.declined;
  return reason === 'missed' ? CallState.missed : CallState.cancelled;
}

/**
 * Whether [by] may answer, or a refusal saying why not.
 *
 * Answering a call that stopped ringing — the caller gave up a second before
 * the tap landed — has to say so rather than drop the chofer into an empty
 * room.
 */
export function assertAnswerable(
  call: { state: CallState; calleeId: string; createdAtMs: number },
  by: string,
  now: number,
): void {
  if (by !== call.calleeId) {
    throw permissionDenied('Esta llamada no es para ti.');
  }
  if (call.state !== CallState.ringing || now - call.createdAtMs > RING_TIMEOUT_MS + 15_000) {
    throw precondition(Code.invalidTransition, 'La llamada ya terminó.');
  }
}

/** The room a call's two parties meet in. One room per call, never reused. */
export const roomFor = (callId: string): string => `call-${callId}`;

/**
 * Where to connect and the pass to get in, for one party to one call.
 *
 * Issued by the server because the LiveKit secret must never reach a phone:
 * with it anyone could mint a token for any room. Short-lived, and good for
 * exactly this room.
 */
export async function joinFor(
  callId: string,
  identity: string,
  name: string,
): Promise<{ url: string; token: string; room: string }> {
  const key = livekitApiKey.value().trim();
  const secret = livekitApiSecret.value().trim();
  const url = livekitUrl.value().trim();

  if (!key || !secret || !url) {
    throw precondition(
      Code.invalidTransition,
      'Las llamadas no están configuradas todavía. Usa el chat mientras tanto.',
    );
  }

  const room = roomFor(callId);
  const token = new AccessToken(key, secret, { identity, name, ttl: '2h' });
  token.addGrant({
    roomJoin: true,
    room,
    canPublish: true,
    canSubscribe: true,
    canPublishData: false,
  });

  return { url, token: await token.toJwt(), room };
}
