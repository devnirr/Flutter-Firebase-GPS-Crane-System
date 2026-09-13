import { beforeEach, describe, expect, it, vi } from 'vitest';

/**
 * Reads before writes, inside every transition.
 *
 * The bug this pins down: `applyTransition` staged the service's status update
 * and the event document *before* handing control to its `inTransaction`
 * callback. Two of those callbacks re-read documents — `acceptOffer` re-reads
 * the offer and the chofer, `assignDriver` re-reads the chofer — and Firestore
 * refuses a read after a write inside a transaction. It throws, the callable
 * answers `INTERNAL`, and a chofer pressing ACEPTAR was told "INTERNAL [500]"
 * every single time. The dispatcher's "Asignar manualmente" was dead the same
 * way.
 *
 * The emulator suite would have caught it, but it needs a JVM and is skipped by
 * `npm test`. This does not: the fake transaction below enforces the same rule
 * the Admin SDK does, with no database anywhere.
 */

/** A transaction that refuses a read once anything has been written, as Firestore does. */
class FakeTransaction {
  written = false;
  readonly reads: string[] = [];
  readonly writes: string[] = [];

  constructor(private readonly docs: Record<string, unknown>) {}

  async get(ref: { path: string }) {
    if (this.written) {
      // The Admin SDK's own words.
      throw new Error(
        'Firestore transactions require all reads to be executed before all writes.',
      );
    }
    this.reads.push(ref.path);
    const data = this.docs[ref.path];
    return { exists: data !== undefined, data: () => data };
  }

  update(ref: { path: string }, _patch: unknown) {
    this.written = true;
    this.writes.push(ref.path);
  }

  set(ref: { path: string }, _value: unknown) {
    this.written = true;
    this.writes.push(ref.path);
  }

  create(ref: { path: string }, _value: unknown) {
    this.written = true;
    this.writes.push(ref.path);
  }
}

const service = {
  status: 'offered',
  clientId: 'client-1',
  pickup: {},
};

let tx: FakeTransaction;

const ref = (path: string) => ({ path, doc: () => ref(`${path}/generated`) });

vi.mock('../src/lib/firestore.js', () => ({
  db: {
    runTransaction: async (body: (t: FakeTransaction) => Promise<unknown>) => {
      tx = new FakeTransaction({ 'services/svc-1': service });
      return body(tx);
    },
  },
  FieldValue: {
    serverTimestamp: () => 'ts',
    increment: (n: number) => n,
    delete: () => 'delete',
  },
  Timestamp: { now: () => 'now', fromDate: (d: Date) => d },
  Paths: {
    service: () => ref('services/svc-1'),
    events: () => ref('services/svc-1/events'),
    driver: (id: string) => ref(`drivers/${id}`),
    offer: (s: string, d: string) => ref(`services/${s}/offers/${d}`),
    user: (id: string) => ref(`users/${id}`),
  },
}));

vi.mock('firebase-functions/v2', () => ({
  logger: { info: () => {}, warn: () => {}, error: () => {} },
}));

describe('applyTransition', () => {
  beforeEach(() => vi.resetModules());

  it('lets a callback read before it has written anything', async () => {
    const { applyTransition } = await import('../src/lib/stateMachine.js');
    const { ServiceEventName } = await import('../src/lib/enums.js');

    let sawDriver: unknown;

    await applyTransition({
      serviceId: 'svc-1',
      event: ServiceEventName.acceptService,
      actorId: 'driver-a',
      actorRole: 'driver',
      // Exactly what `acceptOffer` does: re-read, decide, then write.
      inTransaction: async ({ transaction }) => {
        const snap = await (
          transaction as unknown as FakeTransaction
        ).get(ref('drivers/driver-a'));
        sawDriver = snap.exists;
        transaction.update(ref('drivers/driver-a') as never, { x: 1 } as never);
      },
    });

    expect(sawDriver).toBe(false);
    // The callback's read happened, and the service write came after it.
    expect(tx.reads).toEqual(['services/svc-1', 'drivers/driver-a']);
    expect(tx.writes[0]).toBe('drivers/driver-a');
    expect(tx.writes).toContain('services/svc-1');
  });

  it('writes the status last, so no callback can overrule the machine', async () => {
    const { applyTransition } = await import('../src/lib/stateMachine.js');
    const { ServiceEventName } = await import('../src/lib/enums.js');

    await applyTransition({
      serviceId: 'svc-1',
      event: ServiceEventName.acceptService,
      actorId: 'driver-a',
      actorRole: 'driver',
      inTransaction: ({ transaction }) => {
        transaction.update(ref('services/svc-1') as never, { driverId: 'a' } as never);
      },
    });

    // The transition's own update to the service is the last word on it.
    expect(tx.writes.lastIndexOf('services/svc-1')).toBeGreaterThan(
      tx.writes.indexOf('services/svc-1'),
    );
    expect(tx.writes.at(-1)).toBe('services/svc-1/events/generated');
  });
});
