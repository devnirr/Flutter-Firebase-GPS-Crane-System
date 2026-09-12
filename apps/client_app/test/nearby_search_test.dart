import 'package:client_app/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// "Grúas cerca de ti": a real search, on a clock, that the customer can stop,
/// restart and reconfigure.
///
/// The demo fleet is seeded around Santo Domingo — four trucks in the city,
/// one in Santiago and one in Higüey — so the radius genuinely decides who is
/// found.
Future<void> main() async {
  setUpAll(() => initializeDateFormatting('es_DO'));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const gazcue = LatLng(18.4795, -69.9420);

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
        ],
        child: const ClientApp(),
      );

  /// Frames without settling: the countdown repaints every second for as
  /// long as the search runs.
  Future<void> advance(WidgetTester tester, Duration by) async {
    final steps = by.inMilliseconds ~/ 250;
    for (var i = 0; i < steps; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  Future<DemoBackend> signIn(WidgetTester tester) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(430, 900);
    addTearDown(tester.view.reset);

    final backend = DemoBackend()..seed();
    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Entrar con Teléfono'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '8095551234');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enviar código'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.enterText(find.byType(TextField).first, '123456');
    await advance(tester, const Duration(seconds: 2));
    return backend;
  }

  GruaMap homeMap(WidgetTester tester) => tester.widget<GruaMap>(find.byType(GruaMap));

  Iterable<MapMarker> trucksOn(GruaMap map) =>
      map.markers.where((m) => m.kind == MapMarkerKind.truckIdle);

  testWidgets('the search finds the free trucks inside the radius and puts '
      'them on the map', (tester) async {
    await signIn(tester);

    expect(find.textContaining('Buscando…'), findsOneWidget);

    final map = homeMap(tester);
    // The area searched, drawn and framed.
    expect(map.circles.single.center, gazcue);
    expect(map.circles.single.radiusMeters, 5000);
    expect(map.fitTo, isNotEmpty);

    // Found: only the ones really within 5 km of the customer.
    final found = trucksOn(map).toList();
    expect(found, isNotEmpty);
    for (final truck in found) {
      expect(truck.position.distanceTo(gazcue), lessThanOrEqualTo(5200));
    }
    expect(find.text('${found.length} grúas disponibles en 5 km'), findsOneWidget);
  });

  testWidgets('tapping stops the search, and tapping again starts it',
      (tester) async {
    await signIn(tester);
    final row = find.byKey(const Key('nearby-trucks-row'));

    await tester.tap(row);
    await advance(tester, const Duration(milliseconds: 500));
    expect(find.text('Buscar de nuevo'), findsOneWidget);
    // What was found stays on the map.
    expect(trucksOn(homeMap(tester)), isNotEmpty);

    await tester.tap(row);
    await advance(tester, const Duration(milliseconds: 500));
    expect(find.textContaining('Buscando…'), findsOneWidget);
  });

  testWidgets('the search ends on its own when its time is up', (tester) async {
    await signIn(tester);
    expect(find.textContaining('Buscando…'), findsOneWidget);

    // 30 s by default.
    await advance(tester, const Duration(seconds: 31));

    expect(find.text('Buscar de nuevo'), findsOneWidget);
  });

  testWidgets('tapping a truck shows it anonymously, and '
      '"Pedir esta grúa" opens the request with that truck first', (tester) async {
    await signIn(tester);

    final truck = trucksOn(homeMap(tester)).first;
    // Tappable, and labelled with nobody's name.
    expect(truck.onTap, isNotNull);
    expect(truck.label, isNull);

    truck.onTap!();
    await advance(tester, const Duration(seconds: 1));
    expect(find.text('Grúa disponible'), findsOneWidget);
    // Truck type and distance, e.g. "Plataforma · a 850 m de ti".
    expect(find.textContaining(' · a '), findsOneWidget);

    await tester.tap(find.byKey(const Key('truck-request')));
    await advance(tester, const Duration(seconds: 1));

    // The request form, carrying the choice.
    expect(find.text('Detalles del vehículo'), findsOneWidget);
    expect(find.byKey(const Key('preferred-truck-notice')), findsOneWidget);
  });

  testWidgets('"Chatear" asks that truck\'s chofer to talk, and the '
      'conversation opens when they accept', (tester) async {
    final backend = await signIn(tester);

    trucksOn(homeMap(tester)).first.onTap!();
    await advance(tester, const Duration(seconds: 1));

    await tester.tap(find.byKey(const Key('truck-chat')));
    await advance(tester, const Duration(seconds: 1));

    // A request went to that truck's chofer, and the customer waits for it.
    final request = backend.allChatRequests.single;
    expect(request.clientId, 'demo-client-1');
    expect(request.status, ChatRequestStatus.pending);
    expect(find.byKey(const Key('chat-request-waiting')), findsOneWidget);
    // Nobody's name until the chofer answers.
    expect(find.text('Chofer de la grúa'), findsOneWidget);

    backend.respondChatRequest(request.id, request.driverId, accept: true);
    await advance(tester, const Duration(seconds: 1));

    expect(find.byKey(const Key('chat-request-waiting')), findsNothing);
    expect(find.text('Escribe un mensaje…'), findsOneWidget);
    expect(find.text(backend.chatRequest(request.id)!.driverName), findsOneWidget);

    await tester.enterText(
      find.byType(TextField).last,
      '¿Cuánto cuesta el servicio?',
    );
    await tester.tap(find.byIcon(Icons.send));
    await advance(tester, const Duration(seconds: 1));
    final sent =
        (await tester.runAsync(() => backend.chatRequestMessagesFor(request.id).first))!;
    expect(sent.single.text, '¿Cuánto cuesta el servicio?');
    expect(sent.single.senderRole, UserRole.client);
  });

  testWidgets('the gear sets radius and duration, and searches again with them',
      (tester) async {
    await signIn(tester);

    await tester.tap(find.byTooltip('Ajustes de búsqueda'));
    await advance(tester, const Duration(seconds: 1));
    expect(find.text('Ajustes de búsqueda'), findsOneWidget);

    // Widest radius, shortest duration.
    await tester.drag(find.byKey(const Key('radius-slider')), const Offset(400, 0));
    await tester.drag(find.byKey(const Key('duration-slider')), const Offset(-400, 0));
    await tester.pump();
    expect(find.text('400 km'), findsOneWidget);
    expect(find.text('10 s'), findsOneWidget);

    await tester.tap(find.text('Guardar'));
    await advance(tester, const Duration(seconds: 1));

    expect(homeMap(tester).circles.single.radiusMeters, 400000);
    expect(find.textContaining('Buscando…'), findsOneWidget);
    // …and the new, shorter duration ends it.
    await advance(tester, const Duration(seconds: 11));
    expect(find.text('Buscar de nuevo'), findsOneWidget);

    // Remembered on the device.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('nearby.radiusKm'), 400);
    expect(prefs.getInt('nearby.durationSeconds'), 10);
  });
}
