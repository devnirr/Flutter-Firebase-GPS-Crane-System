import 'dart:async';

import 'package:clock/clock.dart';
import 'package:driver_app/app.dart';
import 'package:driver_app/features/home/location_publisher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:intl/date_symbol_data_local.dart';

/// The bell, the banner, and the page they lead to.
///
/// What matters to a chofer: a request and a customer's message both show up
/// under the bell, a message also drops in as a banner wherever they are, and
/// every entry leads back to the thing it announced.
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

  Widget harness(
    DemoBackend backend, {
    Stream<Offer?>? offers,
  }) => ProviderScope(
    overrides: [
      appConfigProvider.overrideWithValue(config),
      ...demoOverrides(backend: backend, role: UserRole.driver),
      // A widget test has no GPS plugin to publish from.
      locationPublisherProvider.overrideWith((ref) => null),
      if (offers != null) incomingOfferProvider.overrideWith((ref) => offers),
    ],
    child: const DriverApp(),
  );

  Future<void> frames(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> signIn(WidgetTester tester) async {
    await tester.enterText(
      find.byType(TextFormField).first,
      'driver1@gruasrd.do',
    );
    await tester.enterText(find.byType(TextFormField).last, 'secret123');
    await tester.pump();
    await tester.tap(find.text('ENTRAR'));
    await frames(tester);
  }

  Finder bellCount(String count) => find.descendant(
    of: find.byKey(const Key('notifications-badge')),
    matching: find.text(count),
  );

  void useTallPhone(WidgetTester tester) {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(430, 1100);
    addTearDown(tester.view.reset);
  }

  testWidgets('the bell sits beside the header and opens the notification '
      'page', (tester) async {
    useTallPhone(tester);
    final backend = DemoBackend()
      ..seed()
      ..currentUserId = 'driver-1';
    await tester.pumpWidget(harness(backend));
    await tester.pump();
    await signIn(tester);

    // To the right of the header card, level with it.
    final bell = tester.getRect(find.byKey(const Key('notifications-button')));
    final avatar = tester.getRect(find.byType(DriverAvatar));
    expect(bell.left, greaterThan(avatar.right));
    expect(bell.center.dy, moreOrLessEquals(avatar.center.dy, epsilon: 2));

    await tester.tap(find.byKey(const Key('notifications-button')));
    await frames(tester);
    expect(find.text('Notificaciones'), findsOneWidget);
    expect(find.text('Sin notificaciones'), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await frames(tester);
    expect(find.text('Notificaciones'), findsNothing);
  });

  testWidgets('a request is counted on the bell and listed on the page', (
    tester,
  ) async {
    useTallPhone(tester);
    final offers = StreamController<Offer?>.broadcast();
    addTearDown(offers.close);

    final backend = DemoBackend()
      ..seed()
      ..currentUserId = 'driver-1';
    await tester.pumpWidget(harness(backend, offers: offers.stream));
    await tester.pump();
    await signIn(tester);

    offers.add(
      Offer(
        serviceId: 'svc-offer-1',
        driverId: 'driver-1',
        serviceCode: 'GR-260911-0512',
        pickupAddress: 'Av. Abraham Lincoln 1003',
        pickupGeo: const LatLng(18.4712, -69.9061),
        vehicleLabel: 'Toyota Corolla 2018',
        condition: VehicleCondition.noArranca,
        netEarningsCents: 187500,
        grossCents: 250000,
        distanceMeters: 4100,
        etaSeconds: 540,
        expiresAt: clock.now().toUtc().add(const Duration(seconds: 25)),
      ),
    );
    await frames(tester);

    expect(bellCount('1'), findsOneWidget);
    // The offer card is its own alert; no banner over it.
    expect(find.byKey(const Key('notification-toast')), findsNothing);

    await tester.tap(find.byKey(const Key('notifications-button')));
    await frames(tester);
    expect(find.text('Nueva solicitud de servicio'), findsOneWidget);

    // The entry leads back to the offer on the map.
    await tester.tap(find.text('Nueva solicitud de servicio'));
    await frames(tester);
    expect(find.text('Notificaciones'), findsNothing);
    expect(find.text('NUEVA SOLICITUD'), findsOneWidget);
    // Looked at, so the bell is clear.
    expect(bellCount('1'), findsNothing);
  });

  testWidgets('a customer message drops in as a banner that leads to the '
      'notification page and on to the chat', (tester) async {
    useTallPhone(tester);
    final backend = DemoBackend(dispatchDelay: const Duration(milliseconds: 20))
      ..seed();
    addTearDown(backend.dispose);

    final service = (await tester.runAsync(() => _dispatchedService(backend)))!;
    backend.currentUserId = service.driverId!;

    await tester.pumpWidget(harness(backend));
    await tester.pump();
    await signIn(tester);
    expect(find.text('EN SERVICIO'), findsOneWidget);

    backend.addMessage(
      service.id,
      ChatMessage(
        id: 'm-client-1',
        senderId: service.clientId,
        senderRole: UserRole.client,
        text: 'Estoy frente a la farmacia',
        sentAt: DateTime.now().toUtc(),
      ),
    );
    await frames(tester);

    expect(find.byKey(const Key('notification-toast')), findsOneWidget);
    expect(find.text('Mensaje de ${service.clientName}'), findsOneWidget);
    // The bell on the service screen counts it too.
    expect(bellCount('1'), findsOneWidget);

    // The banner opens the notification page.
    await tester.tap(find.byKey(const Key('notification-toast')));
    await frames(tester);
    expect(find.text('Notificaciones'), findsOneWidget);
    expect(find.byKey(const Key('notification-toast')), findsNothing);
    expect(find.text('Estoy frente a la farmacia'), findsOneWidget);

    // And the entry opens the conversation.
    await tester.tap(find.text('Estoy frente a la farmacia'));
    await frames(tester);
    expect(find.text('Voy en camino'), findsOneWidget);
    expect(find.text('Estoy frente a la farmacia'), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await frames(tester);
    await tester.tap(find.byType(BackButton));
    await frames(tester);
    expect(find.text('EN SERVICIO'), findsOneWidget);
    expect(bellCount('1'), findsNothing);
  });
}

/// Creates a service and waits for the simulated cascade to assign a chofer.
Future<Service> _dispatchedService(DemoBackend backend) async {
  final created = backend.createService(
    clientId: 'demo-client-1',
    pickup: const ServiceLocation(
      geo: DoLocations.santoDomingo,
      address: 'Av. 27 de Febrero',
    ),
    dropoff: const ServiceLocation(geo: DoLocations.sanPedro),
    vehicle: const ServiceVehicle(condition: VehicleCondition.noArranca),
    truckType: TruckType.gancho,
    paymentMethod: PaymentMethod.cash,
    quote: const Quote(totalCents: 250000),
    route: const ServiceRoute(distanceMeters: 12000),
  );

  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final current = backend.service(created.id);
    if (current != null && current.hasDriver) return current;
  }
  fail('the demo cascade never assigned a chofer');
}
