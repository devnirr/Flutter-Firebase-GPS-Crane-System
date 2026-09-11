import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';

/// "Pedir esta grúa": the truck the customer picked gets the job ahead of a
/// nearer one, and an unusable pick changes nothing.
void main() {
  const pickup = ServiceLocation(
    geo: LatLng(18.4795, -69.9420), // Gazcue, where driver-1 is parked
    address: 'Gazcue',
  );

  Future<Service> requestWith(DemoBackend backend, String? preferred) async {
    final created = backend.createService(
      clientId: 'demo-client-1',
      pickup: pickup,
      dropoff: const ServiceLocation(geo: LatLng(18.5001, -69.8800)),
      vehicle: const ServiceVehicle(condition: VehicleCondition.noArranca),
      truckType: TruckType.gancho,
      paymentMethod: PaymentMethod.cash,
      quote: const Quote(totalCents: 250000),
      route: const ServiceRoute(distanceMeters: 8000),
      preferredDriverId: preferred,
    );
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final current = backend.service(created.id)!;
      if (current.hasDriver) return current;
    }
    fail('the demo cascade never assigned a chofer');
  }

  /// The free gancho drivers, nearest to the pickup first.
  List<Driver> gancho(DemoBackend backend) => backend.allDrivers
      .where((d) => d.truckType == TruckType.gancho && d.canGoOnline && d.isOnline)
      .toList();

  test('the picked truck is offered the job before a nearer one', () async {
    final backend = DemoBackend(dispatchDelay: const Duration(milliseconds: 10))..seed();
    final drivers = gancho(backend);
    expect(drivers.length, greaterThanOrEqualTo(2), reason: 'seed needs two');

    // Without a pick, dispatch takes the nearest.
    final nearest = (await requestWith(backend, null)).driverId;

    final other = drivers.firstWhere((d) => d.id != nearest);
    final fresh = DemoBackend(dispatchDelay: const Duration(milliseconds: 10))..seed();
    final served = await requestWith(fresh, other.id);

    expect(served.driverId, other.id);
  });

  test('a pick that cannot take the job leaves dispatch as it was', () async {
    final backend = DemoBackend(dispatchDelay: const Duration(milliseconds: 10))..seed();
    // A plataforma truck cannot do a gancho job.
    final wrongType = backend.allDrivers
        .firstWhere((d) => d.truckType == TruckType.plataforma && d.isOnline);

    final served = await requestWith(backend, wrongType.id);

    expect(served.driverId, isNot(wrongType.id));
    expect(served.hasDriver, isTrue);
  });
}
