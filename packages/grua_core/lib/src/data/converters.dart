import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:json_annotation/json_annotation.dart';

import '../domain/value_objects.dart';

/// Firestore `Timestamp` <-> Dart `DateTime` (always UTC in the model layer).
///
/// Everything stored is UTC; the only place local time appears is at the
/// formatting boundary, in `America/Santo_Domingo`. Mixing the two is how a
/// night surcharge gets applied at 6 p.m.
class TimestampConverter implements JsonConverter<DateTime, Object?> {
  const TimestampConverter();

  @override
  DateTime fromJson(Object? json) => switch (json) {
        final Timestamp t => t.toDate().toUtc(),
        // Server timestamps read back as null on the write's local echo.
        null => DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        final int ms => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true),
        final String s => DateTime.parse(s).toUtc(),
        _ => DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      };

  @override
  Object toJson(DateTime object) => Timestamp.fromDate(object);
}

/// Nullable variant, for timeline stamps that have not happened yet.
class NullableTimestampConverter implements JsonConverter<DateTime?, Object?> {
  const NullableTimestampConverter();

  @override
  DateTime? fromJson(Object? json) => switch (json) {
        final Timestamp t => t.toDate().toUtc(),
        final int ms => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true),
        final String s => DateTime.tryParse(s)?.toUtc(),
        _ => null,
      };

  @override
  Object? toJson(DateTime? object) =>
      object == null ? null : Timestamp.fromDate(object);
}

/// Firestore `GeoPoint` <-> the transport-agnostic [LatLng] value object.
///
/// The model layer never exposes a Firestore type, so `grua_core` models stay
/// usable in a pure-Dart test with no Firebase bound.
class GeoPointConverter implements JsonConverter<LatLng, Object?> {
  const GeoPointConverter();

  @override
  LatLng fromJson(Object? json) => switch (json) {
        final GeoPoint g => LatLng(g.latitude, g.longitude),
        final Map<String, dynamic> m => LatLng(
            (m['latitude'] as num? ?? m['lat'] as num? ?? 0).toDouble(),
            (m['longitude'] as num? ?? m['lng'] as num? ?? 0).toDouble(),
          ),
        _ => const LatLng(0, 0),
      };

  @override
  Object toJson(LatLng object) => GeoPoint(object.latitude, object.longitude);
}

class NullableGeoPointConverter implements JsonConverter<LatLng?, Object?> {
  const NullableGeoPointConverter();

  @override
  LatLng? fromJson(Object? json) => switch (json) {
        final GeoPoint g => LatLng(g.latitude, g.longitude),
        final Map<String, dynamic> m => LatLng(
            (m['latitude'] as num? ?? m['lat'] as num? ?? 0).toDouble(),
            (m['longitude'] as num? ?? m['lng'] as num? ?? 0).toDouble(),
          ),
        _ => null,
      };

  @override
  Object? toJson(LatLng? object) =>
      object == null ? null : GeoPoint(object.latitude, object.longitude);
}

/// Reads a money field defensively.
///
/// Firestore hands back `int` for whole numbers and `double` if anything ever
/// wrote one. Rather than crash a customer's history screen on a legacy
/// document, coerce and move on — the server is the authority on the value.
class CentsConverter implements JsonConverter<int, Object?> {
  const CentsConverter();

  @override
  int fromJson(Object? json) => switch (json) {
        final int v => v,
        final double v => v.round(),
        final String v => int.tryParse(v) ?? 0,
        _ => 0,
      };

  @override
  Object toJson(int object) => object;
}
