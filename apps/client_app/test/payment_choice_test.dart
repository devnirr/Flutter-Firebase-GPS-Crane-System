import 'package:client_app/features/payment/card_checkout.dart';
import 'package:client_app/features/payment/payment_choice_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:intl/date_symbol_data_local.dart';

/// "¿Cómo vas a pagar?" when the chofer arrives: card or cash, changeable
/// until the vehicle is loaded.
Future<void> main() async {
  setUpAll(() => initializeDateFormatting('es_DO'));

  late DemoBackend backend;
  late Service service;
  late int checkouts;

  Future<void> pumpCard(WidgetTester tester) async {
    backend = DemoBackend(dispatchDelay: const Duration(hours: 1))..seed();
    service = backend.createService(
      clientId: 'demo-client-1',
      pickup: const ServiceLocation(geo: LatLng(18.4795, -69.9420), address: 'Gazcue'),
      dropoff: const ServiceLocation(geo: LatLng(18.5001, -69.8800)),
      vehicle: const ServiceVehicle(make: 'Toyota', model: 'Corolla'),
      truckType: TruckType.gancho,
      paymentMethod: PaymentMethod.pending,
      quote: const Quote(totalCents: 250000),
      route: const ServiceRoute(distanceMeters: 8000),
    );
    final driver = backend.allDrivers
        .firstWhere((d) => d.truckType == TruckType.gancho && d.status.canWork && !d.isBusy);
    expect(backend.assignServiceManually(serviceId: service.id, driverId: driver.id), isNull);
    backend.transition(service.id, ServiceStatus.arrived, ServiceEventName.markArrived,
        driver.id, UserRole.driver);

    checkouts = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...demoOverrides(backend: backend),
          currentUserIdProvider.overrideWithValue('demo-client-1'),
          cardCheckoutProvider.overrideWithValue((context, payment) async {
            checkouts++;
            return CheckoutOutcome.completed;
          }),
        ],
        child: MaterialApp(
          theme: AppTheme.phone(),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                final live = ref.watch(serviceByIdProvider(service.id)).value;
                return live == null
                    ? const SizedBox.shrink()
                    : SingleChildScrollView(child: PaymentChoiceCard(service: live));
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    backend.dispose();
    await tester.pump();
  }

  testWidgets('asks how to pay, with both ways offered', (tester) async {
    await pumpCard(tester);

    expect(find.text('¿Cómo vas a pagar?'), findsOneWidget);
    expect(find.byKey(const Key('pay-card')), findsOneWidget);
    expect(find.byKey(const Key('pay-cash')), findsOneWidget);

    await finish(tester);
  });

  testWidgets('"Pagar Efectivo" settles it as cash, and can be changed back', (tester) async {
    await pumpCard(tester);

    await tester.tap(find.byKey(const Key('pay-cash')));
    await settle(tester);

    expect(backend.service(service.id)!.payment.isCash, isTrue);
    expect(find.text('Pagarás en efectivo'), findsOneWidget);
    expect(find.text('Cambiar a tarjeta'), findsOneWidget);
    expect(checkouts, 0);

    await finish(tester);
  });

  testWidgets('"Pagar con Tarjeta" holds the card and says which one', (tester) async {
    await pumpCard(tester);

    await tester.tap(find.byKey(const Key('pay-card')));
    await settle(tester);

    final payment = backend.service(service.id)!.payment;
    expect(payment.isHeld, isTrue);
    expect(payment.blocksStart, isFalse);
    expect(find.text('Pagarás con Visa ••••4242'), findsOneWidget);
    // Demo mode holds the test card itself; Stripe's screen is not needed.
    expect(checkouts, 0);

    await finish(tester);
  });
}
