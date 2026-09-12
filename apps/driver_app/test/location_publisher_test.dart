import 'dart:async';

import 'package:driver_app/features/home/location_publisher.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:grua_core/grua_core.dart';

/// Publishing the chofer's position, from the moment they go online.
///
/// The bug this pins down: the publisher only wrote when the position *stream*
/// emitted, and that stream waits for movement — in a browser, often forever.
/// A chofer who switched on and stayed parked was online on their own screen
/// and missing from dispatch and from the customer's "grúas cerca de ti".
void main() {
  Position fix({double lat = 18.4795, double lng = -69.9420}) => Position(
    latitude: lat,
    longitude: lng,
    timestamp: DateTime.utc(2026, 9, 12),
    accuracy: 10,
    altitude: 0,
    altitudeAccuracy: 0,
    heading: 0,
    headingAccuracy: 0,
    speed: 0,
    speedAccuracy: 0,
  );

  test('a parked chofer is published as soon as they go online', () async {
    final drivers = _CapturingDrivers();
    final publisher = LocationPublisher(
      location: _ParkedPhone(fix()),
      drivers: drivers,
      driverId: 'driver-1',
      truckType: TruckType.gancho,
    );

    await publisher.start();
    // The stream never emits — the phone has not moved.
    await Future<void>.delayed(Duration.zero);

    expect(drivers.published, hasLength(1));
    expect(drivers.published.single.driverId, 'driver-1');
    expect(drivers.published.single.isOnline, isTrue);
    expect(drivers.published.single.state, DriverLiveState.idle);
    expect(drivers.published.single.lat, closeTo(18.4795, 0.0001));

    await publisher.stop();
  });

  test('a job is published as being on service, not idle', () async {
    final drivers = _CapturingDrivers();
    final publisher = LocationPublisher(
      location: _ParkedPhone(fix()),
      drivers: drivers,
      driverId: 'driver-2',
      truckType: TruckType.plataforma,
    );

    await publisher.start(
      serviceId: 'svc-1',
      state: DriverLiveState.onService,
    );
    await Future<void>.delayed(Duration.zero);

    expect(drivers.published.single.state, DriverLiveState.onService);
    expect(drivers.published.single.serviceId, 'svc-1');

    await publisher.stop();
  });

  test('a slow first fix never overwrites a real update', () async {
    final drivers = _CapturingDrivers();
    final moving = StreamController<Position>();
    addTearDown(moving.close);

    final publisher = LocationPublisher(
      // The fix takes a moment to come back, as a real one does.
      location: _MovingPhone(
        stream: moving.stream,
        whenAsked: fix(),
        delay: const Duration(milliseconds: 30),
      ),
      drivers: drivers,
      driverId: 'driver-3',
      truckType: TruckType.gancho,
    );

    await publisher.start();
    moving.add(fix(lat: 18.5000, lng: -69.9000));
    await Future<void>.delayed(const Duration(milliseconds: 60));

    // Where the chofer actually is, written once: the stale fix that landed
    // afterwards is dropped rather than moving the truck back.
    expect(drivers.published, hasLength(1));
    expect(drivers.published.single.lat, closeTo(18.5, 0.0001));

    await publisher.stop();
  });

  test('a phone with no fix yet is asked again, not left invisible', () async {
    final drivers = _CapturingDrivers();
    final phone = _LatePhone(fix());
    final publisher = LocationPublisher(
      location: phone,
      drivers: drivers,
      driverId: 'driver-4',
      truckType: TruckType.gancho,
      heartbeat: const Duration(milliseconds: 20),
    );

    await publisher.start();
    await Future<void>.delayed(Duration.zero);

    // The first ask came back empty, so there is nothing on the map yet.
    expect(drivers.published, isEmpty);
    expect(phone.asked, 1);

    // The heartbeat keeps asking, and publishes the moment the phone knows.
    await Future<void>.delayed(const Duration(milliseconds: 70));
    expect(drivers.published, isNotEmpty);
    expect(drivers.published.first.isOnline, isTrue);
    expect(drivers.published.first.lat, closeTo(18.4795, 0.0001));

    await publisher.stop();
  });
}

/// A phone that cannot answer the first time it is asked: permission just
/// granted, no lock yet. The second answer is a real fix.
class _LatePhone extends LocationService {
  _LatePhone(this._fix);

  final Position _fix;
  int asked = 0;

  @override
  Stream<Position> watchPosition({
    int distanceFilter = 25,
    bool background = false,
  }) => const Stream.empty();

  @override
  Future<Position?> currentPosition({
    Duration timeout = const Duration(seconds: 10),
  }) async => ++asked == 1 ? null : _fix;
}

/// A phone that is not moving: its stream never emits, but it can still say
/// where it is when asked.
class _ParkedPhone extends LocationService {
  _ParkedPhone(this._fix);

  final Position _fix;

  @override
  Stream<Position> watchPosition({
    int distanceFilter = 25,
    bool background = false,
  }) => const Stream.empty();

  @override
  Future<Position?> currentPosition({
    Duration timeout = const Duration(seconds: 10),
  }) async => _fix;
}

class _MovingPhone extends LocationService {
  _MovingPhone({
    required this.stream,
    required this.whenAsked,
    this.delay = Duration.zero,
  });

  final Stream<Position> stream;
  final Position whenAsked;
  final Duration delay;

  @override
  Stream<Position> watchPosition({
    int distanceFilter = 25,
    bool background = false,
  }) => stream;

  @override
  Future<Position?> currentPosition({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    await Future<void>.delayed(delay);
    return whenAsked;
  }
}

class _CapturingDrivers implements DriverRepository {
  final published = <DriverLivePosition>[];

  @override
  Future<void> publishLivePosition(DriverLivePosition position) async =>
      published.add(position);

  // Nothing else is called; anything that is should fail loudly.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
