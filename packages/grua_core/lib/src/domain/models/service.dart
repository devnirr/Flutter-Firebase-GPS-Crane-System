import 'package:freezed_annotation/freezed_annotation.dart';

import '../../data/converters.dart';
import '../../location/polyline.dart';
import '../../utils/money.dart';
import '../enums.dart';
import '../value_objects.dart';

part 'service.freezed.dart';
part 'service.g.dart';

/// The customer's vehicle, as described at request time.
@freezed
abstract class ServiceVehicle with _$ServiceVehicle {
  const factory ServiceVehicle({
    @Default('') String make,
    @Default('') String model,
    @Default('') String plate,
    @Default('') String color,
    int? year,
    @JsonKey(unknownEnumValue: VehicleType.unknown)
    @Default(VehicleType.sedan) VehicleType type,
    @JsonKey(unknownEnumValue: VehicleCondition.unknown)
    @Default(VehicleCondition.noArranca) VehicleCondition condition,
    @Default(<String>[]) List<String> photoPaths,
    @Default('') String notes,
  }) = _ServiceVehicle;

  const ServiceVehicle._();

  factory ServiceVehicle.fromJson(Map<String, dynamic> json) =>
      _$ServiceVehicleFromJson(json);

  /// "Toyota Corolla 2018 · Gris" — what the chofer reads on the offer card.
  String get displayName {
    final parts = [
      if (make.isNotEmpty) make,
      if (model.isNotEmpty) model,
      if (year != null) '$year',
    ].join(' ');
    final base = parts.isEmpty ? type.label : parts;
    return color.isEmpty ? base : '$base · $color';
  }

  /// The truck type this vehicle needs.
  ///
  /// This same rule runs server-side in `quoteService`; the app computes it
  /// only to show the customer a price before they commit. If the two ever
  /// disagree, the server wins.
  TruckType get inferredTruckType {
    if (condition.requiresFlatbed) return TruckType.plataforma;
    if (type == VehicleType.camion) return TruckType.pesada;
    return TruckType.gancho;
  }
}

/// A pickup or dropoff point.
@freezed
abstract class ServiceLocation with _$ServiceLocation {
  const factory ServiceLocation({
    @GeoPointConverter() required LatLng geo,
    @Default('') String geohash,
    @Default('') String address,
    @Default('') String placeId,

    /// Dominican street addressing is unreliable, so a landmark reference is
    /// mandatory at pickup: "frente al colmado, km 12 Autopista Duarte".
    @Default('') String reference,
    @Default('') String notes,
  }) = _ServiceLocation;

  const ServiceLocation._();

  factory ServiceLocation.fromJson(Map<String, dynamic> json) =>
      _$ServiceLocationFromJson(json);

  String get displayAddress => address.isNotEmpty ? address : 'Ubicación en el mapa';

  /// Address plus landmark, which is what a chofer actually navigates by.
  String get fullDescription =>
      reference.isEmpty ? displayAddress : '$displayAddress ($reference)';
}

/// The route the server computed between pickup and dropoff.
@freezed
abstract class ServiceRoute with _$ServiceRoute {
  const factory ServiceRoute({
    @Default(0) int distanceMeters,
    @Default(0) int durationSeconds,

    /// Encoded polyline from the Routes API. Decoded on device for drawing.
    @Default('') String polyline,
    @Default('routes_api') String provider,
    @NullableTimestampConverter() DateTime? fetchedAt,
  }) = _ServiceRoute;

  const ServiceRoute._();

  factory ServiceRoute.fromJson(Map<String, dynamic> json) =>
      _$ServiceRouteFromJson(json);

  /// The drawn path, decoded once from what the server stored.
  ///
  /// Empty for a service quoted before the server routed, or when the Routes
  /// API was unreachable at the time — the screen then falls back to fetching
  /// its own, and to a straight line under that.
  ///
  /// Unchecked: [Service.towPath] is the one that knows the two ends and can
  /// tell a road from a line across the Atlantic.
  List<LatLng> get path => polyline.isEmpty ? const [] : decodePolyline(polyline);

  double get distanceKm => distanceMeters / 1000;

  int get durationMinutes => (durationSeconds / 60).ceil();

  String get distanceLabel => distanceKm < 1
      ? '$distanceMeters m'
      : '${distanceKm.toStringAsFixed(1)} km';

  String get durationLabel => durationMinutes < 60
      ? '$durationMinutes min'
      : '${durationMinutes ~/ 60} h ${durationMinutes % 60} min';
}

