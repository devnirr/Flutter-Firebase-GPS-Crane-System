import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';

/// What a Cloud Functions callable can actually carry.
///
/// The bug these pin down: every model here serialises for Firestore, so
/// `ServiceLocation.toJson()` puts a `GeoPoint` in the payload and a driver
/// puts a `Timestamp` in one. Neither survives the trip to a callable — the
/// platform-channel codec has no entry for them and `jsify` refuses them on the
/// web — so `quoteService` threw before it left the phone and the customer was
/// told "Algo salió mal" every single time they pressed VER PRECIO.
void main() {
  const pickup = ServiceLocation(
    geo: LatLng(19.1221, -70.6367),
    address: '4987+78J, Maria Auxiliadora, Jarabacoa',
    reference: 'Frente al colmado',
  );

  test('a location leaves as the pair the server asks for, not a GeoPoint', () {
    expect(pickup.toJson()['geo'], isA<GeoPoint>(), reason: 'the bug');

    final wire = callablePayload({'pickup': pickup.toJson()});
    final geo = (wire['pickup'] as Map<String, dynamic>)['geo'];

    expect(geo, isA<Map<String, dynamic>>());
    expect((geo! as Map)['latitude'], closeTo(19.1221, 0.000001));
    expect((geo as Map)['longitude'], closeTo(-70.6367, 0.000001));
  });

  test('the whole payload is JSON — nothing a codec can choke on', () {
    final payload = callablePayload({
      'pickup': pickup.toJson(),
      'dropoff': pickup.toJson(),
      'vehicle': const ServiceVehicle(make: 'Toyota', model: 'Corolla').toJson(),
      'truckTypeOverride': TruckType.gancho.wire,
    });

    // The real invariant: encodable. A `GeoPoint` anywhere in here throws.
    expect(() => jsonEncode(payload), returnsNormally);
  });

  test('an instant leaves as ISO-8601 in UTC, which is what zod validates', () {
    final when = DateTime.utc(2026, 9, 12, 14, 30);

    final wire = callablePayload({
      'licenseExpiry': Timestamp.fromDate(when),
      'alsoADate': when,
    });

    expect(wire['licenseExpiry'], '2026-09-12T14:30:00.000Z');
    expect(wire['alsoADate'], '2026-09-12T14:30:00.000Z');
  });

  test('nested lists and maps are converted all the way down', () {
    final wire = callablePayload({
      'zones': [
        {'polygon': [const GeoPoint(18.4, -69.9), const GeoPoint(18.5, -69.8)]},
      ],
    });

    expect(() => jsonEncode(wire), returnsNormally);
    final zone = (wire['zones']! as List).first as Map<String, dynamic>;
    expect((zone['polygon']! as List).first, {
      'latitude': 18.4,
      'longitude': -69.9,
    });
  });

  test('a reply with untyped nested maps parses, as it does off the web', () {
    // What the Android and iOS channels hand back: `Map<Object?, Object?>` at
    // every level. `Quote.fromJson` casts nested objects to
    // `Map<String, dynamic>`, so one surcharge used to throw.
    final reply = <Object?, Object?>{
      'quote': <Object?, Object?>{
        'totalCents': 250000,
        'surcharges': <Object?>[
          <Object?, Object?>{'code': 'night', 'label': 'Nocturno', 'cents': 50000},
        ],
      },
    };

    final plain = plainJson(reply)! as Map<String, dynamic>;
    final quote = Quote.fromJson(plain['quote'] as Map<String, dynamic>);

    expect(quote.totalCents, 250000);
    expect(quote.surcharges.single.label, 'Nocturno');
  });
}
