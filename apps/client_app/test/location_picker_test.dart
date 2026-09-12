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
      // No network either: the suggestions come from here.
      placesServiceProvider.overrideWithValue(_FakePlaces()),
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

  testWidgets("the pickup is the phone's own position, and is not a button", (
    tester,
  ) async {
    await signIn(tester);

    // Reaching the field is the same journey; what it does when tapped is
    // what changed.
    await openPicker(tester, 'PUNTO DE RECOGIDA');

    // No picker opened: the form is still the form.
    expect(find.text('CONFIRMAR UBICACIÓN'), findsNothing);
    expect(find.text('PUNTO DE RECOGIDA'), findsOneWidget);

    // And it says where the phone is, geocoded — not a hardcoded avenue.
    expect(find.text('Av. 27 de Febrero, Santo Domingo'), findsOneWidget);

    // The landmark is the part the customer fills in.
    expect(find.byKey(const Key('pickup-reference')), findsOneWidget);
  });

  testWidgets('the destination picker shows a full-width map', (tester) async {
    await signIn(tester);
    await openPicker(tester, 'DESTINO');

    expect(find.text('¿A dónde la llevamos?'), findsWidgets);
    expect(find.text('CONFIRMAR UBICACIÓN'), findsOneWidget);
    expectMapFillsWidth(tester);
  });


  testWidgets('the destination picker opens on the position already known', (
    tester,
  ) async {
    await signIn(tester);
    await openPicker(tester, 'DESTINO');

    // Not the centre of Santo Domingo, which is where it used to start before
    // a fresh fix arrived seconds later: the home map's position is already
    // paid for, so the map opens there.
    final map = tester.widget<GruaMap>(find.byType(GruaMap));
    expect(map.center.latitude, closeTo(gazcue.latitude, 0.0001));
    expect(map.center.longitude, closeTo(gazcue.longitude, 0.0001));
  });

  testWidgets('typing a destination offers matches above the field', (
    tester,
  ) async {
    await signIn(tester);
    await openPicker(tester, 'DESTINO');

    // Nothing is offered for a single letter: it would match half the country.
    await tester.enterText(find.byKey(const Key('address-field')), 'W');
    await advance(tester, const Duration(milliseconds: 400));
    expect(find.byKey(const Key('address-suggestions')), findsNothing);

    await tester.enterText(find.byKey(const Key('address-field')), 'Winston');
    await advance(tester, const Duration(milliseconds: 400));

    // The list is there, and it sits above the field it belongs to.
    expect(find.byKey(const Key('address-suggestions')), findsOneWidget);
    expect(find.text('Av. Winston Churchill'), findsOneWidget);
    expect(find.text('Plaza Central'), findsOneWidget);
    expect(
      tester.getRect(find.byKey(const Key('address-suggestions'))).bottom,
      lessThanOrEqualTo(
        tester.getRect(find.byKey(const Key('address-field'))).top,
      ),
    );

    // Choosing one names the place, moves the map to it, and closes the list.
    await tester.tap(find.text('Av. Winston Churchill'));
    await advance(tester, const Duration(seconds: 1));

    expect(find.byKey(const Key('address-suggestions')), findsNothing);
    expect(find.text('Av. Winston Churchill, Piantini'), findsOneWidget);
    final map = tester.widget<GruaMap>(find.byType(GruaMap));
    expect(map.center.latitude, closeTo(18.4861, 0.0001));

    // And that is what the form gets back.
    await tester.tap(find.text('CONFIRMAR UBICACIÓN'));
    await advance(tester, const Duration(seconds: 1));
    expect(find.text('Av. Winston Churchill, Piantini'), findsWidgets);
  });
}

/// Suggestions without a network: the same two answers for anything typed.
class _FakePlaces extends PlacesService {
  _FakePlaces() : super(apiKey: 'test-key');

  @override
  Future<List<PlaceSuggestion>> suggest(
    String input, {
    LatLng? near,
    double radiusKm = 50,
  }) async {
    if (input.trim().length < 2) return const [];
    return const [
      PlaceSuggestion(
        placeId: 'place-1',
        title: 'Av. Winston Churchill',
        subtitle: 'Piantini, Santo Domingo',
      ),
      PlaceSuggestion(
        placeId: 'place-2',
        title: 'Plaza Central',
        subtitle: 'Av. 27 de Febrero, Santo Domingo',
      ),
    ];
  }

  @override
  Future<ResolvedPlace?> details(String placeId) async => const ResolvedPlace(
    position: LatLng(18.4861, -69.9312),
    address: 'Av. Winston Churchill, Piantini',
  );
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
