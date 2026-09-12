import 'package:client_app/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Marking a point on the map, from the request form.
///
/// The bug this pins down: the map sat in a Stack whose only unpositioned
/// child was the 44-pixel centre pin, so the Stack took the pin's width and
/// the map came out as a thin strip down the middle of the screen with grey
/// either side.
Future<void> main() async {
  setUpAll(() => initializeDateFormatting('es_DO'));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const gazcue = LatLng(18.4795, -69.9420);
  const phone = Size(430, 900);

  Widget harness(DemoBackend backend) => ProviderScope(
    overrides: [
      appConfigProvider.overrideWithValue(
        const AppConfig(
          flavor: Flavor.dev,
          appKind: AppKind.client,
          firebaseProjectId: 'grua-rd-test',
          googleMapsApiKey: '',
          stripePublishableKey: '',
          useEmulators: false,
          emulatorHost: 'localhost',
          functionsRegion: 'us-east1',
        ),
      ),
      ...demoOverrides(backend: backend),
      myPositionProvider.overrideWith(
        (ref) => Stream.value((position: gazcue, heading: 0)),
      ),
      // No GPS and no geocoder in a widget test; the picker asks for both the
      // moment it opens.
      locationServiceProvider.overrideWithValue(_FakeLocation()),
    ],
    child: const ClientApp(),
  );

  Future<void> advance(WidgetTester tester, Duration by) async {
    final steps = by.inMilliseconds ~/ 250;
    for (var i = 0; i < steps; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  Future<void> signIn(WidgetTester tester) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = phone;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness(DemoBackend()..seed()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Entrar con Teléfono'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '8095551234');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enviar código'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.enterText(find.byType(TextField).first, '123456');
    await advance(tester, const Duration(seconds: 2));
  }

  /// Opens the request form and taps one of its two location fields.
  Future<void> openPicker(WidgetTester tester, String label) async {
    await tester.tap(find.text('PEDIR GRÚA 24/7'));
    await advance(tester, const Duration(seconds: 1));

    // The two fields are near the bottom of a long form, and a list that
    // long has not built them yet.
    await tester.scrollUntilVisible(
      find.text(label),
      300,
      // The form's own list, not the chip rows scrolling inside it.
      scrollable: find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await advance(tester, const Duration(seconds: 1));
  }

  /// What the map actually occupies once the picker is open.
  void expectMapFillsWidth(WidgetTester tester) {
    final map = tester.getRect(find.byType(GruaMap));
    expect(map.left, 0);
    expect(map.width, phone.width);
    // And it is the map, not a sliver of one.
    expect(map.height, greaterThan(200));
  }

  testWidgets('the pickup picker shows a full-width map', (tester) async {
    await signIn(tester);
    await openPicker(tester, 'PUNTO DE RECOGIDA');

    expect(find.text('¿Dónde estás?'), findsWidgets);
    expect(find.text('CONFIRMAR UBICACIÓN'), findsOneWidget);
    expectMapFillsWidth(tester);
  });

  testWidgets('the destination picker shows a full-width map', (tester) async {
    await signIn(tester);
    await openPicker(tester, 'DESTINO');

    expect(find.text('¿A dónde la llevamos?'), findsWidgets);
    expect(find.text('CONFIRMAR UBICACIÓN'), findsOneWidget);
    expectMapFillsWidth(tester);
  });
}

/// A phone that knows where it is and can name the place, so the picker gets
/// past its first frame without a platform channel.
class _FakeLocation extends LocationService {
  static const _here = LatLng(18.4795, -69.9420);
  static const _place = ResolvedPlace(
    position: _here,
    address: 'Av. 27 de Febrero, Santo Domingo',
  );

  @override
  Future<LocationBlocker> check({bool requireAlways = false}) async =>
      LocationBlocker.none;

  @override
  Future<LocationBlocker> request({bool requireAlways = false}) async =>
      LocationBlocker.none;

  @override
  Future<Result<ResolvedPlace>> currentPlace({
    Duration timeout = const Duration(seconds: 10),
    bool geocode = true,
  }) async => const Result.ok(_place);

  @override
  Future<ResolvedPlace> describe(LatLng point) async => _place;
}
