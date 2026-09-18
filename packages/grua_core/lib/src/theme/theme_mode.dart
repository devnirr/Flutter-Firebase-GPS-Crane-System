import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Which skin the panel is in, and where that choice is kept.
///
/// The choice belongs to the browser, not to the account: the same dispatcher
/// wants dark at night on the desk machine and light on the laptop by the
/// window. Core only defines the notifier and the hole a store plugs into; the
/// panel fills it with the browser's local storage.

/// Remembers the chosen skin between sessions.
abstract interface class ThemeModeStore {
  /// The stored choice, or null when nothing was ever chosen — or when the
  /// platform has nowhere to store it.
  ThemeMode? read();

  void write(ThemeMode mode);
}

/// The default: nothing is remembered. Every app starts here, and the panel
/// overrides it with a store that writes to the browser.
class NoThemeModeStore implements ThemeModeStore {
  const NoThemeModeStore();

  @override
  ThemeMode? read() => null;

  @override
  void write(ThemeMode mode) {}
}

/// Remembers the choice for as long as the process lives. Used by tests.
class InMemoryThemeModeStore implements ThemeModeStore {
  InMemoryThemeModeStore([this._mode]);

  ThemeMode? _mode;

  @override
  ThemeMode? read() => _mode;

  @override
  void write(ThemeMode mode) => _mode = mode;
}

/// The store the panel writes through. Overridden in `main`.
final themeModeStoreProvider = Provider<ThemeModeStore>(
  (ref) => const NoThemeModeStore(),
);

/// The skin in use. [ThemeMode.system] follows the operating system, which is
/// what a first-time visitor gets.
final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(
  ThemeModeNotifier.new,
);

class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() => ref.read(themeModeStoreProvider).read() ?? ThemeMode.system;

  void set(ThemeMode mode) {
    if (mode == state) return;
    state = mode;
    ref.read(themeModeStoreProvider).write(mode);
  }

  /// What the one-tap control in the top bar does: whatever you are looking at
  /// now, go to the other one. From "system" that means leaving automatic mode,
  /// which is what somebody pressing it intends.
  void toggle(Brightness showing) =>
      set(showing == Brightness.dark ? ThemeMode.light : ThemeMode.dark);
}

/// The names the choice is stored under. Kept out of the store so every
/// platform writes the same three strings.
extension ThemeModeName on ThemeMode {
  String get storedName => switch (this) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        ThemeMode.system => 'system',
      };

  /// What to call it in Spanish, for the menu in the panel.
  String get spanishLabel => switch (this) {
        ThemeMode.light => 'Claro',
        ThemeMode.dark => 'Oscuro',
        ThemeMode.system => 'Como el sistema',
      };

  IconData get icon => switch (this) {
        ThemeMode.light => Icons.light_mode_outlined,
        ThemeMode.dark => Icons.dark_mode_outlined,
        ThemeMode.system => Icons.brightness_auto_outlined,
      };
}

/// The reverse of [ThemeModeName.storedName]; null for anything unexpected, so
/// a stale or hand-edited value falls back to following the system.
ThemeMode? themeModeFromStoredName(String? name) => switch (name) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      'system' => ThemeMode.system,
      _ => null,
    };
