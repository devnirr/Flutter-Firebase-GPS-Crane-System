import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';

/// The demo backend's `setDriverStatus` has to refuse and clean up the way the
/// callable does, or the panel is built against a server that does not exist.
void main() {
  late DemoBackend backend;
  late Driver driver;

  setUp(() {
    backend = DemoBackend()..seed();
    driver = backend.createDriver(
      name: 'Wilfredo Antonio Reyes',
      cedula: '40212345678',
      phone: '+18295557788',
      email: 'wilfredo@gruasrd.do',
      licenseNumber: 'L-884213',
      licenseExpiry: DateTime.now().add(const Duration(days: 300)),
    )!;
  });

  test('activating clears the pending-documents reason', () {
    expect(driver.statusReason, isNotEmpty);

    expect(backend.setDriverStatus(driver.id, DriverStatus.active), isNull);

    final active = backend.driver(driver.id)!;
    expect(active.status, DriverStatus.active);
    expect(active.statusReason, isEmpty);
  });

  test('suspending takes the chofer offline and keeps the reason', () {
    backend
      ..setDriverStatus(driver.id, DriverStatus.active)
      ..setDriverOnline(driver.id, online: true);
    expect(backend.driver(driver.id)!.isOnline, isTrue);

    final refusal = backend.setDriverStatus(
      driver.id,
      DriverStatus.suspended,
      reason: 'Efectivo pendiente',
    );

    expect(refusal, isNull);
    final suspended = backend.driver(driver.id)!;
    expect(suspended.status, DriverStatus.suspended);
    expect(suspended.statusReason, 'Efectivo pendiente');
    expect(suspended.isOnline, isFalse);
  });

  test('an archived chofer cannot be brought back by activation', () {
    backend.archiveDriver(driver.id);

    expect(
      backend.setDriverStatus(driver.id, DriverStatus.active),
      'Este chofer fue eliminado.',
    );
    expect(backend.driver(driver.id)!.status, DriverStatus.inactive);
  });

  test('an unknown chofer is refused', () {
    expect(
      backend.setDriverStatus('nobody', DriverStatus.active),
      'Chofer no encontrado.',
    );
  });
}
