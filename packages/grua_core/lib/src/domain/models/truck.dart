import 'package:freezed_annotation/freezed_annotation.dart';

import '../../data/converters.dart';
import '../enums.dart';

part 'truck.freezed.dart';
part 'truck.g.dart';

/// A grúa at `trucks/{truckId}`.
///
/// [type] is the field dispatch filters candidates on, which is why it may not
/// be changed while the assigned chofer is online — a job offered on the
/// assumption of a flatbed cannot arrive as a wheel-lift.
@freezed
abstract class Truck with _$Truck {
  const factory Truck({
    required String id,
    required String plate,
    @Default('') String make,
    @Default('') String model,
    int? year,
    @Default('') String color,
    @JsonKey(unknownEnumValue: TruckType.unknown)
    @Default(TruckType.gancho) TruckType type,
    @Default(0) int capacityKg,
    @Default(true) bool active,
    @Default('') String inactiveReason,
    String? assignedDriverId,
    @Default('') String assignedDriverName,
    @Default(<String>[]) List<String> photoPaths,
    @Default('') String insurancePolicy,
    @NullableTimestampConverter() DateTime? insuranceExpiry,
    @NullableTimestampConverter() DateTime? marbeteExpiry,
    @Default('') String registrationNumber,
    @Default(0) int completedServices,
    @Default('') String createdBy,
    @NullableTimestampConverter() DateTime? createdAt,
    @NullableTimestampConverter() DateTime? updatedAt,
    @Default(false) bool archived,
  }) = _Truck;

  const Truck._();

  factory Truck.fromJson(Map<String, dynamic> json) => _$TruckFromJson(json);

  bool get isAssigned =>
      assignedDriverId != null && assignedDriverId!.isNotEmpty;

  /// "Ford F-350 2019 · Plataforma"
  String get displayName {
    final parts = [
      if (make.isNotEmpty) make,
      if (model.isNotEmpty) model,
      if (year != null) '$year',
    ].join(' ');
    return parts.isEmpty ? type.label : '$parts · ${type.label}';
  }

  /// Dominican plates read as `L123456`; display them uppercased and trimmed.
  String get displayPlate => plate.trim().toUpperCase();

  double get capacityTons => capacityKg / 1000;

  /// The soonest of the two legal expiries, which is what the fleet list sorts
  /// and badges on.
  DateTime? get nextExpiry {
    final dates = [insuranceExpiry, marbeteExpiry].whereType<DateTime>().toList()
      ..sort();
    return dates.isEmpty ? null : dates.first;
  }

  int? daysUntilNextExpiry(DateTime now) {
    final next = nextExpiry;
    if (next == null) return null;
    return next.difference(DateTime.utc(now.year, now.month, now.day)).inDays;
  }

  bool hasExpiringPaperwork(DateTime now) {
    final days = daysUntilNextExpiry(now);
    return days != null && days <= 30;
  }

  bool hasExpiredPaperwork(DateTime now) => (daysUntilNextExpiry(now) ?? 1) < 0;

  bool get isDispatchable => active && !archived && type.isDispatchable;
}
