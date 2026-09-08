import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:grua_core/grua_core.dart';

/// Publishes the chofer's position while they are online.
///
/// Three rules shape this, and all three come from what dispatch needs rather
/// than from what the GPS offers:
///
/// * **At most one write every 5 seconds.** A raw high-accuracy stream fires
///   several times a second; at 1 Hz a fleet of forty trucks would dominate
///   the bill on its own.
/// * **At least one every 30 seconds.** Dispatch drops any position older than
///   90 seconds, so a truck parked at a stoplight must still say it is there or
///   it silently stops receiving work.
/// * **Nothing at all while offline.** Reporting a chofer who has clocked out
///   is both a privacy problem and a way to offer work to someone who is not
///   available.
class LocationPublisher {
  LocationPublisher({
    required this._location,
    required this._drivers,
    required this._driverId,
    required this._truckType,
  });

  final LocationService _location;
  final DriverRepository _drivers;
  final String _driverId;
  final TruckType _truckType;

  static const _minInterval = Duration(seconds: 5);
  static const _heartbeat = Duration(seconds: 30);

  // Cancelled in `stop()`, which `ref.onDispose` calls; the analyzer only
  // looks for a cancel in the same function that created it.
  // ignore: cancel_subscriptions
  StreamSubscription<Position>? _subscription;
  Timer? _heartbeatTimer;
  Position? _latest;
  DateTime? _lastWriteAt;

  bool get isRunning => _subscription != null;

  /// Begins publishing. Safe to call twice.
  Future<void> start({
    String? serviceId,
    DriverLiveState state = DriverLiveState.idle,
  }) async {
    if (_subscription != null) return;

    _subscription = _location.watchPosition(background: true).listen(
      (position) => _onPosition(position, serviceId, state),
      // A location stream can fail for reasons outside our control — the radio
      // dropping out, permission revoked from settings mid-shift, or no
      // platform at all under a widget test. None of those should take the app
      // down; the chofer simply ages out of dispatch until it recovers.
      onError: (Object error, StackTrace stack) {
        debugPrint('Location stream error: $error');
      },
      cancelOnError: false,
    );

    // The heartbeat is what keeps a stationary truck dispatchable. Without it
    // a chofer waiting at a stoplight ages out of the candidate list.
    _heartbeatTimer = Timer.periodic(_heartbeat, (_) {
      final last = _latest;
      if (last != null) _publish(last, serviceId, state, force: true);
    });
  }

  void _onPosition(
    Position position,
    String? serviceId,
    DriverLiveState state,
  ) {
    _latest = position;
    _publish(position, serviceId, state);
  }

  void _publish(
    Position position,
    String? serviceId,
    DriverLiveState state, {
    bool force = false,
  }) {
    final now = DateTime.now().toUtc();
    final since = _lastWriteAt == null ? null : now.difference(_lastWriteAt!);
    if (!force && since != null && since < _minInterval) return;

    _lastWriteAt = now;
    unawaited(
      _drivers.publishLivePosition(
        DriverLivePosition(
          driverId: _driverId,
          lat: position.latitude,
          lng: position.longitude,
          heading: position.heading,
          speedKmh: position.speed * 3.6,
          accuracy: position.accuracy,
          isOnline: true,
          state: state,
          truckType: _truckType,
          serviceId: serviceId,
          updatedAt: now.millisecondsSinceEpoch,
        ),
      ),
    );
  }

  /// Stops publishing and marks the last position offline, so the chofer
  /// disappears from dispatch immediately rather than aging out.
  Future<void> stop() async {
    // Cancel synchronously before the first await. `ref.onDispose` only runs a
    // callback up to its first suspension, so awaiting the subscription first
    // leaves the heartbeat alive past teardown.
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;

    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();

    final last = _latest;
    if (last == null) return;

    await _drivers.publishLivePosition(
      DriverLivePosition(
        driverId: _driverId,
        lat: last.latitude,
        lng: last.longitude,
        isOnline: false,
        truckType: _truckType,
        updatedAt: DateTime.now().toUtc().millisecondsSinceEpoch,
      ),
    );
  }
}

/// Keeps the publisher's lifecycle tied to the chofer's online state.
///
/// Watching rather than being called imperatively means the publisher also
/// stops when an admin suspends the account or the record says the chofer went
/// offline on another device — cases a button handler would miss.
final locationPublisherProvider = Provider<LocationPublisher?>((ref) {
  final driver = ref.watch(currentDriverProvider).value;
  if (driver == null || !driver.isOnline || !driver.status.canWork) return null;

  final publisher = LocationPublisher(
    location: ref.watch(locationServiceProvider),
    drivers: ref.watch(driverRepositoryProvider),
    driverId: driver.id,
    truckType: driver.truckType,
  );

  unawaited(
    publisher.start(
      serviceId: driver.currentServiceId,
      state: driver.isBusy ? DriverLiveState.onService : DriverLiveState.idle,
    ),
  );

  ref.onDispose(() => unawaited(publisher.stop()));
  return publisher;
});
