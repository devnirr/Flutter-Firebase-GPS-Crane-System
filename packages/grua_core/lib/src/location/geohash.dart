import '../domain/value_objects.dart';

const _base32 = '0123456789bcdefghjkmnpqrstuvwxyz';

/// The standard geohash of [point], as `geofire-common` computes it.
///
/// Dispatch and the "grúas cerca de ti" search find trucks by range queries
/// on this string at `/live/{driverId}/geohash`, so a position published
/// without one is a truck no search can ever find. Ten characters (~1 m) is
/// geofire's default and what its query bounds assume.
String encodeGeohash(LatLng point, {int precision = 10}) {
  var latMin = -90.0;
  var latMax = 90.0;
  var lngMin = -180.0;
  var lngMax = 180.0;
  final out = StringBuffer();
  var bits = 0;
  var bitCount = 0;
  var even = true; // Longitude first.

  // Strictly greater, as geofire-common has it: a value exactly on a split
  // goes to the lower half. Plain `>=` agrees everywhere except on those
  // lines, which is exactly where a mismatch would be hardest to find.
  while (out.length < precision) {
    if (even) {
      final mid = (lngMin + lngMax) / 2;
      if (point.longitude > mid) {
        bits = (bits << 1) | 1;
        lngMin = mid;
      } else {
        bits <<= 1;
        lngMax = mid;
      }
    } else {
      final mid = (latMin + latMax) / 2;
      if (point.latitude > mid) {
        bits = (bits << 1) | 1;
        latMin = mid;
      } else {
        bits <<= 1;
        latMax = mid;
      }
    }
    even = !even;

    if (++bitCount == 5) {
      out.write(_base32[bits]);
      bits = 0;
      bitCount = 0;
    }
  }
  return out.toString();
}
