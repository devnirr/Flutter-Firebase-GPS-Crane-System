import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Address suggestions, which the web build has no other way to get: the
/// `geocoding` plugin has no web implementation, so the destination field used
/// to stay empty there however long anybody waited.
void main() {
  const near = LatLng(18.4795, -69.9420);

  test('a typed street comes back as suggestions, biased to the map', () async {
    late http.Request sent;
    final places = PlacesService(
      apiKey: 'k',
      client: MockClient((request) async {
        sent = request;
        return http.Response(
          jsonEncode({
            'suggestions': [
              {
                'placePrediction': {
                  'placeId': 'place-1',
                  'structuredFormat': {
                    'mainText': {'text': 'Av. Winston Churchill'},
                    'secondaryText': {'text': 'Piantini, Santo Domingo'},
                  },
                },
              },
              // No id and no name: nothing to offer, and nothing to crash on.
              {'placePrediction': {'placeId': ''}},
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final found = await places.suggest('Winston', near: near);

    expect(found, hasLength(1));
    expect(found.single.placeId, 'place-1');
    expect(found.single.title, 'Av. Winston Churchill');
    expect(found.single.subtitle, 'Piantini, Santo Domingo');

    // Dominican results, in Spanish, near where the customer is looking.
    final body = jsonDecode(sent.body) as Map<String, dynamic>;
    expect(body['input'], 'Winston');
    expect(body['includedRegionCodes'], ['do']);
    expect(body['languageCode'], 'es-DO');
    expect(
      ((body['locationBias'] as Map)['circle'] as Map)['center'],
      {'latitude': near.latitude, 'longitude': near.longitude},
    );
    expect(sent.headers['X-Goog-Api-Key'], 'k');
  });

  test('one letter is not worth a call, and no key is not worth one either', () async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return http.Response('{}', 200);
    });

    final places = PlacesService(apiKey: 'k', client: client);
    expect(await places.suggest('a'), isEmpty);
    expect(await places.suggest('  '), isEmpty);
    expect(calls, 0);

    final keyless = PlacesService(apiKey: '', client: client);
    expect(keyless.isAvailable, isFalse);
    expect(await keyless.suggest('Winston'), isEmpty);
    expect(calls, 0);
  });

  test('a refused call is an empty list, not an exception', () async {
    final places = PlacesService(
      apiKey: 'k',
      client: MockClient(
        (_) async => http.Response('{"error":{"status":"PERMISSION_DENIED"}}', 403),
      ),
    );

    // The Places API not being enabled on the project must leave the map and
    // the text field working.
    expect(await places.suggest('Winston'), isEmpty);
    expect(await places.details('place-1'), isNull);
  });

  test('the chosen suggestion resolves to a point and a short address', () async {
    final places = PlacesService(
      apiKey: 'k',
      client: MockClient(
        (request) async => http.Response(
          jsonEncode({
            'location': {'latitude': 18.4861, 'longitude': -69.9312},
            'formattedAddress': 'Av. Winston Churchill, Santo Domingo, RD',
            'shortFormattedAddress': 'Av. Winston Churchill, Piantini',
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );

    final place = await places.details('place-1');

    expect(place, isNotNull);
    expect(place!.position.latitude, closeTo(18.4861, 0.0001));
    expect(place.position.longitude, closeTo(-69.9312, 0.0001));
    // The short one: a bubble on a map has no room for the country.
    expect(place.address, 'Av. Winston Churchill, Piantini');
  });

  test('a point is named by what stands on it', () async {
    late http.Request sent;
    final places = PlacesService(
      apiKey: 'k',
      client: MockClient((request) async {
        sent = request;
        return http.Response(
          jsonEncode({
            'places': [
              {
                'displayName': {'text': 'Plaza Central'},
                'shortFormattedAddress': 'Av. 27 de Febrero, Santo Domingo',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final place = await places.describePoint(near);

    expect(place, isNotNull);
    // The name and the street, and the customer's own point — not the
    // place's, which could be a block away.
    expect(place!.address, 'Plaza Central, Av. 27 de Febrero, Santo Domingo');
    expect(place.position, near);

    final body = jsonDecode(sent.body) as Map<String, dynamic>;
    expect(body['rankPreference'], 'DISTANCE');
    expect(body['maxResultCount'], 1);
    expect(
      ((body['locationRestriction'] as Map)['circle'] as Map)['radius'],
      80,
    );
  });

  test('nothing standing there is not a name', () async {
    final places = PlacesService(
      apiKey: 'k',
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({'places': <Object>[]}),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );

    expect(await places.describePoint(near), isNull);
  });

  test('an answer with no coordinates is no answer', () async {
    final places = PlacesService(
      apiKey: 'k',
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({'formattedAddress': 'Algún lugar'}),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );

    expect(await places.details('place-1'), isNull);
  });
}
