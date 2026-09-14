import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../domain/value_objects.dart';

/// Decodes Google's encoded polyline format into points.
///
/// The format packs each coordinate delta into 5-bit chunks, offset by 63 so
/// every chunk is a printable character.
List<LatLng> decodePolyline(String encoded) {
  final points = <LatLng>[];
  var index = 0;
  var lat = 0;
  var lng = 0;

  int next() {
    var result = 0;
    var shift = 0;
    int chunk;
    do {
      chunk = encoded.codeUnitAt(index++) - 63;
      result |= (chunk & 0x1f) << shift;
      shift += 5;
    } while (chunk >= 0x20 && index < encoded.length);
    // `-(x) - 1` rather than `~x`, which is the same thing on the VM and not
    // on the web: there Dart's bitwise operators work on 32-bit *unsigned*
    // values, so `~` of a positive number comes back as 4294967295 - x
    // instead of a negative. Every longitude in this hemisphere is negative,
    // so on the web every route decoded to a point 11,000 km away and the
    // maps drew a band across the world. The VM tests could not see it.
    final magnitude = result >> 1;
    return (result & 1) != 0 ? -magnitude - 1 : magnitude;
  }

  while (index < encoded.length) {
    lat += next();
    if (index >= encoded.length) break;
    lng += next();
    points.add(LatLng(lat / 1e5, lng / 1e5));
  }
  return points;
}

/// [path], if it plausibly joins [from] to [to] — otherwise nothing.
///
/// A decoded path is only ever as good as the string it came from, and a
/// single wrong point draws a line off the edge of the world and back: on the
/// dispatcher's map that looked like a red band straight across the country,
/// through a pickup whose tow was twenty kilometres long.
///
/// The rule is deliberately loose. A road route wanders — around a reservoir,
/// down to a bridge — so anything within three times the direct distance, or
/// 25 km, whichever is larger, is accepted. Nothing legitimate is thrown away
/// by that; a point in the Atlantic is.
List<LatLng> sanePath(
  List<LatLng> path, {
  required LatLng from,
  required LatLng to,
}) {
  if (path.length < 2) return const [];

  final middle = from.lerp(to, 0.5);
  final allowed = math.max(from.distanceTo(to) * 3, 25000);

  for (final point in path) {
    if (!point.isValid || point.distanceTo(middle) > allowed) {
      if (kDebugMode) {
        debugPrint(
          '[grua] path rejected: $point is ${(point.distanceTo(middle) / 1000)
              .toStringAsFixed(0)} km from a trip of '
          '${(from.distanceTo(to) / 1000).toStringAsFixed(1)} km',
        );
      }
      return const [];
    }
  }
  return path;
}
