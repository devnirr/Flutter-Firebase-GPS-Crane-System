/// Reverse geocoding through the page's Maps script, where there is one.
library;

export 'script_geocoder_stub.dart'
    if (dart.library.js_interop) 'script_geocoder_web.dart';
