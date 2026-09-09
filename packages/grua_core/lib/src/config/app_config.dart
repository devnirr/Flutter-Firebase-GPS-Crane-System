import 'package:flutter/foundation.dart';

/// Which Firebase project / build variant this binary talks to.
enum Flavor {
  dev('dev', 'Grúas RD DEV'),
  stg('stg', 'Grúas RD STG'),
  prod('prod', 'Grúas RD');

  const Flavor(this.wire, this.appName);

  final String wire;
  final String appName;

  static Flavor fromWire(String value) => Flavor.values.firstWhere(
        (f) => f.wire == value,
        orElse: () => Flavor.dev,
      );

  bool get isProduction => this == Flavor.prod;
}

/// Which of the three products this binary is.
enum AppKind { client, driver, admin }

/// Build-time configuration, supplied by `--dart-define-from-file=config/<flavor>.json`.
///
/// Nothing secret belongs here beyond public client keys: the Firebase web API
/// key and the Maps browser key are both restricted by referrer/package, and
/// the Stripe key is the publishable one. Anything that can move money or read
/// another user's data lives in Secret Manager and is only ever touched by a
/// Cloud Function.
@immutable
class AppConfig {
  const AppConfig({
    required this.flavor,
    required this.appKind,
    required this.firebaseProjectId,
    required this.googleMapsApiKey,
    required this.stripePublishableKey,
    required this.useEmulators,
    required this.emulatorHost,
    required this.functionsRegion,
    this.disableAppVerification = false,
  });

  /// Reads every value from the compile-time environment.
  ///
  /// Defaults are deliberately dev-shaped so `flutter run` works with no
  /// arguments during development, and a missing production define fails loudly
  /// in [assertProductionReady] rather than silently pointing at dev.
  factory AppConfig.fromEnvironment(AppKind appKind) {
    const flavorName = String.fromEnvironment('FLAVOR', defaultValue: 'dev');
    return AppConfig(
      flavor: Flavor.fromWire(flavorName),
      appKind: appKind,
      firebaseProjectId: const String.fromEnvironment(
        'FIREBASE_PROJECT_ID',
        defaultValue: 'grua-rd-dev',
      ),
      googleMapsApiKey: const String.fromEnvironment('GOOGLE_MAPS_API_KEY'),
      stripePublishableKey: const String.fromEnvironment('STRIPE_PUBLISHABLE_KEY'),
      useEmulators: const bool.fromEnvironment('USE_EMULATORS'),
      // Deliberately ANDed with kDebugMode rather than just read: a release
      // binary that skips reCAPTCHA and Play Integrity would let anyone mint
      // an SMS code for a number they do not own, so the define cannot turn
      // this on outside a debug build no matter how the build is invoked.
      disableAppVerification: kDebugMode &&
          const bool.fromEnvironment('DISABLE_APP_VERIFICATION'),
      emulatorHost: const String.fromEnvironment(
        'EMULATOR_HOST',
        // 10.0.2.2 is the host loopback as seen from the Android emulator.
        defaultValue: 'localhost',
      ),
      functionsRegion: const String.fromEnvironment(
        'FUNCTIONS_REGION',
        defaultValue: 'us-east1',
      ),
    );
  }

  final Flavor flavor;
  final AppKind appKind;
  final String firebaseProjectId;
  final String googleMapsApiKey;
  final String stripePublishableKey;
  final bool useEmulators;

  /// Skips SMS app verification so the phone numbers registered under
  /// Authentication > Sign-in method > Phone > "Phone numbers for testing"
  /// sign in with their fixed code and no reCAPTCHA or Play Integrity check.
  ///
  /// Debug builds only, and opt-in with
  /// `--dart-define=DISABLE_APP_VERIFICATION=true`.
  final bool disableAppVerification;
  final String emulatorHost;
  final String functionsRegion;

  bool get showDebugTools => !flavor.isProduction;

  /// Emulator ports, matching firebase.json.
  static const int authEmulatorPort = 9099;
  static const int firestoreEmulatorPort = 8080;
  static const int databaseEmulatorPort = 9000;
  static const int functionsEmulatorPort = 5001;
  static const int storageEmulatorPort = 9199;

  /// Throws if a release build is missing something it cannot work without.
  void assertProductionReady() {
    if (!flavor.isProduction) return;
    final missing = <String>[
      if (googleMapsApiKey.isEmpty) 'GOOGLE_MAPS_API_KEY',
      if (stripePublishableKey.isEmpty) 'STRIPE_PUBLISHABLE_KEY',
      if (firebaseProjectId.endsWith('-dev')) 'FIREBASE_PROJECT_ID (points at dev)',
    ];
    if (missing.isNotEmpty) {
      throw StateError(
        'Production build is missing required configuration: ${missing.join(', ')}. '
        'Pass --dart-define-from-file=config/prod.json.',
      );
    }
    if (useEmulators) {
      throw StateError('USE_EMULATORS must never be true in a production build.');
    }
    // Unreachable while the flag is gated on kDebugMode, kept so the guard
    // survives anyone loosening that gate.
    if (disableAppVerification) {
      throw StateError(
        'DISABLE_APP_VERIFICATION must never be true in a production build.',
      );
    }
  }

  @override
  String toString() =>
      'AppConfig(${flavor.wire}, ${appKind.name}, $firebaseProjectId, '
      'emulators: $useEmulators)';
}
