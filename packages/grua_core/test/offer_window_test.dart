import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';

/// How long a chofer gets to answer an offer.
///
/// Twenty-five seconds was not enough to read the card — what they take home,
/// how far the customer is, what is wrong with the vehicle, where it goes —
/// and decide. A chofer who tapped ACEPTAR was often refused by a clock that
/// had already run out, and the refusal looked like a broken button.
void main() {
  test('the default offer window is a minute', () {
    expect(const DispatchConfig().offerTtlSeconds, 60);
    expect(const DispatchConfig().offerTtl, const Duration(minutes: 1));
  });

  test('the countdown comes from the server stamp, not from counting ticks', () {
    // Clock drift on a cheap Android is exactly why: the card shows what is
    // left against `expiresAt`, so a phone running fast cannot hand somebody a
    // dead offer that still looks alive.
    final now = DateTime.utc(2026, 9, 12, 14, 30);
    final offer = Offer(
      serviceId: 'svc-1',
      driverId: 'driver-1',
      pickupGeo: const LatLng(19.1221, -70.6367),
      expiresAt: now.add(const Duration(seconds: 60)),
    );

    expect(offer.secondsRemaining(now), 60);
    expect(offer.progress(now), closeTo(1, 0.001));

    final halfway = now.add(const Duration(seconds: 30));
    expect(offer.secondsRemaining(halfway), 30);

    final after = now.add(const Duration(seconds: 61));
    expect(offer.secondsRemaining(after), 0);
  });
}
