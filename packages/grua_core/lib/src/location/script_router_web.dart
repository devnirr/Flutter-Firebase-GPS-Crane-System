import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import '../config/maps_script.dart';
import '../domain/value_objects.dart';
import 'polyline.dart';

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

/// A driving route from the Maps JavaScript API the page has already loaded.
///
/// The Routes API is an HTTP service with no CORS headers, so a browser cannot
/// call it: `RouteService`'s POST is refused before it leaves the page, the
/// fallback takes over, and every map on the web draws the tow as a straight
/// line across the countryside. `google.maps.DirectionsService` answers the
/// same question from inside the page, over the same billed key, with no
/// preflight to refuse — the same move `scriptReverseGeocode` makes for
/// addresses.
///
/// Null on any failure. The caller then falls back to the straight line, which
/// is still better than no line at all.
Future<ScriptRoute?> scriptRoute(LatLng from, LatLng to) async {
  if (!googleMapsScriptLoaded) return null;

  try {
    final google = globalContext['google'] as JSObject?;
    final maps = google?['maps'] as JSObject?;
    final constructor = maps?['DirectionsService'] as JSFunction?;
    if (constructor == null) return null;

    final service = constructor.callAsConstructor<JSObject>();

    JSObject latLng(LatLng p) => JSObject()
      ..setProperty('lat'.toJS, p.latitude.toJS)
      ..setProperty('lng'.toJS, p.longitude.toJS);

    final request = JSObject()
      ..setProperty('origin'.toJS, latLng(from))
      ..setProperty('destination'.toJS, latLng(to))
      ..setProperty('travelMode'.toJS, 'DRIVING'.toJS);

    // Called without a callback, `route` returns a promise.
    final result = await service
        .callMethod<JSPromise<JSObject>>('route'.toJS, request)
        .toDart;

    final routes = result['routes'] as JSArray<JSObject>?;
    final route = routes?.toDart.firstOrNull;
    if (route == null) return null;

    final points = _pathOf(route);
    if (points.length < 2) return null;

    return ScriptRoute(
      points: points,
      distanceMeters: _legTotal(route, 'distance'),
      durationSeconds: _legTotal(route, 'duration'),
    );
  } on Object {
    // ZERO_RESULTS for a point in the sea, a key without the Directions
    // service, no signal. None of them is worth an exception on a screen whose
    // map still works.
    return null;
  }
}

/// The drawn path, however this version of the API spells it.
///
/// `overview_polyline` has been a bare encoded string and a `{points: …}`
/// object across versions, and `overview_path` is there either way as real
/// `LatLng` objects. Reading all three is cheaper than pinning a version.
List<LatLng> _pathOf(JSObject route) {
  final overview = route['overview_polyline'];
  if (overview.isA<JSString>()) {
    return decodePolyline((overview! as JSString).toDart);
  }
  if (overview.isA<JSObject>()) {
    final encoded = (overview! as JSObject)['points'] as JSString?;
    if (encoded != null) return decodePolyline(encoded.toDart);
  }

  final path = route['overview_path'] as JSArray<JSObject>?;
  if (path == null) return const [];
  return [
    for (final point in path.toDart)
      LatLng(
        point.callMethod<JSNumber>('lat'.toJS).toDartDouble,
        point.callMethod<JSNumber>('lng'.toJS).toDartDouble,
      ),
  ];
}

/// Sums a leg field across the route. One leg here — there are no waypoints —
/// but summing is correct whatever the API returns.
int _legTotal(JSObject route, String field) {
  final legs = route['legs'] as JSArray<JSObject>?;
  if (legs == null) return 0;

  var total = 0;
  for (final leg in legs.toDart) {
    final value = (leg[field] as JSObject?)?['value'] as JSNumber?;
    total += value?.toDartInt ?? 0;
  }
  return total;
}
