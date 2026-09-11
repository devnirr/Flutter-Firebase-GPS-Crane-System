import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';

/// The driver app's geohash must be byte-for-byte what `geofire-common`
/// computes on the server, or dispatch's range queries miss the truck. The
/// expected values below were produced by `geofire-common` itself.
void main() {
  const cases = <(double, double, String)>[
    (57.64911, 10.40744, 'u4pruydqqv'),
    (18.4861, -69.9312, 'd7q30tm9kf'), // Santo Domingo
    (18.452, -69.609, 'd7q8bp068w'), // Boca Chica
    (43.6532, -79.3832, 'dpz83dffm6'), // Toronto
    (-33.8688, 151.2093, 'r3gx2f77bn'),
    (0, 0, '7zzzzzzzzz'),
  ];

  for (final (lat, lng, expected) in cases) {
    test('($lat, $lng) matches geofire-common', () {
      expect(encodeGeohash(LatLng(lat, lng)), expected);
    });
  }

  test('a shorter precision is a prefix of the longer one', () {
    const point = LatLng(18.4861, -69.9312);
    expect(encodeGeohash(point, precision: 5), 'd7q30');
  });
}