/// One line on the price breakdown beyond the base and distance charges.
@freezed
abstract class QuoteSurcharge with _$QuoteSurcharge {
  const factory QuoteSurcharge({
    required String code,
    required String label,
    @CentsConverter() @Default(0) int cents,
  }) = _QuoteSurcharge;

  const QuoteSurcharge._();

  factory QuoteSurcharge.fromJson(Map<String, dynamic> json) =>
      _$QuoteSurchargeFromJson(json);
}

/// A priced quote. Always produced by the server, never by the app.
@freezed
abstract class Quote with _$Quote {
  const factory Quote({
    @Default(1) int pricingVersion,
    @CentsConverter() @Default(0) int baseCents,
    @Default(0) double includedKm,
    @CentsConverter() @Default(0) int perKmCents,
    @Default(0) double distanceKm,
    @CentsConverter() @Default(0) int distanceCents,
    @Default(<QuoteSurcharge>[]) List<QuoteSurcharge> surcharges,
    @CentsConverter() @Default(0) int subtotalCents,
    @CentsConverter() @Default(0) int itbisCents,
    @CentsConverter() @Default(0) int totalCents,
    @Default('DOP') String currency,
  }) = _Quote;

  const Quote._();

  factory Quote.fromJson(Map<String, dynamic> json) => _$QuoteFromJson(json);

  bool get hasItbis => itbisCents > 0;

  int get surchargeTotalCents =>
      surcharges.fold(0, (sum, s) => sum + s.cents);

  String get totalLabel => totalCents.formatDOP;

  /// Every line the customer sees, in the order the receipt prints them.
  List<({String label, int cents}) > get breakdown => [
        (label: 'Banderazo', cents: baseCents),
        if (distanceCents > 0)
          (
            label: 'Recorrido ${distanceKm.toStringAsFixed(1)} km',
            cents: distanceCents
          ),
        for (final s in surcharges) (label: s.label, cents: s.cents),
        if (itbisCents > 0) (label: 'ITBIS (18%)', cents: itbisCents),
      ];
}

/// Payment state for one service.
@freezed
abstract class ServicePayment with _$ServicePayment {
  const factory ServicePayment({
    @JsonKey(unknownEnumValue: PaymentMethod.unknown)
    @Default(PaymentMethod.cash) PaymentMethod method,
    @JsonKey(unknownEnumValue: PaymentStatus.unknown)
    @Default(PaymentStatus.none) PaymentStatus status,
    @Default('') String gateway,

    /// The gateway's intent id. Never a card number — no PAN touches our code.
    String? intentId,
    String? customerId,
    String? paymentMethodId,
    @CentsConverter() @Default(0) int authorizedCents,
    @CentsConverter() @Default(0) int capturedCents,
    @CentsConverter() @Default(0) int refundedCents,
    @Default('') String last4,
    @Default('') String brand,
    @Default('') String failureCode,
    @Default('') String failureMessage,

    /// Set when the app must complete a 3-D Secure challenge.
    @Default(false) bool requiresAction,
    @NullableTimestampConverter() DateTime? authorizedAt,
    @NullableTimestampConverter() DateTime? capturedAt,
    @NullableTimestampConverter() DateTime? cashCollectedAt,
  }) = _ServicePayment;

  const ServicePayment._();

  factory ServicePayment.fromJson(Map<String, dynamic> json) =>
      _$ServicePaymentFromJson(json);

  bool get isCard => method == PaymentMethod.card;

  bool get isCash => method == PaymentMethod.cash;

  /// A card job may not start until the hold is in place; a cash job always may.
  bool get blocksStart => isCard && status != PaymentStatus.authorized;

  String get cardLabel =>
      last4.isEmpty ? method.label : '${brand.isEmpty ? 'Tarjeta' : brand} ••••$last4';
}

/// Dispatch bookkeeping. Read-only to the apps; the cascade owns every field.
@freezed
abstract class DispatchState with _$DispatchState {
  const factory DispatchState({
    @Default(0) int round,
    @Default(5) double radiusKm,
    @Default(<String>[]) List<String> offeredTo,
    @Default(<String>[]) List<String> rejectedBy,
    @NullableTimestampConverter() DateTime? lastOfferAt,
    @NullableTimestampConverter() DateTime? offerExpiresAt,

    /// Why the last scan found nobody, in words, for the dispatcher.
    ///
    /// "Nobody" covers three different problems — no truck online, no truck of
    /// the right kind, every truck already on a job — and only one of them is
    /// dispatch's to solve. The panel used to show a request sitting there
    /// with no explanation at all.
    @Default('') String lastReason,
    @NullableTimestampConverter() DateTime? lastCheckedAt,

    /// Cloud Tasks name for the pending expiry, so accept can cancel it.
    String? taskName,
  }) = _DispatchState;

