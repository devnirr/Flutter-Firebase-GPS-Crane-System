import { beforeAll, beforeEach, describe, expect, it } from 'vitest';

/**
 * The guarantees that only Firestore can prove.
 *
 * Everything here is about concurrency, which cannot be tested with fakes: the
 * whole question is what the database does when two transactions touch the same
 * document at once. Run with:
 *
 *     npm run test:emulator
 *
 * That needs Java, because the Firestore emulator is a JVM process. Without it
 * the suite skips rather than failing, so `npm test` stays green on a machine
 * that only runs the pure-logic tests.
 */

const EMULATOR_HOST = process.env['FIRESTORE_EMULATOR_HOST'];
const describeEmulator = EMULATOR_HOST ? describe : describe.skip;

// Imported lazily: these modules touch the Admin SDK at import time, and
// pulling them in without an emulator would fail collection for the whole file.
type Deps = {
  db: FirebaseFirestore.Firestore;
  Paths: typeof import('../src/lib/firestore.js')['Paths'];
  acceptOffer: typeof import('../src/dispatch/offers.js')['acceptOffer'];
  expireOffer: typeof import('../src/dispatch/offers.js')['expireOffer'];
  applyTransition: typeof import('../src/lib/stateMachine.js')['applyTransition'];
  ServiceStatus: typeof import('../src/lib/enums.js')['ServiceStatus'];
  OfferState: typeof import('../src/lib/enums.js')['OfferState'];
  ServiceEventName: typeof import('../src/lib/enums.js')['ServiceEventName'];
};

let deps: Deps;

