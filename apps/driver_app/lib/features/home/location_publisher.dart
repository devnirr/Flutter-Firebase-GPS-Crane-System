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
    this._heartbeat = const Duration(seconds: 30),
  });

  final LocationService _location;
  final DriverRepository _drivers;
  final String _driverId;
  final TruckType _truckType;

  static const _minInterval = Duration(seconds: 5);

  /// How often a stationary truck repeats itself. A parameter only so a test
  /// does not have to wait half a minute.
  final Duration _heartbeat;

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

    // A fix now, rather than at the first movement. `getPositionStream` only
    // emits once the phone has moved past the distance filter — and in a
    // browser frequently not at all — so a chofer who switches on and waits
    // published nothing: online on their own screen, and absent from both
    // dispatch and the customer's "grúas cerca de ti".
    unawaited(_publishFirstFix(serviceId, state));

    // The heartbeat is what keeps a stationary truck dispatchable. Without it
    // a chofer waiting at a stoplight ages out of the candidate list.
    _heartbeatTimer = Timer.periodic(_heartbeat, (_) {
      final last = _latest;
      if (last != null) {
        _publish(last, serviceId, state, force: true);
        return;
      }
      // Nothing to repeat yet: the fix asked for on switch-on came back empty
      // — permission granted a moment ago, no lock, a phone indoors, a
      // browser that answers when it feels like it. Ask again rather than
      // waiting for movement the stream may never report: a chofer who
      // publishes nothing is invisible to dispatch and to the customer's
      // "grúas cerca de ti", and `reapStaleDrivers` switches them off after
      // five minutes of it.
      unawaited(_publishFirstFix(serviceId, state));
    });
  }

  /// Publishes the position the phone can give right now, unless the stream
  /// has already beaten it to it.
  Future<void> _publishFirstFix(String? serviceId, DriverLiveState state) async {
    if (_latest != null) return;
    final position = await _location.currentPosition();
    // Stopped, or overtaken by a real update, while the fix was coming.
    if (position == null || _latest != null || _subscription == null) return;
    _onPosition(position, serviceId, state);
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
      _drivers
          .publishLivePosition(
            DriverLivePosition(
              driverId: _driverId,
              lat: position.latitude,
              lng: position.longitude,
              // Kept for a future geohash search; today's searches go by
              // `isOnline`, which every build has written.
              geohash: encodeGeohash(LatLng(position.latitude, position.longitude)),
              heading: position.heading,
              speedKmh: position.speed * 3.6,
              accuracy: position.accuracy,
              isOnline: true,
              state: state,
              truckType: _truckType,
              serviceId: serviceId,
              updatedAt: now.millisecondsSinceEpoch,
            ),
          )
          // A refused write used to vanish, leaving a chofer who believed they
          // were online and a dispatcher who could not see them. Say so.
          .catchError((Object error) => debugPrint('Live position not published: $error')),
    );
  }

  /// Stops publishing and marks the last position offline, so the chofer
  /// disappears from dispatch immediately rather than aging out.
  ///
  /// [markOffline] is asked at the moment of writing, after the stream has
  /// been cancelled: by then a successor may have started, and its "online"
  /// must not be overwritten.
  Future<void> stop({bool Function()? markOffline}) async {
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
    if (markOffline != null && !markOffline()) return;

    try {
      await _drivers.publishLivePosition(
        DriverLivePosition(
          driverId: _driverId,
          lat: last.latitude,
          lng: last.longitude,
          geohash: encodeGeohash(LatLng(last.latitude, last.longitude)),
          isOnline: false,
          truckType: _truckType,
          updatedAt: DateTime.now().toUtc().millisecondsSinceEpoch,
        ),
      );
    } on Object catch (error) {
      // Signed out already, or no signal: the stale-position sweep takes the
      // chofer off the map instead.
      debugPrint('Offline position not published: $error');
    }
  }
}

/// Keeps the publisher's lifecycle tied to the chofer's online state.
///
/// Watching rather than being called imperatively means the publisher also
/// stops when an admin suspends the account or the record says the chofer went
/// offline on another device — cases a button handler would miss.
final locationPublisherProvider = Provider<LocationPublisher?>((ref) {
  // Only the fields that change what is published. Watching the whole record
  // restarted the publisher on every unrelated server write, and each
  // restart's "offline" landed after the new publisher's "online".
  final setup = ref.watch(
    currentDriverProvider.select((async) {
      final d = async.value;
      if (d == null || !d.isOnline || !d.status.canWork) return null;
      return (id: d.id, truckType: d.truckType, serviceId: d.currentServiceId);
    }),
  );
  if (setup == null) return null;

  final generation = ++_publisherGeneration;
  final publisher = LocationPublisher(
    location: ref.watch(locationServiceProvider),
    drivers: ref.watch(driverRepositoryProvider),
    driverId: setup.id,
    truckType: setup.truckType,
  );

  unawaited(
    publisher.start(
      serviceId: setup.serviceId,
      state: setup.serviceId == null || setup.serviceId!.isEmpty
          ? DriverLiveState.idle
          : DriverLiveState.onService,
    ),
  );

  // When a successor replaces this publisher (a new job, a new grúa) the
  // chofer is still online, and marking them offline would race its first
  // write. Only the last publisher standing marks them offline.
  ref.onDispose(
    () => unawaited(
      publisher.stop(markOffline: () => generation == _publisherGeneration),
    ),
  );
  return publisher;
});

/// Bumped each time a publisher is created; see [locationPublisherProvider].
var _publisherGeneration = 0;
