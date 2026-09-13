import { describe, expect, it } from 'vitest';

import { withPosition } from '../src/callables/lifecycle.js';

/**
 * The shape the apps put on the wire, checked against the schema that receives
 * it.
 *
 * The bug these pin down: `markArrived` and `completeService` sent a flat
 * `{lat, lng}` pair while the callables required a nested
 * `{position: {latitude, longitude}}`. Zod read that as no position at all and
 * refused the call, so a chofer who had driven to the customer pressed LLEGUÉ
 * and got "Datos inválidos. [400]" — and the job could never move past
 * `accepted`. Both halves of the wire were valid on their own; only putting
 * them side by side shows it.
 *
 * Keep this in step with `FirebaseFunctionsGateway._point` in
 * packages/grua_core/lib/src/data/firebase/functions_gateway.dart.
 */
describe('the position payload the chofer app sends', () => {
  const sent = {
    serviceId: 'svc-1',
    position: { latitude: 19.1221, longitude: -70.6367 },
  };

  it('is what markArrived and completeService accept', () => {
    const parsed = withPosition.safeParse(sent);

    expect(parsed.success).toBe(true);
    if (parsed.success) {
      expect(parsed.data.position.latitude).toBeCloseTo(19.1221);
      expect(parsed.data.position.longitude).toBeCloseTo(-70.6367);
    }
  });

  it('rejects the flat pair the apps used to send', () => {
    // Exactly the old payload, kept as the thing that must never come back.
    const old = { serviceId: 'svc-1', lat: 19.1221, lng: -70.6367 };

    expect(withPosition.safeParse(old).success).toBe(false);
  });

  it('rejects a position off the planet', () => {
    expect(
      withPosition.safeParse({
        serviceId: 'svc-1',
        position: { latitude: 200, longitude: 0 },
      }).success,
    ).toBe(false);
  });
});
