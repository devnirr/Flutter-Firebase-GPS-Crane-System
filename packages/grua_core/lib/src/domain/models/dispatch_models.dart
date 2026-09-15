import 'package:freezed_annotation/freezed_annotation.dart';

import '../../data/converters.dart';
import '../enums.dart';
import '../value_objects.dart';

part 'dispatch_models.freezed.dart';
part 'dispatch_models.g.dart';

/// One exclusive offer to one chofer, at `services/{id}/offers/{driverId}`.
///
/// The cascade sends these one at a time. Everything a chofer needs to decide
/// is denormalised onto the offer so the ringing screen can render before any
/// further reads complete — on a highway with one bar, a second round-trip is
/// a lost job.
@freezed
abstract class Offer with _$Offer {
  const factory Offer({
    required String serviceId,
    required String driverId,
    @JsonKey(unknownEnumValue: OfferState.unknown)
    @Default(OfferState.sent) OfferState state,
    @Default(0) int round,
    @Default(0) int distanceMeters,
    @Default(0) int etaSeconds,
    @Default('') String serviceCode,
    @Default('') String pickupAddress,
    @Default('') String pickupReference,
    @Default('') String dropoffAddress,
    @GeoPointConverter() @Default(LatLng(0, 0)) LatLng pickupGeo,

    /// Null on a job with no destination yet, and on offers sent before the
    /// field existed.
    @NullableGeoPointConverter() LatLng? dropoffGeo,
    @Default('') String vehicleLabel,

    /// Download URLs of the photos the customer added to the request.
    @Default(<String>[]) List<String> vehiclePhotoUrls,
    @JsonKey(unknownEnumValue: VehicleCondition.unknown)
    @Default(VehicleCondition.unknown) VehicleCondition condition,
    @JsonKey(unknownEnumValue: TruckType.unknown)
    @Default(TruckType.gancho) TruckType truckType,
    @JsonKey(unknownEnumValue: PaymentMethod.unknown)
    @Default(PaymentMethod.cash) PaymentMethod paymentMethod,

    /// What the chofer takes home for this job, after commission. Showing gross
    /// and letting them work out the net is how you get rejections.
    @CentsConverter() @Default(0) int netEarningsCents,
    @CentsConverter() @Default(0) int grossCents,
    @Default('') String rejectionReason,
    @NullableTimestampConverter() DateTime? sentAt,
    @NullableTimestampConverter() DateTime? expiresAt,
    @NullableTimestampConverter() DateTime? respondedAt,
  }) = _Offer;

  const Offer._();

  factory Offer.fromJson(Map<String, dynamic> json) => _$OfferFromJson(json);

  bool get isOpen => state.isOpen;

  double get distanceKm => distanceMeters / 1000;

  String get distanceLabel => distanceMeters < 1000
      ? '$distanceMeters m'
      : '${distanceKm.toStringAsFixed(1)} km';

  /// Seconds left, computed from the server's [expiresAt] rather than a local
  /// countdown. Clock drift on a cheap Android otherwise silently eats
  /// offers.
  int secondsRemaining(DateTime now) {
    final expiry = expiresAt;
    if (expiry == null) return 0;
    final remaining = expiry.difference(now).inSeconds;
    return remaining < 0 ? 0 : remaining;
  }

  double progress(DateTime now, {int ttlSeconds = 25}) {
    final remaining = secondsRemaining(now);
    return (remaining / ttlSeconds).clamp(0.0, 1.0);
  }

  bool hasExpired(DateTime now) => secondsRemaining(now) == 0;
}

/// Live position of the assigned chofer, at `tracking/{serviceId}`.
///
/// Mirrored from RTDB by a trigger and throttled to one write every eight
/// seconds, so the client app subscribes to exactly one document and never
/// gains read access to the rest of the fleet.
@freezed
abstract class ServiceTracking with _$ServiceTracking {
  const factory ServiceTracking({
    required String serviceId,
    @GeoPointConverter() @Default(LatLng(0, 0)) LatLng position,
    @Default(0) double heading,
    @Default(0) double speedKmh,
    @Default(0) int etaSeconds,
    @Default(0) int remainingMeters,
    @Default('') String driverId,
    @NullableTimestampConverter() DateTime? updatedAt,
  }) = _ServiceTracking;

  const ServiceTracking._();

  factory ServiceTracking.fromJson(Map<String, dynamic> json) =>
      _$ServiceTrackingFromJson(json);

  int get etaMinutes => etaSeconds <= 0 ? 0 : (etaSeconds / 60).ceil();

  String get etaLabel => etaMinutes <= 1 ? 'menos de 1 min' : '$etaMinutes min';

  /// After a minute of silence the marker is lying about where the truck is.
  /// Say "reconnecting" rather than freezing it in the wrong place.
  bool isStale(DateTime now, {Duration threshold = const Duration(seconds: 60)}) {
    final stamp = updatedAt;
    if (stamp == null) return true;
    return now.difference(stamp) > threshold;
  }
}