  const DispatchState._();

  factory DispatchState.fromJson(Map<String, dynamic> json) =>
      _$DispatchStateFromJson(json);

  /// Seconds left on the current offer, from the server's expiry stamp rather
  /// than a local countdown — a phone with a drifting clock must not lose work.
  int secondsRemaining(DateTime now) {
    final expiry = offerExpiresAt;
    if (expiry == null) return 0;
    final remaining = expiry.difference(now).inSeconds;
    return remaining < 0 ? 0 : remaining;
  }
}

/// When each milestone happened.
@freezed
abstract class ServiceTimeline with _$ServiceTimeline {
  const factory ServiceTimeline({
    @NullableTimestampConverter() DateTime? createdAt,
    @NullableTimestampConverter() DateTime? dispatchedAt,
    @NullableTimestampConverter() DateTime? acceptedAt,
    @NullableTimestampConverter() DateTime? arrivedAt,
    @NullableTimestampConverter() DateTime? startedAt,
    @NullableTimestampConverter() DateTime? completedAt,
    @NullableTimestampConverter() DateTime? closedAt,
    @NullableTimestampConverter() DateTime? cancelledAt,
  }) = _ServiceTimeline;

  const ServiceTimeline._();

  factory ServiceTimeline.fromJson(Map<String, dynamic> json) =>
      _$ServiceTimelineFromJson(json);

  /// How long the customer waited from request to a chofer accepting.
  Duration? get timeToAccept => (createdAt != null && acceptedAt != null)
      ? acceptedAt!.difference(createdAt!)
      : null;

  /// How long from accept to the chofer reaching the vehicle.
  Duration? get timeToArrive => (acceptedAt != null && arrivedAt != null)
      ? arrivedAt!.difference(acceptedAt!)
      : null;

  Duration? get serviceDuration => (startedAt != null && completedAt != null)
      ? completedAt!.difference(startedAt!)
      : null;

  /// Free waiting starts when the chofer arrives and stops when work begins.
  Duration? waitingElapsed(DateTime now) {
    if (arrivedAt == null) return null;
    final end = startedAt ?? now;
    return end.difference(arrivedAt!);
  }
}

@freezed
abstract class ServiceCancellation with _$ServiceCancellation {
  const factory ServiceCancellation({
    @JsonKey(unknownEnumValue: CancelledBy.unknown)
    @Default(CancelledBy.unknown) CancelledBy by,
    @Default('') String reason,
    @Default('') String reasonCode,
    @CentsConverter() @Default(0) int feeCents,
    String? actorId,
  }) = _ServiceCancellation;

  const ServiceCancellation._();

  factory ServiceCancellation.fromJson(Map<String, dynamic> json) =>
      _$ServiceCancellationFromJson(json);

  bool get hasFee => feeCents > 0;
}

@freezed
abstract class ServiceRating with _$ServiceRating {
  const factory ServiceRating({
    @Default(0) int stars,
    @Default('') String comment,
    @NullableTimestampConverter() DateTime? ratedAt,
  }) = _ServiceRating;

  const ServiceRating._();

  factory ServiceRating.fromJson(Map<String, dynamic> json) =>
      _$ServiceRatingFromJson(json);

  bool get isRated => stars > 0;
}

@freezed
abstract class ServiceRatings with _$ServiceRatings {
  const factory ServiceRatings({
    ServiceRating? clientToDriver,
    ServiceRating? driverToClient,
  }) = _ServiceRatings;

  const ServiceRatings._();

  factory ServiceRatings.fromJson(Map<String, dynamic> json) =>
      _$ServiceRatingsFromJson(json);
}

