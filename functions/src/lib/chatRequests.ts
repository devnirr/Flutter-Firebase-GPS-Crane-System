/**
 * Chat requests: a customer asking the chofer of a nearby truck to talk, before
 * any job exists.
 *
 * Kept free of Firestore so the rules that decide what a request may still do
 * are testable on any machine, and so the app's `ChatRequest.phaseAt` has one
 * place to mirror.
 */

export const ChatRequestStatus = {
  pending: 'pending',
  accepted: 'accepted',
  declined: 'declined',
  cancelled: 'cancelled',
  closed: 'closed',
} as const;

export type ChatRequestStatus = (typeof ChatRequestStatus)[keyof typeof ChatRequestStatus];

/** How long a chofer has to answer. A request nobody answers is not left hanging. */
export const CHAT_REQUEST_TTL_MS = 5 * 60 * 1000;

/**
 * How long an accepted conversation stays open. Enough to settle a price or
 * a meeting point; not a standing line to a chofer's phone.
 */
export const CHAT_OPEN_MS = 2 * 60 * 60 * 1000;

/**
 * Where a request stands: waiting for the chofer, open for messages, or over.
 * A pending request past its expiry is over even though nothing rewrote it.
 */
export type ChatRequestPhase = 'waiting' | 'open' | 'over';

/**
 * Whether an accepted conversation is still missing the chofer's face.
 *
 * `respondChatRequest` copies the photo across when the chofer accepts, but
 * conversations accepted before it did — and any where the chofer's photo was
 * set afterwards — carry a name and no face. The customer then sees a grey
 * initial beside a chofer who has a photo on file.
 */
export function needsDriverPhoto(request: {
  status?: unknown;
  driverId?: unknown;
  driverPhotoUrl?: unknown;
}): boolean {
  return (
    request.status === ChatRequestStatus.accepted &&
    typeof request.driverId === 'string' &&
    request.driverId.length > 0 &&
    !(typeof request.driverPhotoUrl === 'string' && request.driverPhotoUrl.length > 0)
  );
}

export function chatRequestPhase(
  status: string,
  expiresAtMs: number | null,
  closesAtMs: number | null,
  now: number,
): ChatRequestPhase {
  if (status === ChatRequestStatus.pending) {
    return expiresAtMs === null || now < expiresAtMs ? 'waiting' : 'over';
  }
  if (status === ChatRequestStatus.accepted) {
    return closesAtMs === null || now < closesAtMs ? 'open' : 'over';
  }
  return 'over';
}

/**
 * What closing a request turns it into, or null when there is nothing to
 * close. Unanswered, the customer withdrawing it is a cancellation and the
 * chofer doing so is a refusal; answered, either one ends the conversation.
 */
export function closingStatus(
  phase: ChatRequestPhase,
  byClient: boolean,
): ChatRequestStatus | null {
  if (phase === 'waiting') {
    return byClient ? ChatRequestStatus.cancelled : ChatRequestStatus.declined;
  }
  if (phase === 'open') return ChatRequestStatus.closed;
  return null;
}
