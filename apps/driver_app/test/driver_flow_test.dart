import 'dart:typed_data';

import 'package:driver_app/app.dart';
import 'package:driver_app/features/home/driver_map.dart';
import 'package:driver_app/features/home/location_publisher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:intl/date_symbol_data_local.dart';

/// Driver-side tests over the in-memory backend.
///
/// The lifecycle test is the important one: it walks a service through the real
/// transition guards rather than asserting on a stubbed controller, so a
/// regression in the state machine fails here.
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

  Widget harness(DemoBackend backend, {PhotoPicker? picker}) => ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(config),
          ...demoOverrides(
            backend: backend,
            role: UserRole.driver,
            actingAs: 'driver-1',
          ),
          if (picker != null) photoPickerProvider.overrideWithValue(picker),
          // An online chofer publishes their position, and a widget test has
          // no GPS plugin to publish from.
          locationPublisherProvider.overrideWith((ref) => null),
        ],
        child: const DriverApp(),
      );

  testWidgets('a signed-out chofer can open the registration form',
      (tester) async {
    await tester.pumpWidget(harness(DemoBackend()..seed()));
    await tester.pumpAndSettle();

    expect(find.text('ACCESO CHOFER'), findsOneWidget);
    expect(find.text('ENTRAR'), findsOneWidget);

    await tester.tap(find.text('REGISTRARSE'));
    await tester.pumpAndSettle();

    expect(find.text('Registro de chofer'), findsOneWidget);
    // The grúa is the office's to assign; nothing here lets a chofer pick one.
    expect(find.textContaining('Grúa'), findsNothing);
  });

  testWidgets('registering opens an inactive account that waits for review',
      (tester) async {
    final backend = DemoBackend()..seed();
    await tester.pumpWidget(
      harness(
        backend,
        picker: (_) async => PickedPhoto(
          name: 'licencia.jpg',
          bytes: Uint8List.fromList(List.filled(64, 7)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('REGISTRARSE'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Agregar foto'));
    await tester.tap(find.text('Agregar foto'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Elegir de la galería'));
    await tester.pumpAndSettle();
    expect(find.text('Cambiar foto'), findsOneWidget);

    Future<void> type(String hint, String value) =>
        tester.enterText(find.widgetWithText(TextFormField, hint), value);

    await type('Juan Alberto Pérez Núñez', 'Wilfredo Antonio Reyes');
    await type('001-1234567-8', '40200123459');
    await type('(809) 555-1234', '8295557788');
    await type('tucorreo@ejemplo.com', 'wilfredo@gruasrd.do');
    await type('Mínimo 8 caracteres', 'clave-segura-1');
    await type('Repite la contraseña', 'clave-segura-1');
    await type('Como aparece en la licencia', 'L-884213');
    await tester.pumpAndSettle();

    // The expiry is a date picker: open it and take the default, a year out.
    await tester.ensureVisible(find.text('dd/mm/aaaa'));
    await tester.tap(find.text('dd/mm/aaaa'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ACEPTAR'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Subir foto'));
    await tester.tap(find.text('Subir foto'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Elegir de la galería'));
    await tester.pumpAndSettle();
    expect(find.text('licencia.jpg'), findsOneWidget);

    await tester.ensureVisible(find.text('ENVIAR REGISTRO'));
    await tester.tap(find.text('ENVIAR REGISTRO'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final created =
        backend.allDrivers.firstWhere((d) => d.cedula == '40200123459');
    expect(created.status, DriverStatus.inactive);
    expect(created.createdBy, created.id);
    expect(created.mustChangePassword, isFalse);

    // Signed straight in, and parked on the review screen rather than home.
    expect(find.text('Solicitud en revisión'), findsOneWidget);
    expect(find.text('PEDIDOS DISPONIBLES'), findsNothing);

    // Let the uploads that run after sign-in finish.
    await tester.pump(const Duration(seconds: 3));

    // The profile photo landed on the record the office's roster draws from.
    expect(backend.driver(created.id)?.photoUrl, startsWith('data:image/jpeg'));
  });

  testWidgets('the registration form refuses a bad cédula and a mismatch',
      (tester) async {
    final backend = DemoBackend()..seed();
    final before = backend.allDrivers.length;
    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await tester.tap(find.text('REGISTRARSE'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, '001-1234567-8'),
      '40200123450',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Mínimo 8 caracteres'),
      'clave-segura-1',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Repite la contraseña'),
      'otra-clave-22',
    );
    await tester.ensureVisible(find.text('ENVIAR REGISTRO'));
    await tester.tap(find.text('ENVIAR REGISTRO'));
    await tester.pumpAndSettle();

    expect(find.text('Esa cédula no es válida.'), findsOneWidget);
    expect(find.text('Las contraseñas no coinciden.'), findsOneWidget);
    expect(find.text('Sube la foto de la licencia.'), findsOneWidget);
    expect(find.text('Agrega tu foto de perfil.'), findsOneWidget);
    expect(backend.allDrivers.length, before);
  });

  testWidgets('signing in reaches the home screen', (tester) async {
    await tester.pumpWidget(harness(DemoBackend()..seed()));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextFormField).first,
      'driver1@gruasrd.do',
    );
    await tester.enterText(find.byType(TextFormField).last, 'secret123');
    await tester.pumpAndSettle();

    await tester.tap(find.text('ENTRAR'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.byType(DriverMap), findsOneWidget);

    // The open work has its own tab now.
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Pedidos'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('PEDIDOS DISPONIBLES'), findsOneWidget);
  });

  testWidgets('signing in shows the office the chofer is connected, and '
      'signing out takes it back', (tester) async {
    final backend = DemoBackend()..seed();
    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    expect(backend.isAppOpen('driver-1'), isFalse);

    await tester.enterText(
      find.byType(TextFormField).first,
      'driver1@gruasrd.do',
    );
    await tester.enterText(find.byType(TextFormField).last, 'secret123');
    await tester.pumpAndSettle();
    await tester.tap(find.text('ENTRAR'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(backend.isAppOpen('driver-1'), isTrue);

    // Signing out lives on the Perfil tab.
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Perfil'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('sign-out')),
      200,
      scrollable: find.descendant(
        of: find.byKey(const Key('profile-list')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(find.byKey(const Key('sign-out')));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('ENTRAR'), findsOneWidget);
    expect(backend.isAppOpen('driver-1'), isFalse);
  });

  testWidgets('opening the app puts the chofer online, and closing it takes '
      'them off', (tester) async {
    // The bug: a switch. A chofer who opened the app and forgot to flip it
    // sat on the roadside invisible to dispatch; one who closed the app
    // without flipping it back stayed "En línea" on the office map with
    // nobody holding the phone.
    final backend = DemoBackend()
      ..seed()
      ..setDriverOnline('driver-1', online: false);
    expect(backend.driver('driver-1')!.canGoOnline, isTrue);

    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextFormField).first,
      'driver1@gruasrd.do',
    );
    await tester.enterText(find.byType(TextFormField).last, 'secret123');
    await tester.pumpAndSettle();
    await tester.tap(find.text('ENTRAR'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Online by itself, with nothing to press — and nothing on screen saying
    // so, since it is the normal state.
    expect(backend.driver('driver-1')!.isOnline, isTrue);
    expect(find.byType(Switch), findsNothing);
    expect(find.text('En línea'), findsNothing);

    // The app closes: the whole widget tree goes, and with it the presence
    // connection — which is all the server has to go on.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();

    expect(backend.isAppOpen('driver-1'), isFalse);
    expect(backend.driver('driver-1')!.isOnline, isFalse);
  });

  testWidgets('a chofer with no grúa is told why instead of going online',
      (tester) async {
    final backend = DemoBackend()..seed();
    final driver = backend.driver('driver-1')!;
    // The office takes the grúa away: the chofer keeps the account and the
    // app, and has nothing to go online with.
    expect(backend.archiveTruck(driver.assignedTruckId!), isNull);
    expect(backend.driver('driver-1')!.canGoOnline, isFalse);

    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextFormField).first,
      'driver1@gruasrd.do',
    );
    await tester.enterText(find.byType(TextFormField).last, 'secret123');
    await tester.pumpAndSettle();
    await tester.tap(find.text('ENTRAR'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // The one case the home screen speaks up: offline, and why.
    expect(backend.driver('driver-1')!.isOnline, isFalse);
    expect(find.byKey(const Key('online-blocked')), findsOneWidget);
    expect(find.textContaining('No tienes una grúa asignada'), findsOneWidget);
  });

  test('closing the app mid-tow leaves the chofer online', () async {
    // The customer is watching that truck; losing the app for a moment must
    // not make it vanish from their map. If the phone is really gone, the
    // stale-position sweep tells the office.
    final backend = DemoBackend(dispatchDelay: const Duration(milliseconds: 20))
      ..seed()
      ..setAppOpen('driver-1', open: true);
    final driver = backend.driver('driver-1')!;
    expect(driver.isOnline, isTrue);

    backend.createService(
      clientId: 'demo-client-1',
      pickup: const ServiceLocation(geo: LatLng(18.4795, -69.9420)),
      dropoff: const ServiceLocation(geo: LatLng(18.5001, -69.8800)),
      vehicle: const ServiceVehicle(condition: VehicleCondition.noArranca),
      truckType: driver.truckType,
      paymentMethod: PaymentMethod.cash,
      quote: const Quote(totalCents: 250000),
      route: const ServiceRoute(distanceMeters: 8000),
      preferredDriverId: 'driver-1',
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(backend.driver('driver-1')!.isBusy, isTrue);

    backend.setAppOpen('driver-1', open: false);

    expect(backend.driver('driver-1')!.isOnline, isTrue);
    backend.dispose();
  });

  test('a chofer cannot go offline while holding a job', () async {
    final backend = DemoBackend(dispatchDelay: const Duration(milliseconds: 20))
      ..seed();
    final container = ProviderContainer(
      overrides: demoOverrides(
        backend: backend,
        role: UserRole.driver,
        actingAs: 'driver-1',
      ),
    );
    addTearDown(container.dispose);

    final gateway = container.read(functionsGatewayProvider);
    expect((await gateway.setOnline(online: true)).isOk, isTrue);

    // Put a chofer on a job the way dispatch would, then act as them.
    final assigned = await _dispatchedService(backend);
    backend.currentUserId = assigned.driverId!;

    final refused = await gateway.setOnline(online: false);
    expect(refused.isErr, isTrue);
    expect(refused.failureOrNull?.code, FailureCode.driverBusy);
    expect(refused.failureOrNull?.userMessage, contains('servicio en curso'));
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('the service lifecycle enforces its guards in order', () async {
    final backend = DemoBackend(dispatchDelay: const Duration(milliseconds: 20))
      ..seed();
    final container = ProviderContainer(
      overrides: demoOverrides(backend: backend, role: UserRole.driver),
    );
    addTearDown(container.dispose);

    const pickup = ServiceLocation(
      geo: DoLocations.santoDomingo,
      address: 'Av. 27 de Febrero',
    );
    final service = await _dispatchedService(backend);
    expect(service.driverId, isNotNull);

    final gateway = container.read(functionsGatewayProvider);
    backend.currentUserId = service.driverId!;

    // "Llegué" from far away is refused, and the refusal says how far.
    final tooFar = await gateway.markArrived(
      serviceId: service.id,
      position: DoLocations.puertoPlata,
    );
    expect(tooFar.isErr, isTrue);
    expect(tooFar.failureOrNull?.code, FailureCode.outOfRange);
    expect(tooFar.failureOrNull?.userMessage, contains('km'));

    // At the pickup it succeeds.
    expect(
      (await gateway.markArrived(serviceId: service.id, position: pickup.geo))
          .isOk,
      isTrue,
    );
    expect(backend.service(service.id)?.status, ServiceStatus.arrived);

    expect(
      (await gateway.startService(serviceId: service.id, photoPaths: const []))
          .isOk,
      isTrue,
    );
    expect(backend.service(service.id)?.status, ServiceStatus.inProgress);

    expect(
      (await gateway.completeService(
        serviceId: service.id,
        position: DoLocations.sanPedro,
        photoPaths: const [],
      ))
          .isOk,
      isTrue,
    );

    final completed = backend.service(service.id)!;
    expect(completed.status, ServiceStatus.completed);
    // A cash job leaves the money with the chofer until they confirm.
    expect(completed.payment.status, PaymentStatus.cashPending);

    expect(
      (await gateway.confirmCashCollected(
        serviceId: service.id,
        amountCents: completed.totalCents,
      ))
          .isOk,
      isTrue,
    );
    expect(backend.service(service.id)?.status, ServiceStatus.closed);

    // Completing the job must have freed the chofer and paid them.
    final driverId = completed.driverId!;
    expect(backend.driver(driverId)?.currentServiceId, isNull);
    final entries = backend.earningEntries(driverId);
    expect(entries.any((e) => e.serviceId == service.id), isTrue);
    final entry = entries.firstWhere((e) => e.serviceId == service.id);
    expect(entry.netCents, lessThan(entry.grossCents));
    // Cash means the chofer owes the company its commission, not the reverse.
    expect(entry.driverOwesCompany, isTrue);
  }, timeout: const Timeout(Duration(seconds: 30)));
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
