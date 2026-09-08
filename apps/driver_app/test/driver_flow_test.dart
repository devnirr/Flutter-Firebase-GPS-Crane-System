import 'package:driver_app/app.dart';
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

  Widget harness(DemoBackend backend) => ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(config),
          ...demoOverrides(
            backend: backend,
            role: UserRole.driver,
            actingAs: 'driver-1',
          ),
        ],
        child: const DriverApp(),
      );

  testWidgets('a signed-out chofer sees login and no way to register',
      (tester) async {
    await tester.pumpWidget(harness(DemoBackend()..seed()));
    await tester.pumpAndSettle();

    expect(find.text('ACCESO CHOFER'), findsOneWidget);
    expect(find.text('ENTRAR'), findsOneWidget);
    // Self-registration must not exist anywhere in this product.
    expect(find.textContaining('Registr'), findsNothing);
    expect(find.textContaining('Crear cuenta'), findsNothing);
  });

  testWidgets('signing in reaches the home screen with the online switch',
      (tester) async {
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

    expect(find.textContaining('línea'), findsWidgets);
    expect(find.text('PEDIDOS DISPONIBLES'), findsOneWidget);
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

    final drivers = container.read(driverRepositoryProvider);
    expect((await drivers.setOnline('driver-1', online: true)).isOk, isTrue);

    // Put a chofer on a job the way dispatch would.
    final assigned = await _dispatchedService(backend);
    final busyDriverId = assigned.driverId!;

    final refused = await drivers.setOnline(busyDriverId, online: false);
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