describeEmulator('dispatch concurrency', () => {
  beforeAll(async () => {
    process.env['GCLOUD_PROJECT'] ??= 'grua-rd-test';
    process.env['QUOTE_SIGNING_SECRET'] ??= 'test-secret';

    const firestore = await import('../src/lib/firestore.js');
    const offers = await import('../src/dispatch/offers.js');
    const machine = await import('../src/lib/stateMachine.js');
    const enums = await import('../src/lib/enums.js');

    deps = {
      db: firestore.db,
      Paths: firestore.Paths,
      acceptOffer: offers.acceptOffer,
      expireOffer: offers.expireOffer,
      applyTransition: machine.applyTransition,
      ServiceStatus: enums.ServiceStatus,
      OfferState: enums.OfferState,
      ServiceEventName: enums.ServiceEventName,
    };
  });

  /** Wipes the collections a test touches, so ordering cannot matter. */
  async function reset(): Promise<void> {
    for (const collection of ['services', 'drivers', 'users', 'earnings']) {
      const snap = await deps.db.collection(collection).get();
      await Promise.all(snap.docs.map((doc) => doc.ref.delete()));
    }
  }

  async function seedOfferedService(driverIds: string[]): Promise<string> {
    const serviceRef = deps.Paths.services().doc();

    await serviceRef.set({
      code: 'GR-TEST-0001',
      status: deps.ServiceStatus.offered,
      clientId: 'client-1',
      truckTypeRequired: 'gancho',
      pickup: { geo: { latitude: 18.4861, longitude: -69.9312 } },
      quote: { totalCents: 250000 },
      payment: { method: 'cash', status: 'none' },
      dispatch: { round: 0, radiusKm: 5, offeredTo: driverIds, rejectedBy: [] },
      timeline: {},
      createdAt: new Date(),
    });

    // Every candidate holds a live offer, which is the situation the guard has
    // to resolve down to exactly one winner.
    await Promise.all(
      driverIds.map(async (driverId) => {
        await deps.Paths.driver(driverId).set({
          name: `Chofer ${driverId}`,
          phone: '+18095550000',
          status: 'active',
          rating: 4.8,
          assignedTruckId: `truck-${driverId}`,
          assignedTruckPlate: 'A123456',
          truckType: 'gancho',
          cashOwedCents: 0,
        });

        await deps.Paths.offer(serviceRef.id, driverId).set({
          state: deps.OfferState.sent,
          round: 0,
          driverId,
          sentAt: new Date(),
          expiresAt: new Date(Date.now() + 25000),
          distanceMeters: 1200,
        });
      }),
    );

    return serviceRef.id;
  }

  beforeEach(reset);

  it('lets exactly one of two simultaneous accepts win', async () => {
    const serviceId = await seedOfferedService(['driver-a', 'driver-b']);

    const results = await Promise.allSettled([
      deps.acceptOffer({ serviceId, driverId: 'driver-a', driver: { name: 'A' } }),
      deps.acceptOffer({ serviceId, driverId: 'driver-b', driver: { name: 'B' } }),
    ]);

    const fulfilled = results.filter((r) => r.status === 'fulfilled');
    const rejected = results.filter((r) => r.status === 'rejected');

    expect(fulfilled).toHaveLength(1);
    expect(rejected).toHaveLength(1);

    // The loser must be told somebody took it, not that it expired — different
    // news, different screen.
    const failure = (rejected[0] as PromiseRejectedResult).reason;
    expect(String(failure.details?.code ?? failure.message)).toContain('ALREADY_TAKEN');

    const service = (await deps.Paths.service(serviceId).get()).data()!;
    expect(service['status']).toBe(deps.ServiceStatus.accepted);
    expect(['driver-a', 'driver-b']).toContain(service['driverId']);

    // Exactly one chofer is committed to the job.
    const [a, b] = await Promise.all([
      deps.Paths.driver('driver-a').get(),
      deps.Paths.driver('driver-b').get(),
    ]);
    const busy = [a.data()?.['currentServiceId'], b.data()?.['currentServiceId']]
      .filter(Boolean);
    expect(busy).toEqual([serviceId]);
  });

  it('survives the race repeatedly', async () => {
    // Once is luck. This is the test that would have caught a missing
    // transaction, so it runs enough times to be evidence.
    for (let attempt = 0; attempt < 25; attempt++) {
      await reset();
      const serviceId = await seedOfferedService(['driver-a', 'driver-b']);

      const results = await Promise.allSettled([
        deps.acceptOffer({ serviceId, driverId: 'driver-a', driver: {} }),
        deps.acceptOffer({ serviceId, driverId: 'driver-b', driver: {} }),
      ]);

      expect(
        results.filter((r) => r.status === 'fulfilled'),
        `attempt ${attempt}`,
      ).toHaveLength(1);
    }
  });

  it('refuses an accept after the offer has expired', async () => {
    const serviceId = await seedOfferedService(['driver-a']);
    await deps.Paths.offer(serviceId, 'driver-a').update({
      expiresAt: new Date(Date.now() - 1000),
    });

    await expect(
      deps.acceptOffer({ serviceId, driverId: 'driver-a', driver: {} }),
    ).rejects.toThrow(/expir/i);

    const service = (await deps.Paths.service(serviceId).get()).data()!;
    expect(service['status']).toBe(deps.ServiceStatus.offered);
  });

  it('refuses an accept from a chofer already on another job', async () => {
    const serviceId = await seedOfferedService(['driver-a']);
    await deps.Paths.driver('driver-a').update({ currentServiceId: 'other-service' });

    await expect(
      deps.acceptOffer({ serviceId, driverId: 'driver-a', driver: {} }),
    ).rejects.toThrow(/servicio asignado/i);
  });

  it('returns the service to the pool when an offer expires', async () => {
    const serviceId = await seedOfferedService(['driver-a']);

    await deps.expireOffer({ serviceId, driverId: 'driver-a' });

    const service = (await deps.Paths.service(serviceId).get()).data()!;
    // Back to pending so the cascade can try somebody else, with this chofer
    // excluded so they are not asked twice.
    expect(service['status']).toBe(deps.ServiceStatus.pendingDispatch);
    expect(service['dispatch']['rejectedBy']).toContain('driver-a');

    const offer = (await deps.Paths.offer(serviceId, 'driver-a').get()).data()!;
    expect(offer['state']).toBe(deps.OfferState.expired);
  });

  it('is idempotent when an offer expires twice', async () => {
    const serviceId = await seedOfferedService(['driver-a']);

    await deps.expireOffer({ serviceId, driverId: 'driver-a' });
    const afterFirst = (await deps.Paths.service(serviceId).get()).data()!;

    // The Cloud Task and the sweeper can both fire for the same offer.
    await deps.expireOffer({ serviceId, driverId: 'driver-a' });
    const afterSecond = (await deps.Paths.service(serviceId).get()).data()!;

    expect(afterSecond['dispatch']['round']).toBe(afterFirst['dispatch']['round']);
  });

  it('does not expire an offer that was already accepted', async () => {
    const serviceId = await seedOfferedService(['driver-a']);
    await deps.acceptOffer({ serviceId, driverId: 'driver-a', driver: {} });

    // A late task firing must not undo a completed acceptance.
    await deps.expireOffer({ serviceId, driverId: 'driver-a' });

    const service = (await deps.Paths.service(serviceId).get()).data()!;
    expect(service['status']).toBe(deps.ServiceStatus.accepted);
    expect(service['driverId']).toBe('driver-a');
  });

  it('refuses a transition from the wrong state', async () => {
    const serviceId = await seedOfferedService(['driver-a']);

    // Still `offered`; nobody has arrived anywhere.
    await expect(
      deps.applyTransition({
        serviceId,
        event: deps.ServiceEventName.markArrived,
        actorId: 'driver-a',
        actorRole: 'driver',
      }),
    ).rejects.toThrow();
  });

  it('appends an event for every accepted transition', async () => {
    const serviceId = await seedOfferedService(['driver-a']);
    await deps.acceptOffer({ serviceId, driverId: 'driver-a', driver: {} });

    const events = await deps.Paths.events(serviceId).get();
    expect(events.size).toBeGreaterThanOrEqual(1);
    expect(events.docs.map((d) => d.data()['event'])).toContain('acceptService');
  });
});