/// A tow service — the central document of the whole system.
///
/// Everything except the chat subcollection is written by Cloud Functions. The
/// apps read this document, render it, and ask the server to move it.
@freezed
abstract class Service with _$Service {
  const factory Service({
    required String id,
    required String clientId,
    required ServiceLocation pickup,

    /// Human-readable code both parties quote on the phone: `GR-260908-0431`.
    @Default('') String code,
    @JsonKey(unknownEnumValue: ServiceStatus.unknown)
    @Default(ServiceStatus.pendingDispatch) ServiceStatus status,
    @Default('') String clientName,
    @Default('') String clientPhone,
    @Default(ServiceVehicle()) ServiceVehicle vehicle,
    @JsonKey(unknownEnumValue: TruckType.unknown)
    @Default(TruckType.gancho) TruckType truckTypeRequired,
    ServiceLocation? dropoff,
    @Default(ServiceRoute()) ServiceRoute route,
    @Default(Quote()) Quote quote,

    /// Written at completion. Differs from [quote] when waiting time or a
    /// reroute changed the price.
    Quote? finalQuote,
    @Default(ServicePayment()) ServicePayment payment,
    String? driverId,
    @Default('') String driverName,
    @Default('') String driverPhone,
    @Default('') String driverPhotoUrl,
    @Default(0) double driverRating,
    String? truckId,
    @Default('') String truckPlate,
    @Default('') String truckLabel,
    @NullableTimestampConverter() DateTime? assignedAt,
    @JsonKey(unknownEnumValue: AssignmentMode.unknown)
    @Default(AssignmentMode.auto) AssignmentMode assignmentMode,
    @Default(DispatchState()) DispatchState dispatch,
    @Default(ServiceTimeline()) ServiceTimeline timeline,
    ServiceCancellation? cancellation,
    @Default(ServiceRatings()) ServiceRatings ratings,
    String? invoiceId,
    @Default(0) int unreadForClient,
    @Default(0) int unreadForDriver,
    @Default(<String>[]) List<String> pickupPhotoPaths,
    @Default(<String>[]) List<String> dropoffPhotoPaths,
    @Default('') String driverNotes,
    @NullableTimestampConverter() DateTime? createdAt,
    @NullableTimestampConverter() DateTime? updatedAt,
  }) = _Service;

  const Service._();

  factory Service.fromJson(Map<String, dynamic> json) => _$ServiceFromJson(json);

  bool get isActive => status.isActive;

  bool get isTerminal => status.isTerminal;

  bool get hasDriver => driverId != null && driverId!.isNotEmpty;

  /// The tow drawn on a map: the road the server routed, checked against the
  /// two ends it is supposed to join.
  ///
  /// Empty when there is no stored path, or when the stored one does not
  /// describe this trip — both cases leave the screen to fetch its own, and a
  /// straight line under that. A wrong path is worse than no path: one bad
  /// point draws a band across the country.
  List<LatLng> get towPath {
    final end = dropoff?.geo;
    if (end == null) return const [];
    return sanePath(route.path, from: pickup.geo, to: end);
  }

  bool get canChat => status.allowsContact && hasDriver;

  bool get canCall => status.allowsContact && hasDriver;

  bool get isCancellableByClient => status.isCancellableByClient;

  /// The price to show. Before completion that is the estimate; after, the
  /// amount actually charged.
  Quote get effectiveQuote => finalQuote ?? quote;

  int get totalCents => effectiveQuote.totalCents;

  /// Customer-facing status line, with the driver's ETA folded in where it
  /// helps. Deliberately hides the dispatch cascade: a client watching
  /// `offered` flick back to `pending_dispatch` five times loses confidence.
  String statusLabelFor(UserRole role) {
    if (role == UserRole.driver) {
      return switch (status) {
        ServiceStatus.accepted => 'Ve al punto de recogida',
        ServiceStatus.arrived => 'Esperando para cargar',
        ServiceStatus.inProgress => 'En camino al destino',
        ServiceStatus.completed => payment.isCash
            ? 'Cobra ${totalCents.formatDOP}'
            : 'Servicio completado',
        _ => status.label,
      };
    }
    return status.label;
  }

  /// Whether a cancellation now would cost the client money. The server
  /// recomputes this; the app shows it so nobody is surprised.
  bool cancellationIncursFee(DateTime now, {Duration grace = const Duration(minutes: 3)}) {
    final acceptedAt = timeline.acceptedAt;
    if (acceptedAt == null) return false;
    return now.difference(acceptedAt) > grace;
  }

  /// Short one-line summary for lists: `GR-260908-0431 · Toyota Corolla`.
  String get listSummary {
    final vehicleLabel = vehicle.displayName;
    return code.isEmpty ? vehicleLabel : '$code · $vehicleLabel';
  }
}
