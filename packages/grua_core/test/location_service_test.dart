import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:grua_core/grua_core.dart';

/// What `LocationService` does when the platform underneath it misbehaves.
///
/// The bug these pin down showed up as a spinner on the location picker that
/// turned for ever. On the web `getLastKnownPosition` throws `UnsupportedError`
/// — an `Error`, which an `on Exception` catch does not see — so the fallback
/// for a failed fix took the whole call down with it, and the screen's
/// `_locating` flag was never cleared. The same platform ignores `timeLimit`
/// entirely, so a browser that simply never answers leaves the future pending.
void main() {
  Position position() => Position(
        latitude: 18.4795,
        longitude: -69.9420,
        timestamp: DateTime.utc(2026),
        accuracy: 10,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      );

  test('a failed fix with no last known position is a failure, not a throw',
      () async {
    final service = LocationService(geolocator: _WebLike());

    final result = await service.currentPlace(geocode: false);

    expect(result.isErr, isTrue);
    expect(result.failureOrNull?.code, FailureCode.timeout);
  });

  test('a platform that never answers gives up instead of hanging', () async {
    final service = LocationService(geolocator: _NeverAnswers());

    final result = await service
        .currentPlace(
          timeout: const Duration(milliseconds: 10),
          geocode: false,
        )
        // Generously past the service's own deadline: if this one fires, the
        // service did not give up at all.
        .timeout(const Duration(seconds: 10));

    expect(result.isErr, isTrue);
  });

  test('a last known position answers, marked approximate', () async {
    final service = LocationService(geolocator: _OnlyLastKnown(position()));

    final result = await service.currentPlace(geocode: false);

    expect(result.valueOrNull?.isApproximate, isTrue);
    expect(result.valueOrNull?.position.latitude, closeTo(18.4795, 0.0001));
  });

  test('a permission check that throws reads as "not asked yet"', () async {
    final service = LocationService(geolocator: _WebLike(permissionKnown: false));

    expect(await service.check(), LocationBlocker.notRequested);
  });

  test('settings that cannot be opened are a no-op, not a crash', () async {
    final service = LocationService(geolocator: _WebLike());

    await expectLater(service.openAppSettings(), completes);
    await expectLater(service.openLocationSettings(), completes);
  });
}

/// A browser: no service concept, no last known position, no settings to open,
/// and every refusal an `Error` rather than an `Exception`.
class _WebLike extends GeolocatorPlatform {
  _WebLike({this.permissionKnown = true});

  /// False for the browser with no Permissions API at all, where even asking
  /// what we are allowed to do throws.
  final bool permissionKnown;

  @override
  Future<bool> isLocationServiceEnabled() async => true;

  @override
  Future<LocationPermission> checkPermission() async => permissionKnown
      ? LocationPermission.whileInUse
      : throw UnsupportedError('no Permissions API here');

  @override
  Future<Position> getCurrentPosition({LocationSettings? locationSettings}) async =>
      throw const PositionUpdateException('no fix');

  @override
  Future<Position?> getLastKnownPosition({bool forceLocationManager = false}) =>
      throw UnsupportedError('getLastKnownPosition is not supported on the web');

  @override
  Future<bool> openAppSettings() => throw UnsupportedError('no settings');

  @override
  Future<bool> openLocationSettings() => throw UnsupportedError('no settings');
}

/// Permission granted, and then silence — the desktop browser that cannot
/// reach a location provider and never calls either callback.
class _NeverAnswers extends GeolocatorPlatform {
  @override
  Future<bool> isLocationServiceEnabled() async => true;

  @override
  Future<LocationPermission> checkPermission() async =>
      LocationPermission.whileInUse;

  @override
  Future<Position> getCurrentPosition({LocationSettings? locationSettings}) =>
      Completer<Position>().future;

  @override
  Future<Position?> getLastKnownPosition({bool forceLocationManager = false}) =>
      throw UnsupportedError('getLastKnownPosition is not supported on the web');
}

/// A phone with a stale fix and no signal for a fresh one.
class _OnlyLastKnown extends GeolocatorPlatform {
  _OnlyLastKnown(this.last);

  final Position last;

  @override
  Future<bool> isLocationServiceEnabled() async => true;

  @override
  Future<LocationPermission> checkPermission() async =>
      LocationPermission.whileInUse;

  @override
  Future<Position> getCurrentPosition({LocationSettings? locationSettings}) =>
      throw const PositionUpdateException('no fix');

  @override
  Future<Position?> getLastKnownPosition({bool forceLocationManager = false}) async =>
      last;
}
