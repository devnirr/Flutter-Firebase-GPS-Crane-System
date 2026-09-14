import { describe, expect, it, vi } from 'vitest';

/**
 * When a chofer's busy flag is a leftover.
 *
 * A chofer marked busy with a job that is over sees "Ocupado" on an empty
 * screen, is skipped by dispatch, and cannot go offline. Releasing one who is
 * really working would be worse: a second job on top of a tow in progress.
 */

vi.mock('../src/lib/firestore.js', () => ({}));
vi.mock('firebase-functions/v2', () => ({
  logger: { info: () => {}, warn: () => {}, error: () => {} },
}));

const { isFinishedHold } = await import('../src/lib/driverRelease.js');

describe('isFinishedHold', () => {
  it('keeps a chofer on a job in progress', () => {
    for (const status of ['accepted', 'arrived', 'in_progress', 'completed']) {
      expect(isFinishedHold('d1', { driverId: 'd1', status })).toBe(false);
    }
  });

  it('frees a chofer whose job was cancelled or closed', () => {
    for (const status of ['cancelled', 'closed', 'expired', 'failed']) {
      expect(isFinishedHold('d1', { driverId: 'd1', status })).toBe(true);
    }
  });

  it('frees a chofer whose job has gone to somebody else', () => {
    expect(isFinishedHold('d1', { driverId: 'd2', status: 'accepted' })).toBe(true);
    // Dropped back into the pool: `cancelByDriver` removes the chofer.
    expect(isFinishedHold('d1', { status: 'pending_dispatch' })).toBe(true);
  });

  it('frees a chofer whose job no longer exists', () => {
    expect(isFinishedHold('d1', undefined)).toBe(true);
  });
});
