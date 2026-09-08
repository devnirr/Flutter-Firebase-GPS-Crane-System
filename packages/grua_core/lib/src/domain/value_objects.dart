import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// A coordinate pair, independent of Firestore and of the maps plugin.
///
/// Both `GeoPoint` and `google_maps_flutter`'s `LatLng` exist, and neither
/// belongs in the domain layer: one drags Firebase into pure-Dart tests, the
/// other drags in a platform plugin that will not run on a test VM.
@immutable
class LatLng {
  const LatLng(this.latitude, this.longitude);

  factory LatLng.fromJson(Map<String, dynamic> json) => LatLng(
        (json['latitude'] as num? ?? 0).toDouble(),
        (json['longitude'] as num? ?? 0).toDouble(),
      );

  final double latitude;
  final double longitude;

  /// Great-circle distance in metres.
  ///
  /// The same formula runs in `functions/src/lib/geo.ts`; if you change one,
  /// change both, because dispatch compares the two.
  double distanceTo(LatLng other) {
    const earthRadiusM = 6371000.0;
    final dLat = _toRadians(other.latitude - latitude);
    final dLng = _toRadians(other.longitude - longitude);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRadians(latitude)) *
            math.cos(_toRadians(other.latitude)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return earthRadiusM * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  double distanceKmTo(LatLng other) => distanceTo(other) / 1000;

  /// Initial bearing in degrees (0 = north), used to rotate the truck marker.
  double bearingTo(LatLng other) {
    final dLng = _toRadians(other.longitude - longitude);
    final lat1 = _toRadians(latitude);
    final lat2 = _toRadians(other.latitude);
    final y = math.sin(dLng) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLng);
    return (_toDegrees(math.atan2(y, x)) + 360) % 360;
  }

  /// Linear interpolation, for gliding a marker between two GPS fixes.
  LatLng lerp(LatLng other, double t) => LatLng(
        latitude + (other.latitude - latitude) * t,
        longitude + (other.longitude - longitude) * t,
      );

  bool get isValid =>
      latitude >= -90 &&
      latitude <= 90 &&
      longitude >= -180 &&
      longitude <= 180 &&
      !(latitude == 0 && longitude == 0);

  static double _toRadians(double degrees) => degrees * math.pi / 180;

  static double _toDegrees(double radians) => radians * 180 / math.pi;

  Map<String, double> toJson() => {'latitude': latitude, 'longitude': longitude};

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LatLng &&
          other.latitude == latitude &&
          other.longitude == longitude;

  @override
  int get hashCode => Object.hash(latitude, longitude);

  @override
  String toString() =>
      'LatLng(${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)})';
}

/// Well-known Dominican coordinates, used for map defaults and test fixtures.
abstract final class DoLocations {
  static const LatLng santoDomingo = LatLng(18.4861, -69.9312);
  static const LatLng santiago = LatLng(19.4517, -70.6970);
  static const LatLng puntaCana = LatLng(18.5820, -68.4055);
  static const LatLng laRomana = LatLng(18.4273, -68.9728);
  static const LatLng puertoPlata = LatLng(19.7808, -70.6871);
  static const LatLng higuey = LatLng(18.6157, -68.7075);
  static const LatLng sanPedro = LatLng(18.4539, -69.3086);

  /// Default camera when we have no fix yet.
  static const LatLng defaultCenter = santoDomingo;
  static const double defaultZoom = 14;

  /// Rough national bounding box, used to sanity-check a coordinate before it
  /// reaches the server.
  static bool isPlausiblyInDominicanRepublic(LatLng p) =>
      p.latitude >= 17.4 &&
      p.latitude <= 20.1 &&
      p.longitude >= -72.1 &&
      p.longitude <= -68.2;
}
