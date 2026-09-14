import { beforeEach, describe, expect, it, vi } from 'vitest';

/**
 * Taking a chofer offline when their app closes.
 *
 * The app used to have a switch, and a chofer who closed it without flipping
 * the switch back stayed "En línea" on the office map with nobody holding the
 * phone. The app now goes online by itself; this is the server half, driven by
 * the presence connection dropping — the only goodbye a force-quit phone ever
 * says.
 */

const db = {
  presence: null as { connected?: boolean } | null,
  driver: undefined as Record<string, unknown> | undefined,
  driverUpdates: [] as Record<string, unknown>[],
  liveUpdates: [] as Record<string, unknown>[],
};

vi.mock('../src/lib/firestore.js', () => ({
  FieldValue: { serverTimestamp: () => 'ts' },
  Paths: {
    presence: () => ({ get: async () => ({ val: () => db.presence }) }),
    driver: () => ({
      get: async () => ({ data: () => db.driver }),
      update: async (patch: Record<string, unknown>) => {
        db.driverUpdates.push(patch);
      },
    }),
    live: () => ({
      update: async (patch: Record<string, unknown>) => {
        db.liveUpdates.push(patch);
      },
    }),
  },
}));
vi.mock('firebase-functions/v2', () => ({
  logger: { info: () => {}, warn: () => {}, error: () => {} },
}));

const { followPresence } = await import('../src/lib/presence.js');

describe('followPresence', () => {
  beforeEach(() => {
    db.presence = { connected: false };
    db.driver = { isOnline: true };
    db.driverUpdates = [];
    db.liveUpdates = [];
  });

  it('takes an idle chofer offline, off the live map as well', async () => {
    expect(await followPresence('driver-1')).toBe('went-offline');

    expect(db.driverUpdates).toEqual([{ isOnline: false, updatedAt: 'ts' }]);
    // Out of dispatch at once, not when the stale sweep gets to it.
    expect(db.liveUpdates).toHaveLength(1);
    expect(db.liveUpdates[0]!['isOnline']).toBe(false);
  });

  it('leaves a chofer alone whose app came straight back', async () => {
    // A dropped signal and the reconnect arrive as two writes, and the trigger
    // can run after the second. Acting on the first would take a chofer offline
    // with the app open in their hand.
    db.presence = { connected: true };

    expect(await followPresence('driver-1')).toBe('reconnected');
    expect(db.driverUpdates).toEqual([]);
    expect(db.liveUpdates).toEqual([]);
  });

  it('leaves a chofer online mid-tow', async () => {
    // The customer is watching that truck.
    db.driver = { isOnline: true, currentServiceId: 'svc-1' };

    expect(await followPresence('driver-1')).toBe('mid-service');
    expect(db.driverUpdates).toEqual([]);
  });

  it('does nothing for a chofer who was already offline', async () => {
    db.driver = { isOnline: false };

    expect(await followPresence('driver-1')).toBe('already-offline');
    expect(db.driverUpdates).toEqual([]);
  });

  it('does nothing for an account that is not a chofer', async () => {
    db.driver = undefined;

    expect(await followPresence('someone')).toBe('already-offline');
    expect(db.driverUpdates).toEqual([]);
  });

  it('treats a presence node that is gone entirely as closed', async () => {
    db.presence = null;

    expect(await followPresence('driver-1')).toBe('went-offline');
  });
});
