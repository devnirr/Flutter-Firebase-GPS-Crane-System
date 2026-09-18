import 'package:flutter/material.dart';
import 'package:grua_core/grua_core.dart';

import 'local_storage_stub.dart'
    if (dart.library.js_interop) 'local_storage_web.dart' as browser;

/// Keeps the chosen skin in the browser, so the panel opens the way this
/// machine was left. It is a preference of the workstation, not of the
/// account — see [ThemeModeStore].
class BrowserThemeModeStore implements ThemeModeStore {
  const BrowserThemeModeStore();

  static const _key = 'grua.admin.theme';

  @override
  ThemeMode? read() => themeModeFromStoredName(browser.readLocal(_key));

  @override
  void write(ThemeMode mode) => browser.writeLocal(_key, mode.storedName);
}
