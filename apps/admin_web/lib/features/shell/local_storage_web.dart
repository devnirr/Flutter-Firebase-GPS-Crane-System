import 'package:web/web.dart' as web;

/// Reads a small preference from the browser. A browser with storage blocked
/// throws here, and the panel simply behaves as if nothing was ever chosen.
String? readLocal(String key) {
  try {
    return web.window.localStorage.getItem(key);
  } on Object catch (_) {
    return null;
  }
}

void writeLocal(String key, String value) {
  try {
    web.window.localStorage.setItem(key, value);
  } on Object catch (_) {
    // Private window, storage disabled: the choice lasts this session only.
  }
}
