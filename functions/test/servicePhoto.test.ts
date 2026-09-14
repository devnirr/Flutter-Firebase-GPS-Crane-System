import { describe, expect, it } from 'vitest';

import { needsServiceDriverPhoto } from '../src/lib/servicePhoto.js';

/**
 * Which services get their chofer's photo filled in.
 *
 * Assigning by hand used to leave the photo off the service, so the customer's
 * tracking card and chat showed the chofer as a single letter.
 */
describe('needsServiceDriverPhoto', () => {
  it('fills in an active service with a chofer and no photo', () => {
    for (const status of ['accepted', 'arrived', 'in_progress']) {
      expect(needsServiceDriverPhoto({ status, driverId: 'driver-1' })).toBe(true);
      expect(needsServiceDriverPhoto({ status, driverId: 'driver-1', driverPhotoUrl: '' })).toBe(true);
    }
  });

  it('leaves a service that already has the photo alone, so it cannot loop', () => {
    expect(
      needsServiceDriverPhoto({
        status: 'arrived',
        driverId: 'driver-1',
        driverPhotoUrl: 'https://example.com/p.jpg',
      }),
    ).toBe(false);
  });

  it('ignores a service nobody has taken yet', () => {
    expect(needsServiceDriverPhoto({ status: 'pending_dispatch' })).toBe(false);
    expect(needsServiceDriverPhoto({ status: 'pending_dispatch', driverId: '' })).toBe(false);
  });

  it('does not rewrite finished tows', () => {
    expect(needsServiceDriverPhoto({ status: 'closed', driverId: 'driver-1' })).toBe(false);
    expect(needsServiceDriverPhoto({ status: 'cancelled', driverId: 'driver-1' })).toBe(false);
  });
});
