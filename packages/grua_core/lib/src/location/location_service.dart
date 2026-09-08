import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:geocoding/geocoding.dart' as geocoding;
import 'package:geolocator/geolocator.dart';

import '../domain/failures.dart';
import '../domain/value_objects.dart';

/// Why the app cannot use location right now, if it cannot.
///
/// Each case has a different fix, so they are separate rather than one
/// "denied": turning on the GPS radio, granting a prompt, and opening system
/// settings are three different instructions for the customer.
enum LocationBlocker {
  /// The device's location services are switched off entirely.
  serviceDisabled,

  /// Not asked yet.
  notRequested,

  /// Denied this time; asking again is allowed.
  denied,

  /// Denied permanently. Only a trip to system settings fixes it.
  deniedForever,

  /// Foreground granted, but the chofer app needs "always".
  needsAlways,

  none;

  bool get isBlocking => this != LocationBlocker.none;

  /// The es-DO explanation shown to the user.
  String get message => switch (this) {
        LocationBlocker.serviceDisabled =>
          'El GPS está apagado. Actívalo para que podamos encontrarte.',
        LocationBlocker.notRequested =>
          'Necesitamos tu ubicación para enviarte la grúa.',
        LocationBlocker.denied =>
          'Sin tu ubicación no podemos enviarte una grúa. Puedes marcarla en '
              'el mapa si prefieres.',
        LocationBlocker.deniedForever =>
          'Bloqueaste el acceso a la ubicación. Actívalo en los ajustes del '
              'teléfono.',
        LocationBlocker.needsAlways =>
          'Para recibir servicios necesitamos tu ubicación siempre, incluso '
              'con la app cerrada.',
        LocationBlocker.none => '',
      };

  /// What the button under that message should say.
  String? get actionLabel => switch (this) {
        LocationBlocker.serviceDisabled => 'Abrir ajustes de ubicación',
        LocationBlocker.notRequested || LocationBlocker.denied => 'Permitir',
        LocationBlocker.deniedForever ||
        LocationBlocker.needsAlways =>
          'Abrir ajustes',
        LocationBlocker.none => null,
      };
}

/// A resolved place: coordinates plus whatever the geocoder could name.
@immutable
class ResolvedPlace {
  const ResolvedPlace({
    required this.position,
    this.address = '',
    this.locality = '',
    this.isApproximate = false,
  });

  final LatLng position;
  final String address;
  final String locality;

  /// True when the address came from a last-known fix or a coarse geocode, so
  /// the UI can ask the customer to confirm rather than assume.
  final bool isApproximate;

  String get displayAddress =>
      address.isNotEmpty ? address : 'Ubicación en el mapa';
}

/// Device location, with the permission ladder handled once.
///
/// Dominican street addressing is unreliable, so nothing here treats a
/// geocoded string as authoritative — every caller pairs it with a map pin the
/// customer can drag and a landmark reference they type themselves.
class LocationService {
  LocationService({GeolocatorPlatform? geolocator, geocoding.Geocoding? geocoder})
      : _geolocator = geolocator ?? GeolocatorPlatform.instance,
        _injectedGeocoder = geocoder;

  final GeolocatorPlatform _geolocator;
  final geocoding.Geocoding? _injectedGeocoder;
  geocoding.Geocoding? _cachedGeocoder;

  /// Built on first use, not in the constructor.
  ///
  /// `Geocoding()` dereferences the platform instance eagerly and throws when
  /// none is registered — which is every widget test, and any host where the
  /// plugin failed to register. Constructing it lazily means a screen that
  /// never geocodes never pays for it, and a missing platform degrades to an
  /// unnamed pin instead of taking the provider down.
  geocoding.Geocoding? get _geocoder {
    if (_injectedGeocoder != null) return _injectedGeocoder;
    if (_cachedGeocoder != null) return _cachedGeocoder;
    try {
      return _cachedGeocoder = geocoding.Geocoding();
    } on Object {
      return null;
    }
  }

  /// Results come back in Dominican Spanish so a chofer reads "Calle" rather
  /// than "Street".
  static const Locale _locale = Locale('es', 'DO');

  /// Checks what, if anything, is stopping us — without prompting.
  Future<LocationBlocker> check({bool requireAlways = false}) async {
    if (!await _geolocator.isLocationServiceEnabled()) {
      return LocationBlocker.serviceDisabled;
    }

    final permission = await _geolocator.checkPermission();
    return switch (permission) {
      LocationPermission.denied => LocationBlocker.notRequested,
      LocationPermission.deniedForever => LocationBlocker.deniedForever,
      LocationPermission.whileInUse =>
        requireAlways ? LocationBlocker.needsAlways : LocationBlocker.none,
      LocationPermission.always => LocationBlocker.none,
      LocationPermission.unableToDetermine => LocationBlocker.notRequested,
    };
  }

