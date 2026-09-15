import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';

/// The demo backend signs anyone in who types four characters as a password,
/// so reaching it is a decision, never an accident. A build that ships
/// firebase_options.dart and cannot reach Firebase stops on an error screen
/// (see `runGruaApp`); these guard the flag that screen depends on.
void main() {
  AppConfig config({
    Flavor flavor = Flavor.dev,
    bool useDemoBackend = false,
  }) =>
      AppConfig(
        flavor: flavor,
        appKind: AppKind.driver,
        firebaseProjectId: 'gruasrd-ce2ae',
        googleMapsApiKey: 'key',
        stripePublishableKey: 'pk_live_x',
        useEmulators: false,
        useDemoBackend: useDemoBackend,
        emulatorHost: 'localhost',
        functionsRegion: 'us-east1',
      );

  test('the demo backend is off unless a build asks for it', () {
    expect(AppConfig.fromEnvironment(AppKind.driver).useDemoBackend, isFalse);
    expect(config().useDemoBackend, isFalse);
  });

  test('a production build refuses to ship the demo backend', () {
    expect(
      () => config(flavor: Flavor.prod, useDemoBackend: true)
          .assertProductionReady(),
      throwsStateError,
    );
    expect(config(flavor: Flavor.prod).assertProductionReady, returnsNormally);
  });
}
