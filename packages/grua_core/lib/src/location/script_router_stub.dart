import '../domain/value_objects.dart';

/// Off the web there is no Maps script on a page; `RouteService` calls the
/// Routes API over HTTP instead, which works fine from a phone.
Future<ScriptRoute?> scriptRoute(LatLng from, LatLng to) async => null;

/// What the page's router answered: the drawn path and its two figures.
class ScriptRoute {
  const ScriptRoute({
    required this.points,
    required this.distanceMeters,
    required this.durationSeconds,
  });

  final List<LatLng> points;
  final int distanceMeters;
  final int durationSeconds;
}
