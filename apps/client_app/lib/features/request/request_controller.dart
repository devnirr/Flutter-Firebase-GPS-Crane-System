import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';
import 'package:image_picker/image_picker.dart';

/// Everything the customer has filled in so far.
///
/// Held as one immutable value so the quote step, the summary card and the
/// submit call all read the same thing, and so a killed app can restore the
/// draft rather than making a stranded customer type it twice.
class RequestDraft {
  const RequestDraft({
    this.pickup,
    this.dropoff,
    this.vehicle = const ServiceVehicle(),
    this.truckTypeOverride,
    this.notes = '',
    this.photoPaths = const [],
    this.quote,
    this.quoting = false,
    this.submitting = false,
    this.failure,
    this.preferredTruck,
  });

  /// The truck picked on the home map with "Pedir esta grúa", offered the job
  /// first. Null for an ordinary request.
  final PreferredTruck? preferredTruck;

  final ServiceLocation? pickup;
  final ServiceLocation? dropoff;
  final ServiceVehicle vehicle;

  /// Set only when the customer disagrees with the inferred type and picks
  /// another. Null means "trust the inference".
  final TruckType? truckTypeOverride;

  // No payment method here: the customer chooses card or cash on the tracking
  // screen when the chofer arrives.
  final String notes;
  final List<String> photoPaths;
  final QuoteResult? quote;
  final bool quoting;
  final bool submitting;
  final Failure? failure;

  TruckType get truckType => truckTypeOverride ?? vehicle.inferredTruckType;

  bool get hasLocations => pickup != null && dropoff != null;

  bool get hasVehicle =>
      vehicle.make.trim().isNotEmpty || vehicle.type != VehicleType.unknown;

  /// The quote step is only worth taking once we know where and what.
  bool get canQuote => hasLocations && hasVehicle;

  bool get canSubmit =>
      canQuote && quote != null && !submitting && !quoting;

  RequestDraft copyWith({
    ServiceLocation? pickup,
    ServiceLocation? dropoff,
    ServiceVehicle? vehicle,
    TruckType? truckTypeOverride,
    bool clearTruckTypeOverride = false,
    String? notes,
    List<String>? photoPaths,
    QuoteResult? quote,
    bool clearQuote = false,
    bool? quoting,
    bool? submitting,
    Failure? failure,
    bool clearFailure = false,
    PreferredTruck? preferredTruck,
    bool clearPreferredTruck = false,
  }) {
    return RequestDraft(
      preferredTruck:
          clearPreferredTruck ? null : (preferredTruck ?? this.preferredTruck),
      pickup: pickup ?? this.pickup,
      dropoff: dropoff ?? this.dropoff,
      vehicle: vehicle ?? this.vehicle,
      truckTypeOverride:
          clearTruckTypeOverride ? null : (truckTypeOverride ?? this.truckTypeOverride),
      notes: notes ?? this.notes,
      photoPaths: photoPaths ?? this.photoPaths,
      quote: clearQuote ? null : (quote ?? this.quote),
      quoting: quoting ?? this.quoting,
      submitting: submitting ?? this.submitting,
      failure: clearFailure ? null : (failure ?? this.failure),
    );
  }
}

/// A truck chosen on the map: its sealed handle, and what the customer saw.
class PreferredTruck {
  const PreferredTruck({required this.ref, required this.truckType});

  /// [NearbyTruck.ref], sent back as `preferredTruckRef`.
  final String ref;
  final TruckType truckType;
}

class RequestController extends Notifier<RequestDraft> {
  @override
  RequestDraft build() {
    // Empty on purpose: the pickup is the phone's own position, filled in by
    // [usePickupFromDevice] as soon as there is a fix. A hardcoded address
    // here used to look like an answer the customer had given.
    return const RequestDraft();
  }

  /// Takes the device's position as the pickup point.
  ///
  /// The customer is the one who is stranded, so where they are is not a
  /// question worth asking — and the form does not let them point somewhere
  /// else. Whatever landmark they typed survives a new fix.
  void usePickupFromDevice(ResolvedPlace place) {
    final current = state.pickup;

    // The same point again: fill in a name if this answer has one, and
    // otherwise leave what is there. `displayAddress` is not used here — its
    // "Ubicación en el mapa" would read as an answer the geocoder gave.
    if (current != null && current.geo == place.position) {
      if (place.address.isEmpty || current.address == place.address) return;
      state = state.copyWith(
        pickup: current.copyWith(address: place.address),
        clearQuote: true,
      );
      return;
    }

    state = state.copyWith(
      pickup: ServiceLocation(
        geo: place.position,
        address: place.address,
        reference: current?.reference ?? '',
      ),
      clearQuote: true,
      clearFailure: true,
    );
    if (place.address.isEmpty) unawaited(_namePickup(place.position));
  }

