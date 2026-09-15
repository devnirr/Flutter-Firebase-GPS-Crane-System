import { beforeEach, describe, expect, it, vi } from 'vitest';

/**
 * Who may call whom, and what a call becomes when somebody ends it.
 *
 * The phone button on the chofer's service screen and the customer's "Llamar"
 * used to show "Llamando a …" and do nothing. These are the rules the real
 * calls run on.
 */

const secret = { key: 'APIkey123', secret: 'a'.repeat(40), url: 'wss://grua.livekit.cloud' };
vi.mock('../src/lib/secrets.js', () => ({
  livekitApiKey: { value: () => secret.key },
  livekitApiSecret: { value: () => secret.secret },
  livekitUrl: { value: () => secret.url },
}));

const {
  CallState,
  RING_TIMEOUT_MS,
  assertAnswerable,
  endedState,
  joinFor,
  partiesFor,
  partiesForChatRequest,
  roomFor,
} = await import('../src/lib/calls.js');

const service = (over: Record<string, unknown> = {}) => ({
  status: 'in_progress',
  clientId: 'client-1',
  clientName: 'QWER 134',
  driverId: 'driver-1',
  driverName: 'Ramón Peralta',
  ...over,
});

describe('partiesFor', () => {
  it('rings the chofer when the customer calls', () => {
    const parties = partiesFor(service(), 'client-1');

    expect(parties.callerRole).toBe('client');
    expect(parties.calleeId).toBe('driver-1');
    expect(parties.calleeRole).toBe('driver');
    expect(parties.calleeName).toBe('Ramón Peralta');
  });

  it('rings the customer when the chofer calls', () => {
    const parties = partiesFor(service(), 'driver-1');

    expect(parties.callerName).toBe('Ramón Peralta');
    expect(parties.calleeId).toBe('client-1');
    expect(parties.calleeRole).toBe('client');
  });

  it('refuses anyone who is not on the service', () => {
    expect(() => partiesFor(service(), 'driver-2')).toThrow(/No formas parte/);
  });

  it('refuses before a chofer has accepted, and after the tow is over', () => {
    // The same window the chat button uses.
    expect(() =>
      partiesFor(service({ status: 'pending_dispatch', driverId: undefined }), 'client-1'),
    ).toThrow(/en curso/);
    expect(() => partiesFor(service({ status: 'closed' }), 'client-1')).toThrow(/en curso/);
  });

  it('allows every state where the two are in contact', () => {
    for (const status of ['accepted', 'arrived', 'in_progress']) {
      expect(() => partiesFor(service({ status }), 'client-1')).not.toThrow();
    }
  });
});

describe('partiesForChatRequest', () => {
  const now = 1_000_000;
  const chat = (over: Record<string, unknown> = {}) => ({
    status: 'accepted',
    clientId: 'client-1',
    clientName: 'Manuel Guzmán',
    driverId: 'driver-1',
    driverName: 'Ramón Peralta',
    expiresAtMs: now - 60_000,
    closesAtMs: now + 60_000,
    ...over,
  });

  it('rings the other side of an open conversation, either way round', () => {
    const fromClient = partiesForChatRequest(chat(), 'client-1', now);
    expect(fromClient.calleeId).toBe('driver-1');
    expect(fromClient.calleeRole).toBe('driver');
    expect(fromClient.calleeName).toBe('Ramón Peralta');

    const fromDriver = partiesForChatRequest(chat(), 'driver-1', now);
    expect(fromDriver.calleeId).toBe('client-1');
    expect(fromDriver.calleeRole).toBe('client');
  });

  it('refuses anyone who is not in the conversation', () => {
    expect(() => partiesForChatRequest(chat(), 'driver-2', now)).toThrow(/No formas parte/);
  });

  it('refuses before the chofer accepts, and once it is closed or lapsed', () => {
    // A stranger's phone must not ring for a request the chofer did not answer.
    expect(() =>
      partiesForChatRequest(
        chat({ status: 'pending', expiresAtMs: now + 60_000, closesAtMs: null }),
        'client-1',
        now,
      ),
    ).toThrow(/abierta/);
    for (const status of ['declined', 'cancelled', 'closed']) {
      expect(() => partiesForChatRequest(chat({ status }), 'client-1', now)).toThrow(/abierta/);
    }
    expect(() =>
      partiesForChatRequest(chat({ closesAtMs: now - 1 }), 'client-1', now),
    ).toThrow(/abierta/);
  });
});

