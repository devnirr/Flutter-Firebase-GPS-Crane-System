import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// True once `https://maps.googleapis.com/maps/api/js` has run and defined
/// `window.google.maps`. The script tag is synchronous and sits before the
/// Flutter bootstrap, so by the time Dart runs this is settled.
bool get googleMapsScriptLoaded {
  if (!globalContext.has('google')) return false;
  final google = globalContext['google'];
  return google != null && (google as JSObject).has('maps');
}

/// The key the page's Maps script was loaded with, for the HTTP APIs — Places
/// autocomplete among them — that need one in Dart.
///
/// On the web the key lives in `web/index.html`, so the build-time define is
/// usually empty there and asking for it would leave the web build without
/// suggestions on a page whose map works perfectly.
String get googleMapsScriptKey {
  final document = globalContext['document'];
  if (document == null) return '';

  final scripts = (document as JSObject).callMethod<JSArray<JSObject>>(
    'querySelectorAll'.toJS,
    'script[src*="maps.googleapis.com"]'.toJS,
  );
  for (final script in scripts.toDart) {
    final src = script.getProperty<JSString?>('src'.toJS)?.toDart ?? '';
    final key = Uri.tryParse(src)?.queryParameters['key'] ?? '';
    if (key.isNotEmpty) return key;
  }
  return '';
}