  /// Prompts, and reports what we ended up with.
  ///
  /// Callers must show their own rationale *before* calling this: on both
  /// platforms a denied prompt is close to unrecoverable, so spending it
  /// without explaining why is a permanent loss.
  Future<LocationBlocker> request({bool requireAlways = false}) async {
    if (!await _geolocator.isLocationServiceEnabled()) {
      return LocationBlocker.serviceDisabled;
    }

    var permission = await _geolocator.checkPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.unableToDetermine) {
      permission = await _geolocator.requestPermission();
    }

    return switch (permission) {
      LocationPermission.denied => LocationBlocker.denied,
      LocationPermission.deniedForever => LocationBlocker.deniedForever,
      LocationPermission.whileInUse =>
        requireAlways ? LocationBlocker.needsAlways : LocationBlocker.none,
      LocationPermission.always => LocationBlocker.none,
      LocationPermission.unableToDetermine => LocationBlocker.denied,
    };
  }

  Future<void> openLocationSettings() => _geolocator.openLocationSettings();

  Future<void> openAppSettings() => _geolocator.openAppSettings();

  /// A single fix.
  ///
  /// Falls back to the last known position rather than failing: somebody
  /// stranded on a highway would rather see an approximate pin they can drag
  /// than a spinner while the GPS gets a lock.
  Future<Result<ResolvedPlace>> currentPlace({
    Duration timeout = const Duration(seconds: 10),
    bool geocode = true,
  }) async {
    final blocker = await check();
    if (blocker.isBlocking) {
      return Result.err(
        Failure(FailureCode.permissionDenied, message: blocker.message),
      );
    }

    Position? position;
    var approximate = false;

    try {
      position = await _geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: timeout,
        ),
      );
    } on TimeoutException {
      position = await _geolocator.getLastKnownPosition();
      approximate = true;
    } on Exception {
      position = await _geolocator.getLastKnownPosition();
      approximate = true;
    }

    if (position == null) {
      return const Result.err(
        Failure(
          FailureCode.timeout,
          message: 'No pudimos obtener tu ubicación. Márcala en el mapa.',
        ),
      );
    }

    final point = LatLng(position.latitude, position.longitude);
    if (!geocode) {
      return Result.ok(
        ResolvedPlace(position: point, isApproximate: approximate),
      );
    }

    final place = await describe(point);
    return Result.ok(
      ResolvedPlace(
        position: point,
        address: place.address,
        locality: place.locality,
        isApproximate: approximate,
      ),
    );
  }

  /// Reverse-geocodes a point. Never throws — an unnamed pin is still usable,
  /// and the customer types a landmark reference anyway.
  Future<ResolvedPlace> describe(LatLng point) async {
    try {
      final geocoder = _geocoder;
      if (geocoder == null) return ResolvedPlace(position: point);

      final results = await geocoder.placemarkFromCoordinates(
        point.latitude,
        point.longitude,
        locale: _locale,
      );
      if (results.isEmpty) return ResolvedPlace(position: point);

      final mark = results.first;
      final parts = [
        if ((mark.thoroughfare ?? '').isNotEmpty) mark.thoroughfare,
        if ((mark.subThoroughfare ?? '').isNotEmpty) mark.subThoroughfare,
        if ((mark.subLocality ?? '').isNotEmpty) mark.subLocality,
        if ((mark.locality ?? '').isNotEmpty) mark.locality,
      ].whereType<String>().toList();

      return ResolvedPlace(
        position: point,
        address: parts.join(', '),
        locality: mark.locality ?? '',
      );
    } on Exception {
      return ResolvedPlace(position: point);
    }
  }

  /// A continuous position stream for the chofer app.
  ///
  /// [distanceFilter] keeps a parked truck from emitting; the caller throttles
  /// on top of this so a moving truck writes at most once every few seconds.
  Stream<Position> watchPosition({
    int distanceFilter = 25,
    bool background = false,
  }) {
    final settings = background
        ? AndroidSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: distanceFilter,
            // Without a foreground service Android stops delivering updates
            // within minutes of the screen going off, which for a chofer means
            // vanishing from dispatch mid-shift.
            foregroundNotificationConfig: const ForegroundNotificationConfig(
              notificationTitle: 'Grúas RD 24/7',
              notificationText: 'Compartiendo tu ubicación mientras trabajas',
              enableWakeLock: true,
              setOngoing: true,
            ),
          )
        : LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: distanceFilter,
          );

    return _geolocator.getPositionStream(locationSettings: settings);
  }

  /// Distance in metres between two points, without a plugin round-trip.
  double distanceBetween(LatLng a, LatLng b) => a.distanceTo(b);
}