/// A chat message at `services/{id}/messages/{msgId}`.
///
/// The only subcollection the apps write directly — rules restrict it to the
/// two parties, cap the length, and reject a spoofed [senderId].
@freezed
abstract class ChatMessage with _$ChatMessage {
  const factory ChatMessage({
    required String id,
    required String senderId,
    @JsonKey(unknownEnumValue: UserRole.unknown)
    @Default(UserRole.unknown) UserRole senderRole,
    @Default('') String text,

    /// A photo shared in the conversation, if any: the download URL of an
    /// object under `chat/{threadId}/` in Storage. A message carries words, a
    /// photo, or both — never neither.
    @Default('') String imageUrl,

    /// Client-generated id, so an optimistic bubble can be reconciled with the
    /// server echo and a retry cannot duplicate the message.
    @Default('') String clientMsgId,
    @NullableTimestampConverter() DateTime? sentAt,
    @NullableTimestampConverter() DateTime? readAt,

    /// Set when the sender deletes the message for both sides. The words and
    /// the photo are cleared in the same write — this is all that is left,
    /// and it is what the bubble says instead.
    @NullableTimestampConverter() DateTime? deletedAt,
  }) = _ChatMessage;

  const ChatMessage._();

  factory ChatMessage.fromJson(Map<String, dynamic> json) =>
      _$ChatMessageFromJson(json);

  bool get isRead => readAt != null;

  bool get hasImage => imageUrl.isNotEmpty && !isDeleted;

  bool get isDeleted => deletedAt != null;

  /// True while the server has not yet stamped [sentAt] — the message is on
  /// screen but not confirmed.
  bool get isPending => sentAt == null;

  bool isMine(String uid) => senderId == uid;
}

/// An append-only transition record at `services/{id}/events/{eventId}`.
///
/// This is the audit trail, the debugging tool, and the timeline the admin
/// panel renders. Nothing ever updates or deletes one.
@freezed
abstract class ServiceEvent with _$ServiceEvent {
  const factory ServiceEvent({
    required String id,
    @Default(ServiceEventName.unknown) ServiceEventName event,
    @JsonKey(unknownEnumValue: ServiceStatus.unknown)
    @Default(ServiceStatus.unknown) ServiceStatus from,
    @JsonKey(unknownEnumValue: ServiceStatus.unknown)
    @Default(ServiceStatus.unknown) ServiceStatus to,
    @Default('') String actorId,
    @JsonKey(unknownEnumValue: UserRole.unknown)
    @Default(UserRole.unknown) UserRole actorRole,
    @Default('') String note,
    @Default(<String, dynamic>{}) Map<String, dynamic> meta,
    @NullableTimestampConverter() DateTime? at,
  }) = _ServiceEvent;

  const ServiceEvent._();

  factory ServiceEvent.fromJson(Map<String, dynamic> json) =>
      _$ServiceEventFromJson(json);

  /// One line for the admin timeline, in Spanish.
  String get description => switch (event) {
        ServiceEventName.requestService => 'Servicio solicitado por el cliente',
        ServiceEventName.dispatchNext => 'Oferta enviada a un chofer',
        ServiceEventName.acceptService => 'Chofer aceptó el servicio',
        ServiceEventName.rejectService => 'Chofer rechazó la oferta',
        ServiceEventName.expireOffer => 'La oferta expiró',
        ServiceEventName.noDriversFound => 'Sin choferes disponibles',
        ServiceEventName.assignServiceManually => 'Asignado manualmente',
        ServiceEventName.confirmHeavyService =>
          'Precio y disponibilidad confirmados por el operador',
        ServiceEventName.markArrived => 'Chofer llegó al punto de recogida',
        ServiceEventName.startService => 'Servicio iniciado',
        ServiceEventName.completeService => 'Servicio finalizado',
        ServiceEventName.confirmCashCollected => 'Efectivo confirmado',
        ServiceEventName.closeService => 'Servicio cerrado',
        ServiceEventName.cancelService => 'Cancelado por el cliente',
        ServiceEventName.cancelByDriver => 'Cancelado por el chofer',
        ServiceEventName.failService => 'Servicio marcado con problema',
        ServiceEventName.choosePaymentMethod => switch (meta['method']) {
            'card' => 'Eligió pagar con tarjeta',
            'cash' => 'Eligió pagar en efectivo',
            _ => 'Eligió la forma de pago',
          },
        ServiceEventName.paymentAuthorized => 'Tarjeta retenida para el servicio',
        ServiceEventName.paymentCaptured => 'Pagado con tarjeta',
        ServiceEventName.paymentFailed => 'El pago con tarjeta falló',
        ServiceEventName.paymentVoided => 'Retención de la tarjeta liberada',
        ServiceEventName.unknown => 'Evento desconocido',
      };
}