  /// Takes a bare point as the pickup, before any address is known.
  ///
  /// The live position stream has a fix long before a fresh
  /// `getCurrentPosition` answers, and a pickup with coordinates and no street
  /// name is already enough to quote and to dispatch. The name arrives a
  /// moment later through [usePickupFromDevice].
  void usePickupPoint(LatLng point) {
    if (state.pickup != null) return;
    state = state.copyWith(
      pickup: ServiceLocation(geo: point),
      clearQuote: true,
      clearFailure: true,
    );
    // Name it straight away rather than waiting for the precise fix: the
    // customer should read their street, not "tu ubicación actual".
    unawaited(_namePickup(point));
  }

  /// Fills in the address of a pickup that has only coordinates.
  ///
  /// Dropped if the customer's pickup has moved on since — a precise fix
  /// landed, or they picked a place by name — so a slow geocode never
  /// overwrites something better.
  ///
  /// When nothing can name the point (no geocoder on this platform, a key
  /// without the Geocoding API, no signal) the coordinates themselves are the
  /// answer: exact, and better than a form that waits forever for a street.
  Future<void> _namePickup(LatLng point) async {
    // Whichever of the two Google APIs the project has enabled: a reverse
    // geocode names the street, and failing that the nearest place names the
    // spot. Coordinates only when neither answers.
    final place = await ref.read(locationServiceProvider).describe(point);
    var name = place.address;
    if (name.isEmpty) {
      final nearby = await ref.read(placesServiceProvider).describePoint(point);
      name = nearby?.address ?? '';
    }
    final named = name.isNotEmpty ? name : _coordinates(point);

    final current = state.pickup;
    if (current == null || current.geo != point || current.address.isNotEmpty) {
      return;
    }
    state = state.copyWith(pickup: current.copyWith(address: named));
  }

  /// Five decimals: about a metre, which is finer than any tow needs.
  static String _coordinates(LatLng point) =>
      '${point.latitude.toStringAsFixed(5)}, '
      '${point.longitude.toStringAsFixed(5)}';

  /// Any change to what is being priced invalidates the quote. Letting a stale
  /// price survive an edit is how a customer gets charged for a different tow
  /// than the one they agreed to.
  void setPickup(ServiceLocation value) =>
      state = state.copyWith(pickup: value, clearQuote: true, clearFailure: true);

  void setDropoff(ServiceLocation value) =>
      state = state.copyWith(dropoff: value, clearQuote: true, clearFailure: true);

  void setVehicle(ServiceVehicle value) => state = state.copyWith(
        vehicle: value,
        clearQuote: true,
        clearTruckTypeOverride: true,
        clearFailure: true,
      );

  void setTruckType(TruckType? value) => state = value == null
      ? state.copyWith(clearTruckTypeOverride: true, clearQuote: true)
      : state.copyWith(truckTypeOverride: value, clearQuote: true);

  /// Sets or clears the truck to offer first. Opening the form without one
  /// clears it, so an old choice never rides along on a plain request.
  void setPreferredTruck(PreferredTruck? value) => state = value == null
      ? state.copyWith(clearPreferredTruck: true)
      : state.copyWith(preferredTruck: value);

  void setNotes(String value) => state = state.copyWith(notes: value);

  void addPhoto(String path) =>
      state = state.copyWith(photoPaths: [...state.photoPaths, path]);

  void removePhoto(String path) => state = state.copyWith(
        photoPaths: state.photoPaths.where((p) => p != path).toList(),
      );

  /// Asks the server what this tow costs. The app never prices anything itself.
  Future<void> requestQuote() async {
    final pickup = state.pickup;
    final dropoff = state.dropoff;
    if (pickup == null || dropoff == null || state.quoting) return;

    state = state.copyWith(quoting: true, clearFailure: true, clearQuote: true);

    final result = await ref.read(functionsGatewayProvider).quoteService(
          pickup: pickup,
          dropoff: dropoff,
          vehicle: state.vehicle,
          truckTypeOverride: state.truckTypeOverride,
        );

    state = result.fold(
      (quote) => state.copyWith(quoting: false, quote: quote),
      (failure) => state.copyWith(quoting: false, failure: failure),
    );
  }

