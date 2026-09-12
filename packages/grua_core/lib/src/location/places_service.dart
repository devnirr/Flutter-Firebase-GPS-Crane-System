import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../domain/value_objects.dart';
import 'location_service.dart';

/// One line of the suggestion list: what the customer reads, and the id that
/// turns it into a point.
@immutable
class PlaceSuggestion {
  const PlaceSuggestion({
    required this.placeId,
    required this.title,
    this.subtitle = '',
  });

  final String placeId;

  /// The name or street, as Google returns it for the typed text.
  final String title;

  /// The rest of the address — sector, city — under the title.
  final String subtitle;

  @override
  bool operator ==(Object other) =>
      other is PlaceSuggestion &&
      other.placeId == placeId &&
      other.title == title &&
      other.subtitle == subtitle;

  @override
  int get hashCode => Object.hash(placeId, title, subtitle);
}

/// Address suggestions and the point behind the one that gets picked.
///
/// The Places API (New), called over HTTP rather than through a plugin: the
/// same code then answers on Android, iOS and the web, where the `geocoding`
/// plugin has no implementation at all and the destination field stayed empty
/// however long the customer waited.
///
/// Every failure is an empty list. A customer who gets no suggestions can
/// still drag the pin and type the address, and an error banner over a map
/// helps nobody.
class PlacesService {
  PlacesService({required this.apiKey, http.Client? client})
    : _client = client ?? http.Client();

  final String apiKey;
  final http.Client _client;

  static const _host = 'places.googleapis.com';

  /// Dominican results, in Dominican Spanish.
  static const _regionCode = 'do';
  static const _languageCode = 'es-DO';

  /// Whether suggestions are possible at all. False without a key, which is
  /// every fresh checkout: the UI then offers the map and the text field only.
  bool get isAvailable => apiKey.isNotEmpty;

  /// Places matching [input], nearest [near] first when it is known.
  ///
  /// Two characters is the shortest input worth a call; anything shorter
  /// matches half the country.
  Future<List<PlaceSuggestion>> suggest(
    String input, {
    LatLng? near,
    double radiusKm = 50,
  }) async {
    final query = input.trim();
    if (!isAvailable || query.length < 2) return const [];

    try {
      final response = await _client.post(
        Uri.https(_host, '/v1/places:autocomplete'),
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': apiKey,
          'X-Goog-FieldMask': 'suggestions.placePrediction.placeId,'
              'suggestions.placePrediction.structuredFormat',
        },
        body: jsonEncode({
          'input': query,
          'languageCode': _languageCode,
          'includedRegionCodes': [_regionCode],
          if (near != null)
            'locationBias': {
              'circle': {
                'center': {
                  'latitude': near.latitude,
                  'longitude': near.longitude,
                },
                'radius': radiusKm * 1000,
              },
            },
        }),
      );

      if (response.statusCode != 200) {
        // Most often the Places API (New) is not enabled on the project, or
        // the key is restricted to the Maps SDK. Said once, quietly, rather
        // than on the customer's screen.
        debugPrint(
          'Places autocomplete refused (${response.statusCode}): '
          '${response.body}',
        );
        return const [];
      }

      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) return const [];
      final suggestions = body['suggestions'];
      if (suggestions is! List) return const [];

      return [
        for (final raw in suggestions)
          if (raw is Map<String, dynamic>) ?_suggestion(raw),
      ];
    } on Object catch (error) {
      debugPrint('Places autocomplete failed: $error');
      return const [];
    }
  }

  static PlaceSuggestion? _suggestion(Map<String, dynamic> raw) {
    final prediction = raw['placePrediction'];
    if (prediction is! Map<String, dynamic>) return null;

    final placeId = prediction['placeId'] as String? ?? '';
    if (placeId.isEmpty) return null;

    final format = prediction['structuredFormat'];
    final main = format is Map<String, dynamic> ? format['mainText'] : null;
    final secondary =
        format is Map<String, dynamic> ? format['secondaryText'] : null;

    final title = main is Map<String, dynamic>
        ? main['text'] as String? ?? ''
        : '';
    if (title.isEmpty) return null;

    return PlaceSuggestion(
      placeId: placeId,
      title: title,
      subtitle: secondary is Map<String, dynamic>
          ? secondary['text'] as String? ?? ''
          : '',
    );
  }

  /// Names a point by what stands on it.
  ///
  /// A second way to answer "what is this place called", for when the
  /// Geocoding API is not the one enabled on the project: the nearest place
  /// within [radiusMeters] and its short address. Less precise than a reverse
  /// geocode — it says "Plaza Central, Av. 27 de Febrero" where a geocoder
  /// would give a street number — and far better than coordinates.
  Future<ResolvedPlace?> describePoint(
    LatLng point, {
    double radiusMeters = 80,
  }) async {
    if (!isAvailable) return null;

    try {
      final response = await _client.post(
        Uri.https(_host, '/v1/places:searchNearby'),
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': apiKey,
          'X-Goog-FieldMask':
              'places.displayName,places.shortFormattedAddress,places.location',
        },
        body: jsonEncode({
          'maxResultCount': 1,
          'rankPreference': 'DISTANCE',
          'languageCode': _languageCode,
          'locationRestriction': {
            'circle': {
              'center': {
                'latitude': point.latitude,
                'longitude': point.longitude,
              },
              'radius': radiusMeters,
            },
          },
        }),
      );
      if (response.statusCode != 200) {
        debugPrint(
          'Nearby place refused (${response.statusCode}): ${response.body}',
        );
        return null;
      }

      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) return null;
      final places = body['places'];
      if (places is! List || places.isEmpty) return null;
      final first = places.first;
      if (first is! Map<String, dynamic>) return null;

      final name = first['displayName'];
      final label = name is Map<String, dynamic>
          ? name['text'] as String? ?? ''
          : '';
      final street = first['shortFormattedAddress'] as String? ?? '';
      final address = [
        if (label.isNotEmpty) label,
        if (street.isNotEmpty && street != label) street,
      ].join(', ');
      if (address.isEmpty) return null;

      // The point stays the customer's own; only the name comes from here.
      return ResolvedPlace(position: point, address: address);
    } on Object catch (error) {
      debugPrint('Nearby place failed: $error');
      return null;
    }
  }

  /// Where a suggestion actually is. Null when the lookup fails, so the caller
  /// leaves the map where it was rather than jumping to nowhere.
  Future<ResolvedPlace?> details(String placeId) async {
    if (!isAvailable || placeId.isEmpty) return null;

    try {
      final response = await _client.get(
        Uri.https(_host, '/v1/places/$placeId', {
          'languageCode': _languageCode,
        }),
        headers: {
          'X-Goog-Api-Key': apiKey,
          'X-Goog-FieldMask': 'location,formattedAddress,shortFormattedAddress',
        },
      );
      if (response.statusCode != 200) {
        debugPrint(
          'Place details refused (${response.statusCode}): ${response.body}',
        );
        return null;
      }

      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) return null;

      final location = body['location'];
      if (location is! Map<String, dynamic>) return null;
      final lat = (location['latitude'] as num?)?.toDouble();
      final lng = (location['longitude'] as num?)?.toDouble();
      if (lat == null || lng == null) return null;

      return ResolvedPlace(
        position: LatLng(lat, lng),
        address: body['shortFormattedAddress'] as String? ??
            body['formattedAddress'] as String? ??
            '',
      );
    } on Object catch (error) {
      debugPrint('Place details failed: $error');
      return null;
    }
  }
}
