import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../domain/value_objects.dart';
import 'polyline.dart';
import 'script_router.dart';

/// A road route between two points, ready to draw.
@immutable
class RoadRoute {
  const RoadRoute({
    required this.points,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.isApproximate,
  });

  /// A straight line between the ends, for when no road route is available.
  /// The distance is padded by the usual detour factor so the figure shown is
  /// in the right ballpark rather than flatteringly short.
  factory RoadRoute.straight(LatLng from, LatLng to) {
    final meters = (from.distanceTo(to) * _detourFactor).round();
    return RoadRoute(
      points: [from, to],
      distanceMeters: meters,
      // 28 km/h: the urban average dispatch estimates with.
      durationSeconds: (meters / 1000 / 28 * 3600).round(),
      isApproximate: true,
    );
  }

  static const _detourFactor = 1.35;

  final List<LatLng> points;
  final int distanceMeters;
  final int durationSeconds;

  /// True when this is the straight-line fallback, so the screen can say so.
  final bool isApproximate;

  String get distanceLabel => distanceMeters < 1000
      ? '$distanceMeters m'
      : '${(distanceMeters / 1000).toStringAsFixed(1)} km';

  String get durationLabel {
    final minutes = (durationSeconds / 60).ceil();
    if (minutes < 60) return '$minutes min';
    return '${minutes ~/ 60} h ${(minutes % 60).toString().padLeft(2, '0')} min';
  }
}

/// Road routes from Google's Routes API.
///
/// Called with the same key the map uses, so there is nothing extra to
/// provision beyond enabling "Routes API" on it. Never fails: with no key, the
/// API not enabled, or no signal, the answer is a straight line marked
/// [RoadRoute.isApproximate] — a chofer deciding on an offer is better served
/// by a rough line than by no line.
class RouteService {
  RouteService({required this.apiKey, http.Client? client})
      : _client = client ?? http.Client();

  /// The Maps key. Routes are fetched only when it is set.
  final String apiKey;
  final http.Client _client;

  static final Uri _endpoint =
      Uri.parse('https://routes.googleapis.com/directions/v2:computeRoutes');

  /// Answers are cached by their ends, rounded to ~100 m: a chofer creeping
  /// down a street does not need a fresh route every few metres, and every
  /// call is billed.
  final _cache = <String, RoadRoute>{};

  static String _key(LatLng from, LatLng to) =>
      '${from.latitude.toStringAsFixed(3)},${from.longitude.toStringAsFixed(3)}'
      '>${to.latitude.toStringAsFixed(3)},${to.longitude.toStringAsFixed(3)}';

  Future<RoadRoute> route(LatLng from, LatLng to) async {
    final key = _key(from, to);
    final cached = _cache[key];
    if (cached != null) return cached;

    final fetched = await _fetch(from, to);
    // A path is only as good as the string it came from, and one wrong point
    // draws a line off the edge of the world and back. The straight line is
    // better than that.
    final sane = fetched == null
        ? null
        : sanePath(fetched.points, from: from, to: to).isEmpty
            ? null
            : fetched;

    // Only real routes are kept: a fallback caused by a dropped connection
    // should be retried next time, not remembered.
    if (sane != null) _cache[key] = sane;
    return sane ?? RoadRoute.straight(from, to);
  }

  Future<RoadRoute?> _fetch(LatLng from, LatLng to) async {
    // The browser first. `routes.googleapis.com` sends no CORS headers, so a
    // web build's POST below is refused before it leaves the page and every
    // map drew the tow as a straight line across the countryside. The Maps
    // script already on the page answers the same question from inside it.
    final script = await scriptRoute(from, to);
    if (script != null && script.points.length >= 2) {
      return RoadRoute(
        points: script.points,
        distanceMeters: script.distanceMeters,
        durationSeconds: script.durationSeconds,
        isApproximate: false,
      );
    }

    if (apiKey.isEmpty) return null;

    Map<String, Object> waypoint(LatLng p) => {
          'location': {
            'latLng': {'latitude': p.latitude, 'longitude': p.longitude},
          },
        };

    try {
      final response = await _client
          .post(
            _endpoint,
            headers: {
              'Content-Type': 'application/json',
              'X-Goog-Api-Key': apiKey,
              // Only what is drawn and shown; the API bills by field mask.
              'X-Goog-FieldMask':
                  'routes.distanceMeters,routes.duration,routes.polyline.encodedPolyline',
            },
            body: jsonEncode({
              'origin': waypoint(from),
              'destination': waypoint(to),
              'travelMode': 'DRIVE',
              'routingPreference': 'TRAFFIC_AWARE',
              'languageCode': 'es-DO',
              'units': 'METRIC',
            }),
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        // Most often "Routes API has not been used in project … or it is
        // disabled", which is a console fix, not a code one.
        debugPrint('Routes API ${response.statusCode}: ${response.body}');
        return null;
      }

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final routes = body['routes'] as List<dynamic>? ?? const [];
      if (routes.isEmpty) return null;
      final route = routes.first as Map<String, dynamic>;

      final encoded =
          (route['polyline'] as Map<String, dynamic>?)?['encodedPolyline']
              as String?;
      final points = encoded == null ? const <LatLng>[] : decodePolyline(encoded);
      if (points.length < 2) return null;

      // "1234s", as the API writes durations.
      final duration = route['duration'] as String? ?? '0s';
      return RoadRoute(
        points: points,
        distanceMeters: (route['distanceMeters'] as num?)?.round() ?? 0,
        durationSeconds:
            int.tryParse(duration.replaceAll(RegExp('[^0-9]'), '')) ?? 0,
        isApproximate: false,
      );
    } on Object catch (error) {
      debugPrint('Routes API unavailable: $error');
      return null;
    }
  }
}
