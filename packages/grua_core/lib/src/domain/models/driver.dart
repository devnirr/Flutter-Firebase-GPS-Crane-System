import 'package:freezed_annotation/freezed_annotation.dart';

import '../../data/converters.dart';
import '../enums.dart';
import '../value_objects.dart';

part 'driver.freezed.dart';
part 'driver.g.dart';

/// A chofer at `drivers/{uid}`.
///
/// Choferes never self-register: an admin creates the account, and every field
/// here is written by a Cloud Function. The driver app reads its own document
/// and nothing else.
@freezed
abstract class Driver with _$Driver {
  const factory Driver({
    required String id,
    required String name,
    @Default('') String cedula,
    @Default('') String phone,
    @Default('') String email,
    @Default('') String photoUrl,
    @Default('') String licenseNumber,
    @NullableTimestampConverter() DateTime? licenseExpiry,
    @Default(DriverStatus.inactive) DriverStatus status,
    @Default('') String statusReason,
    String? assignedTruckId,
    @Default('') String assignedTruckPlate,
    @Default(TruckType.unknown) TruckType truckType,

    /// Set while the chofer owns a job. Its presence is what blocks a second
    /// offer, going offline, and being deactivated.
    String? currentServiceId,
    @Default(false) bool isOnline,
    @Default(4.8) double rating,
    @Default(0) int ratingCount,
    @Default(0) int completedServices,

    /// Rolling 30-day dispatch behaviour, used in the admin panel and
    /// eventually as a scoring input.
    @Default(0) int offersSent,
    @Default(0) int offersAccepted,
    @Default(0) int cancellations,

    /// Cash the chofer has collected but not yet handed in. When this passes
    /// the configured limit they stop receiving cash jobs.
    @Default(0) int cashOwedCents,
    @Default(<String>[]) List<String> zones,
    @Default('') String createdBy,
    @NullableTimestampConverter() DateTime? createdAt,
    @NullableTimestampConverter() DateTime? updatedAt,
    @NullableTimestampConverter() DateTime? lastOnlineAt,
    @Default(false) bool mustChangePassword,
    @Default(false) bool archived,
  }) = _Driver;

  const Driver._();

  factory Driver.fromJson(Map<String, dynamic> json) => _$DriverFromJson(json);

  bool get isBusy => currentServiceId != null && currentServiceId!.isNotEmpty;

  bool get canGoOnline => status.canWork && assignedTruckId != null;

  bool get isDispatchable => status.canWork && isOnline && !isBusy;

  /// Share of offers this chofer actually took. Low numbers mean either a
  /// notification problem or a chofer cherry-picking; both need looking at.
  double get acceptanceRate =>
      offersSent == 0 ? 1 : offersAccepted / offersSent;

  String get acceptanceLabel => '${(acceptanceRate * 100).round()}%';

  String get shortName {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length <= 1) return name.trim();
    return '${parts.first} ${parts[1]}';
  }

  /// Cédula formatted the way it appears on the card: `001-1234567-8`.
  String get displayCedula {
    final digits = cedula.replaceAll(RegExp(r'\D'), '');
    if (digits.length != 11) return cedula;
    return '${digits.substring(0, 3)}-${digits.substring(3, 10)}-${digits.substring(10)}';
  }
}

/// One uploaded document at `drivers/{uid}/documents/{docType}`.
@freezed
abstract class DriverDocument with _$DriverDocument {
  const factory DriverDocument({
    required DriverDocumentType type,
    @Default('') String storagePath,
    @Default('') String fileName,
    @Default(0) int sizeBytes,
    @Default('') String contentType,
    @Default(DocumentReviewState.pending) DocumentReviewState state,
    @Default('') String rejectionReason,
    @Default('') String uploadedBy,
    @Default('') String reviewedBy,
    @NullableTimestampConverter() DateTime? uploadedAt,
    @NullableTimestampConverter() DateTime? reviewedAt,
    @NullableTimestampConverter() DateTime? issuedAt,
    @NullableTimestampConverter() DateTime? expiresAt,
  }) = _DriverDocument;

  const DriverDocument._();

  factory DriverDocument.fromJson(Map<String, dynamic> json) =>
      _$DriverDocumentFromJson(json);

  bool get isVerified => state == DocumentReviewState.verified;

  /// Days until expiry; negative once expired. Null when no expiry applies.
  int? daysUntilExpiry(DateTime now) {
    final expiry = expiresAt;
    if (expiry == null) return null;
    return expiry.difference(DateTime.utc(now.year, now.month, now.day)).inDays;
  }

  bool isExpired(DateTime now) => (daysUntilExpiry(now) ?? 1) < 0;

  /// The 30-day warning window the scheduled sweeper notifies on.
  bool isExpiringSoon(DateTime now) {
    final days = daysUntilExpiry(now);
    return days != null && days >= 0 && days <= 30;
  }

  /// An expired required document takes the chofer offline automatically —
  /// a grúa on the road with lapsed seguro is a liability, not a reminder.
  bool blocksWork(DateTime now) => type.required && (isExpired(now) || !isVerified);
}

/// A chofer's live position, mirrored from Realtime Database `/live/{driverId}`.
///
/// This is not a Firestore document. It is written at up to 0.2 Hz per chofer,
/// which is why it lives in RTDB: the same traffic in Firestore would dominate
/// the bill for a fleet of any size.
@freezed
abstract class DriverLivePosition with _$DriverLivePosition {
  const factory DriverLivePosition({
    required String driverId,
    required double lat,
    required double lng,
    @Default('') String geohash,
    @Default(0) double heading,
    @Default(0) double speedKmh,
    @Default(0) double accuracy,
    @Default(false) bool isOnline,
    @Default(DriverLiveState.idle) DriverLiveState state,
    @Default(TruckType.unknown) TruckType truckType,
    String? serviceId,

    /// Epoch milliseconds. RTDB has no Timestamp type.
    @Default(0) int updatedAt,
  }) = _DriverLivePosition;

  const DriverLivePosition._();

  factory DriverLivePosition.fromJson(Map<String, dynamic> json) =>
      _$DriverLivePositionFromJson(json);

  LatLng get position => LatLng(lat, lng);

  DateTime get updatedAtUtc =>
      DateTime.fromMillisecondsSinceEpoch(updatedAt, isUtc: true);

  /// A phone that lost signal is not dispatchable, whatever `isOnline` says.
  /// The dispatcher applies the same 90-second rule server-side.
  bool isStale(DateTime now, {Duration threshold = const Duration(seconds: 90)}) =>
      now.difference(updatedAtUtc) > threshold;

  bool isDispatchable(DateTime now) =>
      isOnline && state == DriverLiveState.idle && !isStale(now);
}
