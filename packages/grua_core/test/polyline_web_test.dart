import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/src/location/polyline.dart';

/// The polyline decoder, run where it actually broke.
///
/// **This file must also be run compiled to JavaScript:**
///
///     flutter test --platform chrome test/polyline_web_test.dart
///
/// On the Dart VM an `int` is 64-bit and signed. On the web it is a JavaScript
/// number, and Dart's bitwise operators there work on 32-bit **unsigned**
/// values — so `~x` of a positive number comes back as `4294967295 - x`
/// instead of a negative one. The decoder used `~` for the zigzag step, which
/// is exactly where every western longitude turns negative.
///
/// The result on every map in the product: a point at longitude 42879 instead
/// of -70.6, eleven thousand kilometres away, drawn as a red band across the
/// world. Every VM test passed throughout.
///
/// It imports the library directly rather than through `grua_core.dart` so the
/// browser build stays seconds rather than minutes.
void main() {
  test('a western-hemisphere route decodes to western longitudes', () {
    // Jarabacoa → Santiago, both at about -70.6.
    final points = decodePolyline('cxusBjfcnL{eNrpC_jZ~{BcyTfiB');

    expect(points, hasLength(4));
    for (final point in points) {
      expect(
        point.longitude,
        lessThan(0),
        reason: 'longitude wrapped to unsigned: $point',
      );
      expect(point.longitude, closeTo(-70.67, 0.1));
      expect(point.latitude, closeTo(19.28, 0.2));
    }
  });

  test('the zigzag step produces negatives, not their unsigned twin', () {
    // Google's own worked example, whose second and third points move south
    // and west — both negative deltas, both through the branch that broke.
    final points = decodePolyline('_p~iF~ps|U_ulLnnqC_mqNvxq`@');

    expect(points, hasLength(3));
    expect(points[0].longitude, closeTo(-120.2, 0.0001));
    expect(points[1].longitude, closeTo(-120.95, 0.0001));
    expect(points[2].longitude, closeTo(-126.453, 0.0001));
    // The wrapped value this used to produce, for the record.
    expect(points[0].longitude, isNot(closeTo(42829.47, 1)));
  });

  test('every point stays on the planet', () {
    final points = decodePolyline('cxusBjfcnL{eNrpC_jZ~{BcyTfiB');

    for (final point in points) {
      expect(point.latitude.abs(), lessThanOrEqualTo(90));
      expect(point.longitude.abs(), lessThanOrEqualTo(180));
    }
  });
}