  /// Submits the request. Returns the new service id, or null on failure — the
  /// failure itself is on [RequestDraft.failure] for the screen to render.
  Future<String?> submit() async {
    final pickup = state.pickup;
    final dropoff = state.dropoff;
    final quote = state.quote;
    if (pickup == null || dropoff == null || quote == null) return null;

    if (quote.isStale(DateTime.now().toUtc())) {
      state = state.copyWith(
        clearQuote: true,
        failure: const Failure(FailureCode.quoteExpired),
      );
      return null;
    }

    state = state.copyWith(submitting: true, clearFailure: true);

    // The photos go up first, so the request carries them and the chofer sees
    // the car on the offer. They used to stay on the customer's phone: picked,
    // shown on the form, and never sent anywhere.
    final photoUrls = await _uploadPhotos();
    if (photoUrls == null) {
      state = state.copyWith(
        submitting: false,
        failure: const Failure(
          FailureCode.network,
          message: 'No pudimos subir las fotos del vehículo. Revisa tu conexión '
              'e intenta de nuevo, o quítalas para continuar.',
        ),
      );
      return null;
    }

    final result = await ref.read(functionsGatewayProvider).requestService(
          pickup: pickup,
          dropoff: dropoff,
          vehicle: state.vehicle.copyWith(photoPaths: photoUrls),
          truckType: quote.truckType,
          quoteSignature: quote.signature,
          quoteExpiresAt: quote.expiresAt,
          distance: TripDistance.of(quote.quote),
          notes: state.notes.isEmpty ? null : state.notes,
          preferredTruckRef: state.preferredTruck?.ref,
        );

    // Awaited above; fold is synchronous here.
    // ignore: async_return_with_no_await
    return result.fold(
      (serviceId) {
        // Spent: the next request starts from the map again.
        state = state.copyWith(submitting: false, clearPreferredTruck: true);
        return serviceId;
      },
      (failure) {
        state = state.copyWith(submitting: false, failure: failure);
        return null;
      },
    );
  }

  /// Uploads every picked photo and returns their URLs, in order. Null when
  /// any of them fails: a request that silently drops the photo the customer
  /// took is the bug this replaced.
  Future<List<String>?> _uploadPhotos() async {
    final paths = state.photoPaths;
    if (paths.isEmpty) return const [];

    final clientId = ref.read(currentUserIdProvider);
    if (clientId == null) return null;

    final read = ref.read(photoBytesReaderProvider);
    final services = ref.read(serviceRepositoryProvider);
    final urls = <String>[];
    for (final path in paths) {
      try {
        final bytes = await read(path);
        final result = await services.uploadVehiclePhoto(
          clientId: clientId,
          bytes: bytes,
          contentType: imageContentType(bytes),
        );
        switch (result) {
          case Ok(:final value):
            urls.add(value);
          case Err():
            return null;
        }
      } on Object {
        // The picked file is gone — cleared from the cache, a revoked blob URL.
        return null;
      }
    }
    return urls;
  }

  void reset() => state = build();
}

/// Reads a picked photo off the device. A provider so a test can hand the form
/// photos without a camera or a file system.
final photoBytesReaderProvider = Provider<Future<Uint8List> Function(String path)>(
  (ref) => (path) => XFile(path).readAsBytes(),
);

/// The image type, from the bytes themselves.
///
/// Not from the name: in a browser the picker hands back a blob URL with no
/// extension at all. The picker re-encodes at `imageQuality`, which makes
/// nearly everything a JPEG.
String imageContentType(Uint8List bytes) {
  bool startsWith(List<int> magic, [int offset = 0]) {
    if (bytes.length < offset + magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[offset + i] != magic[i]) return false;
    }
    return true;
  }

  if (startsWith(const [0x89, 0x50, 0x4E, 0x47])) return 'image/png';
  if (startsWith(const [0x52, 0x49, 0x46, 0x46]) &&
      startsWith(const [0x57, 0x45, 0x42, 0x50], 8)) {
    return 'image/webp';
  }
  return 'image/jpeg';
}

final NotifierProvider<RequestController, RequestDraft> requestControllerProvider =
    NotifierProvider<RequestController, RequestDraft>(RequestController.new);
