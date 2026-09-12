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

/// Rewrites a value from Firestore's dialect into plain JSON, for the payload
/// of a Cloud Functions callable.
///
/// Every model here serialises for Firestore: a coordinate leaves `toJson` as
/// a [GeoPoint], an instant as a [Timestamp]. Firestore understands both. A
/// callable does not — the platform-channel codec has no entry for either, and
/// on the web `jsify` refuses them outright — so a payload built from
/// `model.toJson()` failed *before it left the phone*, with an error no server
/// ever saw. It reached the customer as "Algo salió mal", which is why pressing
/// VER PRECIO could never work.
///
/// Dates become ISO-8601 in UTC because that is what the callables validate
/// against (`z.string().datetime()`), and `GeoPoint` becomes the
/// `{latitude, longitude}` pair their `point` schema expects.
Object? callableJson(Object? value) => switch (value) {
      final GeoPoint g => {'latitude': g.latitude, 'longitude': g.longitude},
      final Timestamp t => t.toDate().toUtc().toIso8601String(),
      final DateTime d => d.toUtc().toIso8601String(),
      final Map<Object?, Object?> map => {
          for (final entry in map.entries)
            '${entry.key}': callableJson(entry.value),
        },
      // Strings are Iterable-adjacent in spirit but not in type; this catches
      // lists and sets, which is all a payload ever holds.
      final Iterable<Object?> items => [
          for (final item in items) callableJson(item),
        ],
      _ => value,
    };

/// [callableJson] over a whole payload, keeping the map type a callable wants.
Map<String, dynamic> callablePayload(Map<String, dynamic> payload) => {
      for (final entry in payload.entries)
        entry.key: callableJson(entry.value),
    };

/// The mirror image, for what a callable sends back.
///
/// The web plugin hands back `Map<String, dynamic>` all the way down, but the
/// Android and iOS ones decode the channel into `Map<Object?, Object?>`, and
/// `json_serializable` casts nested objects to `Map<String, dynamic>` without
/// asking. One surcharge on a quote was enough to throw there — the same
/// generic error, on the platforms most customers use.
Object? plainJson(Object? value) => switch (value) {
      final Map<Object?, Object?> map => {
          for (final entry in map.entries) '${entry.key}': plainJson(entry.value),
        },
      final Iterable<Object?> items => [for (final item in items) plainJson(item)],
      _ => value,
    };
