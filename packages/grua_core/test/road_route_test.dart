import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The line drawn between two points on every map in the product.
///
/// The bug this pins down: it was a straight one. On the web the Routes API is
/// unreachable — `routes.googleapis.com` sends no CORS headers, so the POST is
/// refused before it leaves the page — and the fallback drew a tow as a line
/// across the mountains. The screens that never asked for a road route at all
/// drew the same thing everywhere else.
void main() {
  const jarabacoa = LatLng(19.1221, -70.6367);
  const santiago = LatLng(19.4517, -70.6970);

  /// The Routes API's answer, trimmed to the fields the service reads.
  String routesApiBody(String polyline) => jsonEncode({
        'routes': [
          {
            'distanceMeters': 52340,
            'duration': '3600s',
            'polyline': {'encodedPolyline': polyline},
          },
        ],
      });

  test('a real route is drawn along the road, not across country', () async {
    // Three points from the encoder: a line that bends is a road.
    const encoded = 'cxusBjfcnL{eNrpC_jZ~{BcyTfiB';
    final service = RouteService(
      apiKey: 'k',
      client: MockClient((_) async => http.Response(
            routesApiBody(encoded),
            200,
            headers: {'content-type': 'application/json'},
          )),
    );

    final route = await service.route(jarabacoa, santiago);

    expect(route.isApproximate, isFalse);
    expect(route.points.length, greaterThan(2));
    expect(route.distanceMeters, 52340);
    expect(route.durationSeconds, 3600);
  });

  test('an unreachable router still draws something', () async {
    // What the web does today before the page's own router answers: refused
    // outright. A chofer is better served by a rough line than by no line.
    final service = RouteService(
      apiKey: 'k',
      client: MockClient((_) async => http.Response('denied', 403)),
    );

    final route = await service.route(jarabacoa, santiago);

    expect(route.isApproximate, isTrue);
    expect(route.points, [jarabacoa, santiago]);
    // Padded by the detour factor rather than flatteringly short.
    expect(
      route.distanceMeters,
      greaterThan(jarabacoa.distanceTo(santiago).round()),
    );
  });

  test('the straight fallback is not cached over a real answer', () async {
    var calls = 0;
    final service = RouteService(
      apiKey: 'k',
      client: MockClient((_) async {
        calls++;
        return calls == 1
            ? http.Response('boom', 500)
            : http.Response(
                routesApiBody('cxusBjfcnL{eNrpC_jZ~{BcyTfiB'),
                200,
                headers: {'content-type': 'application/json'},
              );
      }),
    );

    final first = await service.route(jarabacoa, santiago);
    expect(first.isApproximate, isTrue);

    final second = await service.route(jarabacoa, santiago);
    expect(second.isApproximate, isFalse, reason: 'a dropped call is retried');
  });

  test('a service carries the path the server routed for it', () {
    // Every screen draws this rather than fetching its own, so the customer,
    // the chofer and the dispatcher cannot see three different lines.
    const service = ServiceRoute(
      distanceMeters: 52340,
      durationSeconds: 3600,
      polyline: '_p~iF~ps|U_ulLnnqC_mqNvxq`@',
      provider: 'routes_api',
    );

    expect(service.path, hasLength(3));
    expect(service.path.first.latitude, closeTo(38.5, 0.0001));
  });

  test('a service quoted before the server routed has no path to draw', () {
    // The screens then fetch their own, and fall back to the straight line
    // under that — an old service still shows something.
    const old = ServiceRoute(distanceMeters: 8000, provider: 'estimate');

    expect(old.path, isEmpty);
  });

  test('a path with one point in the ocean is thrown away whole', () {
    // What the dispatcher's map showed: a red band straight across the
    // country, through a pickup whose tow was twenty kilometres long. One
    // wrong point in an otherwise fine path does that, and a wrong path is
    // worse than none — without one the screen falls back to a straight line
    // that is at least between the right two places.
    final path = [
      jarabacoa,
      const LatLng(19.20, -70.66),
      const LatLng(19.15, -30.00), // the Atlantic
      santiago,
    ];

    expect(sanePath(path, from: jarabacoa, to: santiago), isEmpty);
  });

  test('a road that wanders is still a road', () {
    // Around a reservoir, down to a bridge: a real route is not a straight
    // line and the check must not mistake one for a broken path.
    final path = [
      jarabacoa,
      const LatLng(19.28, -70.55),
      const LatLng(19.35, -70.80),
      santiago,
    ];

    expect(sanePath(path, from: jarabacoa, to: santiago), path);
  });

  test('two points are a path; one is not', () {
    expect(sanePath([jarabacoa, santiago], from: jarabacoa, to: santiago),
        hasLength(2));
    expect(sanePath([jarabacoa], from: jarabacoa, to: santiago), isEmpty);
  });

  test('a service will not draw a path that is not its own trip', () {
    const service = ServiceRoute(
      distanceMeters: 20000,
      // A valid polyline, but for a trip on the other side of the world.
      polyline: '_p~iF~ps|U_ulLnnqC_mqNvxq`@',
      provider: 'routes_api',
    );

    expect(service.path, isNotEmpty, reason: 'it decodes');
    expect(
      sanePath(service.path, from: jarabacoa, to: santiago),
      isEmpty,
      reason: 'but it is not this trip',
    );
  });

  test('the polyline decoder reads what Google encodes', () {
    // Google's own documented example.
    final points = decodePolyline('_p~iF~ps|U_ulLnnqC_mqNvxq`@');

    expect(points, hasLength(3));
    expect(points.first.latitude, closeTo(38.5, 0.0001));
    expect(points.first.longitude, closeTo(-120.2, 0.0001));
    expect(points.last.latitude, closeTo(43.252, 0.0001));
    expect(points.last.longitude, closeTo(-126.453, 0.0001));
  });
}
