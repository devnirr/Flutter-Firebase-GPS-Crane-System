import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';

/// Paying for a tow, on the in-memory backend that mirrors the callables.
///
/// The customer chooses card or cash once the chofer is at the curb; nobody
/// loads a vehicle before that is settled. Cash is marked paid by the chofer
/// and held by them for the office's corte; card money never passes through
/// the chofer at all.
void main() {
  const client = 'demo-client-1';
  const staff = 'demo-admin';

  late DemoBackend backend;
  late String driverId;
  late Service service;

  /// A job with its chofer standing at the pickup.
  void arrived({PaymentMethod method = PaymentMethod.pending}) {
    backend = DemoBackend(dispatchDelay: const Duration(hours: 1))..seed();
    service = backend.createService(
      clientId: client,
      pickup: const ServiceLocation(geo: LatLng(18.4795, -69.9420), address: 'Gazcue'),
      dropoff: const ServiceLocation(geo: LatLng(18.5001, -69.8800)),
      vehicle: const ServiceVehicle(condition: VehicleCondition.noArranca),
      truckType: TruckType.gancho,
      paymentMethod: method,
      quote: const Quote(totalCents: 250000),
      route: const ServiceRoute(distanceMeters: 8000),
    );
    driverId = backend.allDrivers
        .firstWhere((d) => d.truckType == TruckType.gancho && d.status.canWork && !d.isBusy)
        .id;
    expect(backend.assignServiceManually(serviceId: service.id, driverId: driverId), isNull);
    backend.transition(
      service.id,
      ServiceStatus.arrived,
      ServiceEventName.markArrived,
      driverId,
      UserRole.driver,
    );
  }

  Service current() => backend.service(service.id)!;

  tearDown(() => backend.dispose());

  test('nobody starts before the customer chooses how to pay', () {
    arrived();
    expect(current().payment.method, PaymentMethod.pending);
    expect(current().payment.blocksStart, isTrue);
  });

  test('a card held by the customer lets the chofer start', () {
    arrived();

    final held = backend.holdDemoCard(service.id, client);

    expect(held, isA<Ok<PreparedPayment>>());
    final payment = current().payment;
    expect(payment.isHeld, isTrue);
    expect(payment.cardLabel, 'Visa ••••4242');
    // The quote plus headroom for waiting, never less than the quote.
    expect(payment.authorizedCents, greaterThan(250000));
    expect(payment.blocksStart, isFalse);
  });

  test('only the customer can choose card; the chofer can mark cash', () {
    arrived();

    expect(
      backend.choosePaymentMethod(service.id, driverId, PaymentMethod.card),
      isA<Err<void>>(),
    );
    expect(
      backend.choosePaymentMethod(service.id, driverId, PaymentMethod.cash),
      isA<Ok<void>>(),
    );
    expect(current().payment.isCash, isTrue);
    expect(current().payment.blocksStart, isFalse);
  });

  test('switching a held card to cash lets go of the hold', () {
    arrived();
    backend.holdDemoCard(service.id, client);

    backend.choosePaymentMethod(service.id, client, PaymentMethod.cash);

    expect(current().payment.isCash, isTrue);
    expect(current().payment.authorizedCents, 0);
    expect(current().payment.intentId, isNull);
  });

  test('the choice is closed once the vehicle is loaded', () {
    arrived(method: PaymentMethod.cash);
    backend.transition(service.id, ServiceStatus.inProgress,
        ServiceEventName.startService, driverId, UserRole.driver);

    expect(
      backend.choosePaymentMethod(service.id, client, PaymentMethod.card),
      isA<Err<void>>(),
    );
  });

  group('cash and the corte', () {
    void collect() {
      backend.transition(service.id, ServiceStatus.inProgress,
          ServiceEventName.startService, driverId, UserRole.driver);
      backend.transition(service.id, ServiceStatus.completed,
          ServiceEventName.completeService, driverId, UserRole.driver);
      expect(backend.confirmCashCollected(service.id, driverId, 250000), isA<Ok<void>>());
    }

    /// Cash this chofer already held from seeded jobs, before this one.
    int heldBefore() => backend
        .uncountedCash(driverId)
        .fold(0, (sum, s) => sum + s.payment.capturedCents);

    test('"Cobrado en efectivo" marks the job paid and the chofer holding it', () {
      arrived(method: PaymentMethod.cash);
      final before = backend.driver(driverId)!.cashOnHandCents;
      final uncountedBefore = backend.uncountedCash(driverId).length;

      collect();

      expect(current().status, ServiceStatus.closed);
      expect(current().payment.isPaid, isTrue);
      expect(current().payment.status.label, 'Pagado en efectivo');
      expect(backend.driver(driverId)!.cashOnHandCents, before + 250000);
      expect(backend.uncountedCash(driverId), hasLength(uncountedBefore + 1));
      expect(backend.uncountedCash(driverId).map((s) => s.id), contains(service.id));
    });

    test('a corte receives it all once, and never counts the same job again', () {
      arrived(method: PaymentMethod.cash);
      final earlier = backend.uncountedCash(driverId).length;
      final earlierCents = heldBefore();
      collect();

      // The chofer's balance and the jobs behind it agree.
      expect(backend.driver(driverId)!.cashOnHandCents, earlierCents + 250000);

      final corte = backend.settleDriverCash(driverId, staff, note: 'Oficina');

      expect(corte, isA<Ok<int>>());
      // Every uncounted cash job, this one and any before it.
      expect(corte.valueOrNull, earlierCents + 250000);
      expect(backend.driver(driverId)!.cashOnHandCents, 0);
      expect(backend.uncountedCash(driverId), isEmpty);
      expect(current().payment.cashSettlementId, isNotNull);

      final history = backend.cashSettlements(driverId: driverId);
      expect(history, hasLength(1));
      expect(history.single.amountCents, earlierCents + 250000);
      expect(history.single.serviceCount, earlier + 1);
      expect(history.single.note, 'Oficina');

      // Nothing left to hand in.
      expect(backend.settleDriverCash(driverId, staff), isA<Err<int>>());
    });

    test('a card job has no cash to confirm', () {
      arrived();
      backend.holdDemoCard(service.id, client);
      backend.transition(service.id, ServiceStatus.inProgress,
          ServiceEventName.startService, driverId, UserRole.driver);

      expect(backend.confirmCashCollected(service.id, driverId, 250000), isA<Err<void>>());
    });
  });
}
