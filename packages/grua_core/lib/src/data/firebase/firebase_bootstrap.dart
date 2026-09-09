import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../../config/app_config.dart';
import '../../providers.dart';
import 'firebase_repositories.dart';
import 'functions_gateway.dart';

/// Brings Firebase up and binds the real repositories.
///
/// Kept separate from `runGruaApp` so a build with no Firebase configuration
/// still runs: `initializeFirebase` reports whether it succeeded, and the
/// caller falls back to the in-memory backend rather than showing a crash to
/// somebody who just cloned the repo.
abstract final class FirebaseBootstrap {
  /// True once [initialize] has connected successfully.
  static bool get isReady => _ready;
  static bool _ready = false;

  /// Initializes Firebase and, in a dev build, points the SDKs at the local
  /// emulator suite.
  ///
  /// Returns false rather than throwing when there is no configuration. A
  /// missing `firebase_options.dart` is the normal state of a fresh clone, not
  /// an error worth a crash screen.
  static Future<bool> initialize({
    required AppConfig config,
    FirebaseOptions? options,
  }) async {
    if (_ready) return true;

    try {
      await Firebase.initializeApp(options: options);
    } on Object catch (error) {
      debugPrint(
        'Firebase not configured ($error). '
        'Running against the in-memory demo backend instead. '
        'Run `flutterfire configure` to connect a project.',
      );
      return false;
    }

    if (config.useEmulators) await _useEmulators(config);

    // Lets the console's test phone numbers through with their fixed code and
    // no reCAPTCHA (web) or Play Integrity (Android) round trip. Debug builds
    // only - see AppConfig.disableAppVerification.
    if (config.disableAppVerification) {
      await FirebaseAuth.instance.setSettings(
        appVerificationDisabledForTesting: true,
      );
    }
    // Said out loud either way: "I passed the define" and "the define reached
    // the build" are different claims, and only this line settles it.
    if (kDebugMode) {
      debugPrint(
        '[grua] SMS app verification: '
        '${config.disableAppVerification ? "DISABLED (test numbers)" : "enabled"}',
      );
    }

    // Offline persistence is not a nicety here. A customer requesting a tow is
    // frequently on a highway with one bar, and a chofer's app must keep
    // rendering the job it already has when the signal drops.
    if (!kIsWeb) {
      FirebaseFirestore.instance.settings = const Settings(
        persistenceEnabled: true,
        cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
      );
    } else {
      // On the web, Firestore's default transport is WebChannel: one long-lived
      // streaming connection per listener. Plenty of networks between here and
      // Google — corporate proxies, some antivirus TLS inspectors, a few
      // Dominican ISPs, and anything doing IPv6 badly — accept the handshake
      // and then never deliver the stream, which the browser eventually reports
      // as ERR_CONNECTION_TIMED_OUT. The snapshot listener simply never fires,
      // so every screen sits on its spinner with nothing in the logs but a
      // timeout.
      //
      // Auto-detect gives the SDK one attempt at WebChannel and falls back to
      // long polling — ordinary XHR round trips, which those middleboxes pass —
      // when it does not come up. Forcing it outright would cost the office a
      // slower, chattier connection on networks where streaming works fine.
      FirebaseFirestore.instance.settings = const Settings(
        webExperimentalAutoDetectLongPolling: true,
      );
    }

    _ready = true;
    return true;
  }

  static Future<void> _useEmulators(AppConfig config) async {
    final host = config.emulatorHost;
    debugPrint('Using Firebase emulators at $host');

    await FirebaseAuth.instance
        .useAuthEmulator(host, AppConfig.authEmulatorPort);

    FirebaseFirestore.instance
        .useFirestoreEmulator(host, AppConfig.firestoreEmulatorPort);

    FirebaseDatabase.instance
        .useDatabaseEmulator(host, AppConfig.databaseEmulatorPort);

    FirebaseFunctions.instanceFor(region: config.functionsRegion)
        .useFunctionsEmulator(host, AppConfig.functionsEmulatorPort);

    await FirebaseStorage.instance
        .useStorageEmulator(host, AppConfig.storageEmulatorPort);
  }

  /// Binds every repository to Firebase.
  ///
  /// The shape mirrors `demoOverrides` exactly, which is the point: the two are
  /// interchangeable, and no screen can tell which one it is running against.
  static List<Override> overrides(AppConfig config) {
    final gateway = FirebaseFunctionsGateway(region: config.functionsRegion);

    return [
      authRepositoryProvider.overrideWithValue(FirebaseAuthRepository()),
      userRepositoryProvider
          .overrideWithValue(const FirestoreUserRepository()),
      driverRepositoryProvider.overrideWithValue(FirebaseDriverRepository()),
      truckRepositoryProvider
          .overrideWithValue(const FirestoreTruckRepository()),
      serviceRepositoryProvider
          .overrideWithValue(const FirestoreServiceRepository()),
      offerRepositoryProvider
          .overrideWithValue(const FirestoreOfferRepository()),
      chatRepositoryProvider.overrideWithValue(const FirestoreChatRepository()),
      earningsRepositoryProvider
          .overrideWithValue(const FirestoreEarningsRepository()),
      invoiceRepositoryProvider
          .overrideWithValue(FirestoreInvoiceRepository(gateway: gateway)),
      configRepositoryProvider
          .overrideWithValue(const FirestoreConfigRepository()),
      functionsGatewayProvider.overrideWithValue(gateway),
    ];
  }
}
