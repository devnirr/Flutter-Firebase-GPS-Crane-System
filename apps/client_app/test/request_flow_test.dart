import 'package:client_app/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:intl/date_symbol_data_local.dart';

/// End-to-end smoke tests over the in-memory backend.
///
/// These run the real widget tree, the real router redirects and the real
/// state machine — only the transport is swapped. That is the point of the demo
/// backend: a test that stubs the controllers proves the stubs work.
Future<void> main() async {
  setUpAll(() => initializeDateFormatting('es_DO'));

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
        ],
        child: const ClientApp(),
      );

  testWidgets('an unauthenticated cold start lands on the welcome screen',
      (tester) async {
    await tester.pumpWidget(harness(DemoBackend()..seed()));
    await tester.pumpAndSettle();

    expect(find.text('Entrar con teléfono'), findsOneWidget);
    expect(find.text('Registrarme'), findsOneWidget);
  });

  testWidgets('phone sign-in reaches the home screen', (tester) async {
    await tester.pumpWidget(harness(DemoBackend()..seed()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Entrar con teléfono'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, '8095551234');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Enviar código'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Any six digits are accepted by the demo auth repository.
    await tester.enterText(find.byType(TextField).first, '123456');
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('PEDIR GRÚA 24/7'), findsOneWidget);
  });

  test('a short verification code is rejected with a specific message', () async {
    // A plain test, not testWidgets: the demo repository simulates latency with
    // a real Future.delayed, and testWidgets' fake async never advances it
    // unless the tester pumps — the await would hang forever.
    final container = ProviderContainer(
      overrides: demoOverrides(backend: DemoBackend()..seed()),
    );
    addTearDown(container.dispose);

    final auth = container.read(authRepositoryProvider);
    await auth.startPhoneVerification('+18095551234');

    final tooShort = await auth.confirmSmsCode(
      verificationId: 'demo-verification-id',
      smsCode: '12345',
    );
    expect(tooShort.isErr, isTrue);
    expect(tooShort.failureOrNull?.code, FailureCode.invalidInput);
    expect(tooShort.failureOrNull?.userMessage, contains('6 dígitos'));

    final valid = await auth.confirmSmsCode(
      verificationId: 'demo-verification-id',
      smsCode: '123456',
    );
    expect(valid.isOk, isTrue);
    expect(auth.currentUserId, isNotNull);
  });

  test('a request is refused while the customer already has one in flight',
      () async {
    final container = ProviderContainer(
      overrides: demoOverrides(backend: DemoBackend()..seed()),
    );
    addTearDown(container.dispose);

    const pickup = ServiceLocation(
      geo: DoLocations.santoDomingo,
      address: 'Av. 27 de Febrero',
      reference: 'Frente al colmado',
    );
    const dropoff = ServiceLocation(
      geo: DoLocations.sanPedro,
      address: 'Taller Hermanos Pérez',
    );
    const vehicle = ServiceVehicle(
      make: 'Toyota',
      model: 'Corolla',
      condition: VehicleCondition.noArranca,
    );

    final gateway = container.read(functionsGatewayProvider);
    final quote = await gateway.quoteService(
      pickup: pickup,
      dropoff: dropoff,
      vehicle: vehicle,
    );
    expect(quote.isOk, isTrue);
    // A gancho tow of this distance must cost something.
    expect(quote.valueOrNull!.quote.totalCents, greaterThan(0));
    expect(quote.valueOrNull!.truckType, TruckType.gancho);

    final first = await gateway.requestService(
      pickup: pickup,
      dropoff: dropoff,
      vehicle: vehicle,
      truckType: TruckType.gancho,
      paymentMethod: PaymentMethod.cash,
      quoteSignature: quote.valueOrNull!.signature,
      quoteExpiresAt: quote.valueOrNull!.expiresAt,
    );
    expect(first.isOk, isTrue);

    final second = await gateway.requestService(
      pickup: pickup,
      dropoff: dropoff,
      vehicle: vehicle,
      truckType: TruckType.gancho,
      paymentMethod: PaymentMethod.cash,
      quoteSignature: quote.valueOrNull!.signature,
      quoteExpiresAt: quote.valueOrNull!.expiresAt,
    );
    expect(second.isErr, isTrue);
    expect(
      second.failureOrNull?.code,
      FailureCode.alreadyHasActiveService,
    );
    // The existing service id rides along so the app can deep-link to it
    // instead of stranding the customer on a dead end.
    expect(second.failureOrNull?.details, first.valueOrNull);
  });

  test('a flatbed is required when the vehicle cannot roll', () async {
    const rolled = ServiceVehicle(condition: VehicleCondition.volcado);
    const flat = ServiceVehicle(condition: VehicleCondition.gomaPinchada);
    const truck = ServiceVehicle(
      type: VehicleType.camion,
      condition: VehicleCondition.noArranca,
    );

    expect(rolled.inferredTruckType, TruckType.plataforma);
    expect(flat.inferredTruckType, TruckType.gancho);
    expect(truck.inferredTruckType, TruckType.pesada);
  });
}
