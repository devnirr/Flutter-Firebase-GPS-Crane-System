import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:intl/date_symbol_data_local.dart';

import 'config/app_config.dart';
import 'domain/enums.dart';
import 'providers.dart';
import 'theme/brand.dart';

/// Boots one of the three apps.
///
/// The entry point is shared so initialization order, error capture and locale
/// setup cannot drift between products — the client app crashing on a
/// misconfigured locale while the driver app is fine is a bug nobody finds
/// until a Sunday.
///
/// [backendOverrides] chooses the data layer. Until Firebase credentials exist
/// the apps run against the in-memory demo backend, which is also what widget
/// tests use.
Future<void> runGruaApp({
  required AppKind appKind,
  required Widget Function() builder,
  UserRole demoRole = UserRole.client,
  List<Override> Function()? backendOverrides,
}) async {
  await runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      final config = AppConfig.fromEnvironment(appKind)..assertProductionReady();

      // Dominican formatting for dates and currency. Without this, `es_DO`
      // number and date patterns silently fall back to en_US.
      await initializeDateFormatting('es_DO');

      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        if (kDebugMode) return;
        // Crashlytics is wired here once Firebase is configured.
      };

      PlatformDispatcher.instance.onError = (error, stack) {
        debugPrint('Uncaught: $error\n$stack');
        return true;
      };

      // Phone apps are portrait-only: a chofer holding a phone sideways on a
      // highway shoulder is not a layout we want to support.
      if (appKind != AppKind.admin) {
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ]);
      }

      SystemChrome.setSystemUIOverlayStyle(
        const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.dark,
          statusBarBrightness: Brightness.light,
          systemNavigationBarColor: BrandColors.white,
          systemNavigationBarIconBrightness: Brightness.dark,
        ),
      );

      final overrides = <Override>[
        appConfigProvider.overrideWithValue(config),
        ...?backendOverrides?.call(),
        if (backendOverrides == null) ...demoOverrides(role: demoRole),
      ];

      runApp(ProviderScope(overrides: overrides, child: builder()));
    },
    (error, stack) => debugPrint('Zone error: $error\n$stack'),
  );
}

/// Localization delegates and supported locales, shared by all three apps.
abstract final class GruaLocalization {
  static const Locale spanishDominican = Locale('es', 'DO');
  static const Locale english = Locale('en');

  static const List<Locale> supportedLocales = [spanishDominican, english];

  static const List<LocalizationsDelegate<Object>> delegates = [
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ];

  /// Resolves to Dominican Spanish unless the device explicitly prefers
  /// English. The product is Spanish-first; English exists for reviewers.
  static Locale? resolve(List<Locale>? deviceLocales, Iterable<Locale> supported) {
    if (deviceLocales == null || deviceLocales.isEmpty) return spanishDominican;
    for (final locale in deviceLocales) {
      if (locale.languageCode == 'es') return spanishDominican;
      if (locale.languageCode == 'en') return english;
    }
    return spanishDominican;
  }
}