describe('endedState', () => {
  const ringing = { state: CallState.ringing, callerId: 'client-1', calleeId: 'driver-1' };
  const accepted = { ...ringing, state: CallState.accepted };

  it('a callee hanging up on a ringing call has declined it', () => {
    expect(endedState(ringing, 'driver-1', 'declined')).toBe(CallState.declined);
    // Whatever the app said — pressing the red button on a ringing call is no.
    expect(endedState(ringing, 'driver-1', 'hangup')).toBe(CallState.declined);
  });

  it('a caller giving up on a ringing call has cancelled it, or it rang out', () => {
    expect(endedState(ringing, 'client-1', 'hangup')).toBe(CallState.cancelled);
    expect(endedState(ringing, 'client-1', 'missed')).toBe(CallState.missed);
  });

  it('either side ending a call in progress ends it', () => {
    expect(endedState(accepted, 'client-1', 'hangup')).toBe(CallState.ended);
    expect(endedState(accepted, 'driver-1', 'hangup')).toBe(CallState.ended);
  });

  it('ending a call that already ended changes nothing', () => {
    // Both phones hang up at once; the ring timeout fires after an answer.
    for (const state of [CallState.ended, CallState.declined, CallState.missed, CallState.cancelled]) {
      expect(endedState({ ...ringing, state }, 'client-1', 'missed')).toBeNull();
    }
  });

  it('refuses a stranger', () => {
    expect(() => endedState(accepted, 'someone', 'hangup')).toThrow(/No formas parte/);
  });
});

describe('assertAnswerable', () => {
  const now = 1_000_000;

  it('lets the callee answer while it rings', () => {
    expect(() =>
      assertAnswerable({ state: CallState.ringing, calleeId: 'driver-1', createdAtMs: now - 5000 }, 'driver-1', now),
    ).not.toThrow();
  });

  it('refuses the caller answering their own call', () => {
    expect(() =>
      assertAnswerable({ state: CallState.ringing, calleeId: 'driver-1', createdAtMs: now }, 'client-1', now),
    ).toThrow(/no es para ti/);
  });

  it('refuses a call that stopped ringing, or rang too long ago', () => {
    expect(() =>
      assertAnswerable({ state: CallState.cancelled, calleeId: 'driver-1', createdAtMs: now }, 'driver-1', now),
    ).toThrow(/ya terminó/);
    expect(() =>
      assertAnswerable(
        { state: CallState.ringing, calleeId: 'driver-1', createdAtMs: now - RING_TIMEOUT_MS - 60_000 },
        'driver-1',
        now,
      ),
    ).toThrow(/ya terminó/);
  });
});

describe('joinFor', () => {
  beforeEach(() => {
    secret.key = 'APIkey123';
    secret.secret = 'a'.repeat(40);
    secret.url = 'wss://grua.livekit.cloud';
  });

  it('issues a token for exactly this call room and this person', async () => {
    const join = await joinFor('abc', 'driver-1', 'Ramón Peralta');

    expect(join.url).toBe('wss://grua.livekit.cloud');
    expect(join.room).toBe(roomFor('abc'));

    const payload = JSON.parse(
      Buffer.from(join.token.split('.')[1]!, 'base64url').toString('utf8'),
    ) as Record<string, any>;
    expect(payload['sub']).toBe('driver-1');
    expect(payload['iss']).toBe('APIkey123');
    expect(payload['video']['room']).toBe('call-abc');
    expect(payload['video']['roomJoin']).toBe(true);
    // Short-lived: a leaked token is good for one call, not forever.
    expect(payload['exp'] - payload['nbf']).toBeLessThanOrEqual(2 * 60 * 60 + 5);
  });

  it('refuses clearly when LiveKit is not configured', async () => {
    secret.secret = '';
    await expect(joinFor('abc', 'driver-1', 'x')).rejects.toThrow(/no están configuradas/);
  });

  it('survives secrets pasted with a stray newline', async () => {
    secret.key = 'APIkey123\r\n';
    const join = await joinFor('abc', 'driver-1', 'x');
    const payload = JSON.parse(
      Buffer.from(join.token.split('.')[1]!, 'base64url').toString('utf8'),
    ) as Record<string, unknown>;
    expect(payload['iss']).toBe('APIkey123');
  });
});
