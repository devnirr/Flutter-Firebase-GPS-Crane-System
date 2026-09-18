import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:intl/date_symbol_data_local.dart';

import 'config/app_config.dart';
import 'data/demo/demo_backend.dart';
import 'data/firebase/firebase_bootstrap.dart';
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
/// The data layer is chosen at startup, in this order:
///
/// 1. [backendOverrides], when a caller passes one — tests and demos do.
/// 2. The in-memory demo backend, with `--dart-define=USE_DEMO_BACKEND=true`.
/// 3. Firebase, when [firebaseOptions] is supplied.
/// 4. The in-memory demo backend, when there are no [firebaseOptions] at all.
///
/// A fresh clone has no `firebase_options.dart`, and somebody evaluating the
/// repo should see the product rather than a crash screen naming a CLI they
/// have not heard of. A build that does ship one is a different case: it means
/// to talk to a project, and the demo backend lets anybody in with any
/// password, so failing to reach Firebase stops on an error screen instead.
Future<void> runGruaApp({
  required AppKind appKind,
  required Widget Function() builder,
  UserRole demoRole = UserRole.client,
  List<Override> Function()? backendOverrides,
  FirebaseOptions? firebaseOptions,
  /// Anything an app wires on top of the shared providers, such as the
  /// panel's browser-backed theme-mode store.
  List<Override> appOverrides = const [],
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

      // The demo backend signs anyone in who types four characters as a
      // password, so it is only ever reached on purpose: a test harness, the
      // USE_DEMO_BACKEND define, or a clone with no firebase_options.dart to
      // pass. A build that ships one and cannot reach Firebase says so below
      // rather than turning into an app with no password check.
      final wantsDemo = backendOverrides != null || config.useDemoBackend;
      final usingFirebase = !wantsDemo &&
          await FirebaseBootstrap.initialize(
            config: config,
            options: firebaseOptions,
          );

      if (!wantsDemo && !usingFirebase && firebaseOptions != null) {
        runApp(
          _BackendUnavailableApp(
            error: FirebaseBootstrap.initializationError,
            flavor: config.flavor,
          ),
        );
        return;
      }

      final overrides = <Override>[
        appConfigProvider.overrideWithValue(config),
        ...appOverrides,
        if (backendOverrides != null)
          ...backendOverrides()
        else if (usingFirebase)
          ...FirebaseBootstrap.overrides(config)
        else
          // The demo app also gets an insurer's month to invoice, and the
          // driver app requests that arrive on their own.
          ...demoOverrides(role: demoRole, backend: _demoAppBackend(demoRole)),
      ];

      runApp(ProviderScope(overrides: overrides, child: builder()));
    },
    (error, stack) => debugPrint('Zone error: $error\n$stack'),
  );
}

DemoBackend _demoAppBackend(UserRole role) {
  final backend = DemoBackend()
    ..seed()
    ..seedInsurerHistory();
  if (role == UserRole.driver) backend.startRequestSimulator();
  return backend;
}

/// What a build configured for Firebase shows when it cannot reach it.
///
/// The alternative — the in-memory backend — would accept any email with any
/// password and then report that the account has no chofer, which reads as two
/// unrelated bugs instead of one connection that never came up.
class _BackendUnavailableApp extends StatelessWidget {
  const _BackendUnavailableApp({required this.error, required this.flavor});

  final Object? error;
  final Flavor flavor;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: BrandColors.white,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(Insets.xxl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.cloud_off_outlined,
                  size: 56,
                  color: BrandColors.red,
                ),
                const SizedBox(height: Insets.lg),
                Text(
                  'No pudimos conectar con el servidor',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: Insets.md),
                const Text(
                  'Revisa tu conexión y vuelve a abrir la app. Si el problema '
                  'sigue, avisa a la oficina.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: BrandColors.grey600),
                ),
                // The reason, where a tester can read it and nobody else is
                // looking: a production build says only that it failed.
                if (error != null && !flavor.isProduction) ...[
                  const SizedBox(height: Insets.lg),
                  Text(
                    '$error',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 11,
                      color: BrandColors.grey600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Frames a phone app inside a phone-sized viewport when it is previewed in a
/// desktop browser.
///
/// The phone products are portrait-locked and laid out for a thumb; stretched
/// across a 1920-px window they are unreviewable, and a reviewer would be
/// judging a layout the product never ships. Running them on web is the only
/// way to see them without an Android emulator, so the frame makes that
/// preview honest.
///
/// Call it from `MaterialApp.builder`, not around `MaterialApp`: the app
/// re-derives MediaQuery from the view at its root, so an override placed
/// outside it is discarded.
Widget webPhoneFrame(BuildContext context, Widget child) {
  if (!kIsWeb) return child;

  final media = MediaQuery.of(context);
  // A narrow browser is already phone-shaped — framing it again would just
  // shrink it.
  if (media.size.width <= 560) return child;

  const phone = Size(412, 880);

  return ColoredBox(
    color: BrandColors.sidebar,
    child: Center(
      child: SizedBox.fromSize(
        size: phone,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: MediaQuery(
            data: media.copyWith(
              size: phone,
              padding: EdgeInsets.zero,
              viewPadding: EdgeInsets.zero,
              viewInsets: EdgeInsets.zero,
            ),
            child: child,
          ),
        ),
      ),
    ),
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
