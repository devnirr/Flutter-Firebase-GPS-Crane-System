/// Whether the page loaded the Google Maps JavaScript API.
///
/// On the web the key lives in the `<script>` tag in `web/index.html`, not in
/// the Dart build, so the build-time define is the wrong question there: a
/// panel started without `--dart-define-from-file` would draw the fallback map
/// over a perfectly working Maps script. Always false off the web.
library;

export 'maps_script_stub.dart'
    if (dart.library.js_interop) 'maps_script_web.dart';
