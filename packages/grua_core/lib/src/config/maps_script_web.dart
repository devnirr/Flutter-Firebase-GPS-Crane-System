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
