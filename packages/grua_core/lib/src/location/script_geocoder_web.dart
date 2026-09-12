import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import '../config/maps_script.dart';

/// Names a point using the Maps JavaScript API the page has already loaded.
///
/// The `geocoding` plugin has no web implementation at all, so on the web
/// every address field stayed empty however long the customer waited — and
/// the pickup row could only say "tu ubicación actual" about a point it could
/// not name. The script in `index.html` carries `google.maps.Geocoder`, which
/// answers the same question over the same billed key.
///
/// Null on any failure: no script, no result, a refused key. The caller then
/// leaves the field as it was rather than showing an error over a map.
Future<String?> scriptReverseGeocode(double latitude, double longitude) async {
  if (!googleMapsScriptLoaded) return null;

  try {
    final google = globalContext['google'] as JSObject?;
    final maps = google?['maps'] as JSObject?;
    final constructor = maps?['Geocoder'] as JSFunction?;
    if (constructor == null) return null;

    final geocoder = constructor.callAsConstructor<JSObject>();
    final location = JSObject()
      ..setProperty('lat'.toJS, latitude.toJS)
      ..setProperty('lng'.toJS, longitude.toJS);
    final request = JSObject()
      ..setProperty('location'.toJS, location)
      // The Dominican Spanish the rest of the app speaks, whatever the
      // browser's own language is set to.
      ..setProperty('language'.toJS, 'es'.toJS)
      ..setProperty('region'.toJS, 'DO'.toJS);

    final response = await geocoder
        .callMethod<JSPromise<JSObject>>('geocode'.toJS, request)
        .toDart;

    final results = response['results'] as JSArray<JSObject>?;
    final first = results?.toDart.firstOrNull;
    if (first == null) return null;

    final address = first['formatted_address'] as JSString?;
    final text = address?.toDart ?? '';
    return text.isEmpty ? null : text;
  } on Object {
    // A geocode nobody can read is not worth an exception on a screen whose
    // map and text field both still work.
    return null;
  }
}
