import { describe, expect, it } from 'vitest';

import {
  CHAT_OPEN_MS,
  CHAT_REQUEST_TTL_MS,
  ChatRequestStatus,
  chatRequestPhase,
  closingStatus,
  needsDriverPhoto,
} from '../src/lib/chatRequests.js';

/**
 * What a chat request may still do, decided without Firestore — the same
 * answers the apps compute in `ChatRequest.phaseAt`.
 */
describe('chat requests', () => {
  const now = 1_800_000_000_000;

  it('waits for the chofer until it expires, then is over', () => {
    const expires = now + CHAT_REQUEST_TTL_MS;
    expect(chatRequestPhase(ChatRequestStatus.pending, expires, null, now)).toBe('waiting');
    expect(chatRequestPhase(ChatRequestStatus.pending, expires, null, expires)).toBe('over');
  });

  it('is open once accepted, until it closes on its own', () => {
    const closes = now + CHAT_OPEN_MS;
    expect(chatRequestPhase(ChatRequestStatus.accepted, null, closes, now)).toBe('open');
    expect(chatRequestPhase(ChatRequestStatus.accepted, null, closes, closes + 1)).toBe('over');
  });

  it('is over for good once declined, cancelled or closed', () => {
    for (const status of [
      ChatRequestStatus.declined,
      ChatRequestStatus.cancelled,
      ChatRequestStatus.closed,
      'something_new',
    ]) {
      expect(chatRequestPhase(status, now + 1, now + 1, now)).toBe('over');
    }
  });

  it('closes as a cancellation, a refusal, or the end of the conversation', () => {
    expect(closingStatus('waiting', true)).toBe(ChatRequestStatus.cancelled);
    expect(closingStatus('waiting', false)).toBe(ChatRequestStatus.declined);
    expect(closingStatus('open', true)).toBe(ChatRequestStatus.closed);
    expect(closingStatus('open', false)).toBe(ChatRequestStatus.closed);
    expect(closingStatus('over', true)).toBeNull();
  });
});

describe("the chofer's face on a conversation", () => {
  const accepted = {
    status: ChatRequestStatus.accepted,
    driverId: 'driver-1',
    driverPhotoUrl: '',
  };

  it('is wanted on an accepted conversation that has none', () => {
    expect(needsDriverPhoto(accepted)).toBe(true);
  });

  it('is left alone once it is there', () => {
    expect(
      needsDriverPhoto({ ...accepted, driverPhotoUrl: 'https://example/p.jpg' }),
    ).toBe(false);
  });

  it('is not filled in before the chofer answers', () => {
    // Nobody learns who drives the truck until they choose to answer.
    expect(needsDriverPhoto({ ...accepted, status: ChatRequestStatus.pending }))
      .toBe(false);
    expect(needsDriverPhoto({ ...accepted, status: ChatRequestStatus.declined }))
      .toBe(false);
  });

  it('needs a chofer to ask about', () => {
    expect(needsDriverPhoto({ ...accepted, driverId: '' })).toBe(false);
  });
});
