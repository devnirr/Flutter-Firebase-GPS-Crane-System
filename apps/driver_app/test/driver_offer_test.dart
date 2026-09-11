import 'dart:async';

import 'package:clock/clock.dart';
import 'package:driver_app/app.dart';
import 'package:driver_app/features/home/driver_map.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:intl/date_symbol_data_local.dart';

/// The chofer's map and the request that takes it over.
///
/// The demo cascade assigns choferes directly and never sends an offer, so
/// these hand the app one the way Firestore would: through the stream the
/// home screen watches.
Future<void> main() async {
  setUpAll(() => initializeDateFormatting('es_DO'));

  const config = AppConfig(
    flavor: Flavor.dev,
    appKind: AppKind.driver,
    firebaseProjectId: 'grua-rd-test',
    googleMapsApiKey: '',
    stripePublishableKey: '',
    useEmulators: false,
    emulatorHost: 'localhost',
    functionsRegion: 'us-east1',
  );

  const here = LatLng(18.4795, -69.9420); // Gazcue
  const customer = LatLng(18.4712, -69.9061); // Naco
  const garage = LatLng(18.5001, -69.8800);

  Offer offerFor({Duration left = const Duration(seconds: 25)}) => Offer(
        serviceId: 'svc-offer-1',
        driverId: 'driver-1',
        serviceCode: 'GR-260911-0512',
        pickupAddress: 'Av. Abraham Lincoln 1003',
        pickupReference: 'Frente a la farmacia',
        dropoffAddress: 'Taller Hermanos Pérez',
        pickupGeo: customer,
        dropoffGeo: garage,
        vehicleLabel: 'Toyota Corolla 2018',
        condition: VehicleCondition.noArranca,
        netEarningsCents: 187500,
        grossCents: 250000,
        distanceMeters: 4100,
        etaSeconds: 540,
        // The test's clock, which `pump` moves, not the wall clock.
        expiresAt: clock.now().toUtc().add(left),
      );

  Widget harness({Offer? offer, MyFix? position}) => ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(config),
          ...demoOverrides(
            backend: DemoBackend()..seed(),
            role: UserRole.driver,
            actingAs: 'driver-1',
          ),
          incomingOfferProvider.overrideWith((ref) => Stream.value(offer)),
          myPositionProvider.overrideWith((ref) => Stream.value(position)),
        ],
        child: const DriverApp(),
      );

  Future<void> signIn(WidgetTester tester) async {
    await tester.enterText(find.byType(TextFormField).first, 'driver1@gruasrd.do');
    await tester.enterText(find.byType(TextFormField).last, 'secret123');
    await tester.pumpAndSettle();
    await tester.tap(find.text('ENTRAR'));
    // Not pumpAndSettle once an offer is up: its countdown repaints forever.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// The markers the home map was last built with.
  List<MapMarker> markersOnMap(WidgetTester tester) =>
      tester.widget<GruaMap>(find.byType(GruaMap)).markers;

  testWidgets('the home screen shows the chofer on a map', (tester) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(430, 1100);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness(position: (position: here, heading: 90)));
    await tester.pumpAndSettle();
    await signIn(tester);
    await tester.pumpAndSettle();

    expect(find.byType(DriverMap), findsOneWidget);
    final markers = markersOnMap(tester);
    expect(markers, hasLength(1));
    expect(markers.single.position, here);
    expect(markers.single.label, 'Tú');
    // "You are here" is the red drop.
    expect(markers.single.kind, MapMarkerKind.me);
    expect(find.byTooltip('Centrar en mi ubicación'), findsOneWidget);
    expect(find.text('NUEVA SOLICITUD'), findsNothing);
  });

  testWidgets('a request puts the customer, the destination and both legs on '
      'the map', (tester) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(430, 1400);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      harness(offer: offerFor(), position: (position: here, heading: 0)),
    );
    await tester.pump();
    await signIn(tester);

    final map = tester.widget<GruaMap>(find.byType(GruaMap));
    // Red for the chofer, blue for the customer: never two red pins.
    expect(
      {for (final m in map.markers) m.label: m.kind},
      {
        'Tú': MapMarkerKind.me,
        'Cliente': MapMarkerKind.customer,
        'Destino': MapMarkerKind.dropoff,
      },
    );
    // The whole job is framed, not just the truck.
    expect(map.fitTo, containsAll(<LatLng>[here, customer, garage]));
    // Road to the customer, then the tow. With no Maps key in a test both are
    // the straight fallback, which the map labels as approximate.
    expect(map.routes, hasLength(2));
    expect(map.routes.last.points.first, routeGrain(here));
    expect(map.routes.last.points.last, customer);
    expect(find.text('Ruta aproximada'), findsOneWidget);

    // The card under it: what they take home and where it goes.
    expect(find.text('NUEVA SOLICITUD'), findsOneWidget);
    expect(find.text(187500.formatDOP), findsOneWidget);
    expect(find.text('Av. Abraham Lincoln 1003'), findsOneWidget);
    expect(find.text('Taller Hermanos Pérez'), findsOneWidget);
    expect(find.text('ACEPTAR'), findsOneWidget);
    expect(find.text('RECHAZAR'), findsOneWidget);
  });

  testWidgets('a request that lapses leaves on its own', (tester) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(430, 1400);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      harness(
        offer: offerFor(left: const Duration(seconds: 3)),
        position: (position: here, heading: 0),
      ),
    );
    await tester.pump();
    await signIn(tester);
    expect(find.text('NUEVA SOLICITUD'), findsOneWidget);

    // The stream still says "sent"; the app's own clock takes it down.
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();

    expect(find.text('NUEVA SOLICITUD'), findsNothing);
    expect(markersOnMap(tester).map((m) => m.label), ['Tú']);
  });
}
