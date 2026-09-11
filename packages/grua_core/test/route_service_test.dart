import 'dart:convert';

import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Road routes for the chofer's map. The contract that matters: a real route
/// when the API answers, and a straight line — never an error — when it does
/// not.
void main() {
  const santoDomingo = LatLng(18.4861, -69.9312);
  const boca = LatLng(18.4520, -69.6090);

  test("decodes Google's own worked example", () {
    // From the Encoded Polyline Algorithm Format documentation.
    final points = decodePolyline('_p~iF~ps|U_ulLnnqC_mqNvxq`@');

    expect(points, hasLength(3));
    expect(points[0].latitude, closeTo(38.5, 1e-5));
    expect(points[0].longitude, closeTo(-120.2, 1e-5));
    expect(points[1].latitude, closeTo(40.7, 1e-5));
    expect(points[1].longitude, closeTo(-120.95, 1e-5));
    expect(points[2].latitude, closeTo(43.252, 1e-5));
    expect(points[2].longitude, closeTo(-126.453, 1e-5));
  });

  test('a Routes API answer becomes a drawable road route', () async {
    late http.Request sent;
    final service = RouteService(
      apiKey: 'test-key',
      client: MockClient((request) async {
        sent = request;
        return http.Response(
          jsonEncode({
            'routes': [
              {
                'distanceMeters': 41250,
                'duration': '2710s',
                'polyline': {'encodedPolyline': '_p~iF~ps|U_ulLnnqC_mqNvxq`@'},
              },
            ],
          }),
          200,
        );
      }),
    );

    final route = await service.route(santoDomingo, boca);

    expect(route.isApproximate, isFalse);
    expect(route.points, hasLength(3));
    expect(route.distanceMeters, 41250);
    expect(route.durationSeconds, 2710);
    expect(route.distanceLabel, '41.3 km');
    expect(route.durationLabel, '46 min');
    // Keyed and field-masked, as the API bills.
    expect(sent.headers['X-Goog-Api-Key'], 'test-key');
    expect(sent.headers['X-Goog-FieldMask'], contains('encodedPolyline'));
  });

  test('an API that refuses leaves a straight, approximate line', () async {
    final service = RouteService(
      apiKey: 'test-key',
      client: MockClient(
        (_) async => http.Response('{"error":{"status":"PERMISSION_DENIED"}}', 403),
      ),
    );

    final route = await service.route(santoDomingo, boca);

    expect(route.isApproximate, isTrue);
    expect(route.points, [santoDomingo, boca]);
    // Padded for the detour, so it is not flatteringly short.
    expect(route.distanceMeters, greaterThan(santoDomingo.distanceTo(boca)));
  });

  test('without a key nothing is called at all', () async {
    var called = false;
    final service = RouteService(
      apiKey: '',
      client: MockClient((_) async {
        called = true;
        return http.Response('', 500);
      }),
    );

    final route = await service.route(santoDomingo, boca);

    expect(called, isFalse);
    expect(route.isApproximate, isTrue);
  });

  test('the same ends are fetched once', () async {
    var calls = 0;
    final service = RouteService(
      apiKey: 'test-key',
      client: MockClient((_) async {
        calls++;
        return http.Response(
          jsonEncode({
            'routes': [
              {
                'distanceMeters': 1000,
                'duration': '120s',
                'polyline': {'encodedPolyline': '_p~iF~ps|U_ulLnnqC'},
              },
            ],
          }),
          200,
        );
      }),
    );

    await service.route(santoDomingo, boca);
    await service.route(santoDomingo, boca);

    expect(calls, 1);
  });

  test('the camera fits every point it is given', () {
    final camera = cameraFitting([santoDomingo, boca], const Size(400, 300))!;

    // Between the two, and zoomed out far enough to hold ~34 km in 400 px.
    expect(camera.center.longitude, closeTo((-69.9312 + -69.6090) / 2, 1e-6));
    expect(camera.zoom, inInclusiveRange(9, 12));
    // One point is simply centred, close in.
    expect(cameraFitting([boca], const Size(400, 300))!.zoom, 16);
    expect(cameraFitting(const [], const Size(400, 300)), isNull);
  });
}
