import 'package:freezed_annotation/freezed_annotation.dart';

import '../../data/converters.dart';
import '../enums.dart';
import '../value_objects.dart';

part 'remote_config_models.freezed.dart';
part 'remote_config_models.g.dart';

/// Tariffs at `config/pricing`.
///
/// [version] is stamped onto every quote so a service priced last month never
/// re-prices when the tariff changes. Bump it whenever any amount below moves.
@freezed
abstract class PricingConfig with _$PricingConfig {
  const factory PricingConfig({
    @Default(1) int version,

    /// Banderazo per truck type, keyed by [TruckType.wire].
    @Default(<String, int>{
      'plataforma': 180000,
      'gancho': 150000,
      'pesada': 450000,
    })
    Map<String, int> baseCentsByTruckType,
    @Default(5) double includedKm,
    @Default(<String, int>{
      'plataforma': 6500,
      'gancho': 5500,
      'pesada': 14000,
    })
    Map<String, int> perKmCentsByTruckType,

    /// Night surcharge as a percentage of the base, applied between
    /// [nightStartHour] and [nightEndHour] in America/Santo_Domingo.
    @Default(2500) int nightSurchargeBps,
    @Default(22) int nightStartHour,
    @Default(6) int nightEndHour,
    @Default(2000) int holidaySurchargeBps,
    @Default(<String>[]) List<String> holidayDates,
    @Default(10) int freeWaitingMinutes,
    @Default(2500) int perWaitingMinuteCents,

    /// Company commission on each job, in basis points. 2000 = 20%.
    @Default(2000) int commissionBps,

    /// Cancellation fee once the grace period after acceptance has passed.
    @Default(50000) int cancellationFeeCents,
    @Default(3) int cancellationGraceMinutes,

    /// Extra headroom authorized on a card at accept time, to cover waiting
    /// and reroutes without a second charge. 1500 = 15%.
    @Default(1500) int authorizationBufferBps,

    /// A chofer holding more than this in undeposited cash stops receiving
    /// cash jobs.
    @Default(1500000) int maxCashOwedCents,
    @Default(true) bool chargeItbis,
    @NullableTimestampConverter() DateTime? updatedAt,
  }) = _PricingConfig;

  const PricingConfig._();

  factory PricingConfig.fromJson(Map<String, dynamic> json) =>
      _$PricingConfigFromJson(json);

  int baseCentsFor(TruckType type) =>
      baseCentsByTruckType[type.wire] ?? baseCentsByTruckType['gancho'] ?? 150000;

  int perKmCentsFor(TruckType type) =>
      perKmCentsByTruckType[type.wire] ?? perKmCentsByTruckType['gancho'] ?? 5500;

  /// Night rate spans midnight, so the comparison is an OR, not a range.
  bool isNightHour(int localHour) =>
      localHour >= nightStartHour || localHour < nightEndHour;
}

/// Dispatch tuning at `config/dispatch`.
///
/// Every one of these is a lever the operator will want to pull once real
/// traffic arrives, which is why none of them is a constant in code.
@freezed
abstract class DispatchConfig with _$DispatchConfig {
  const factory DispatchConfig({
    /// How long a chofer has to answer. Long enough to look up from the wheel,
    /// short enough that a client is not waiting three minutes on a cascade.
    @Default(25000) int offerTtlMs,
    @Default(5) double startRadiusKm,
    @Default(40) double maxRadiusKm,
    @Default(8) int maxRounds,
    @Default(360000) int maxDispatchMs,
    @Default(15000) int retryDelayMs,

    /// Guard for "Llegué". Urban Dominican GPS is not better than this.
    @Default(300) int arrivalRadiusM,
    @Default(500) int completionRadiusM,

    /// A position older than this is not dispatchable regardless of `isOnline`.
    @Default(90000) int stalePositionMs,

    /// Candidate scoring weights. They must sum to 1.
    @Default(0.70) double weightDistance,
    @Default(0.20) double weightRating,
    @Default(0.10) double weightIdleTime,
    @NullableTimestampConverter() DateTime? updatedAt,
  }) = _DispatchConfig;

  const DispatchConfig._();

  factory DispatchConfig.fromJson(Map<String, dynamic> json) =>
      _$DispatchConfigFromJson(json);

  Duration get offerTtl => Duration(milliseconds: offerTtlMs);

  int get offerTtlSeconds => (offerTtlMs / 1000).round();

  bool get weightsAreValid =>
      ((weightDistance + weightRating + weightIdleTime) - 1.0).abs() < 0.001;
}

/// A coverage polygon. Requests outside every zone are refused up front rather
/// than accepted and then stranded.
@freezed
abstract class CoverageZone with _$CoverageZone {
  const factory CoverageZone({
    required String id,
    required String name,
    @Default(<LatLng>[]) List<LatLng> polygon,
    @Default(true) bool active,

    /// During a pilot only the listed zones dispatch, so a staged rollout does
    /// not need a release.
    @Default(false) bool pilotOnly,
  }) = _CoverageZone;

  const CoverageZone._();

  factory CoverageZone.fromJson(Map<String, dynamic> json) =>
      _$CoverageZoneFromJson(json);

  /// Ray-casting point-in-polygon. Used in the app for immediate feedback; the
  /// server re-checks before accepting the request.
  bool contains(LatLng point) {
    if (polygon.length < 3) return false;
    var inside = false;
    for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      final pi = polygon[i];
      final pj = polygon[j];
      final intersects = (pi.longitude > point.longitude) !=
              (pj.longitude > point.longitude) &&
          point.latitude <
              (pj.latitude - pi.latitude) *
                      (point.longitude - pi.longitude) /
                      (pj.longitude - pi.longitude) +
                  pi.latitude;
      if (intersects) inside = !inside;
    }
    return inside;
  }
}

/// Operational switches at `config/app`.
///
/// These are read at startup and on every foreground, so the office can stop
/// taking new requests or force an update without shipping a build.
@freezed
abstract class AppSettings with _$AppSettings {
  const factory AppSettings({
    @Default(false) bool maintenanceMode,
    @Default('') String maintenanceMessage,
    @Default('1.0.0') String minSupportedClientVersion,
    @Default('1.0.0') String minSupportedDriverVersion,
    @Default(true) bool enableCardPayments,
    @Default(true) bool enableChat,
    @Default(true) bool enableCalls,
    @Default(<CoverageZone>[]) List<CoverageZone> zones,

    /// When non-empty, dispatch is restricted to these zone ids — the staged
    /// pilot switch.
    @Default(<String>[]) List<String> launchZoneIds,
    @Default('+18095550100') String supportPhone,
    @Default('') String supportWhatsapp,
    @Default('1.0') String termsVersion,
    @Default(<String>[]) List<String> requiredDriverDocuments,
    @NullableTimestampConverter() DateTime? updatedAt,
  }) = _AppSettings;

  const AppSettings._();

  factory AppSettings.fromJson(Map<String, dynamic> json) =>
      _$AppSettingsFromJson(json);

  List<CoverageZone> get activeZones => zones.where((z) => z.active).toList();

  /// True when the point falls inside any active, currently-dispatching zone.
  bool isCovered(LatLng point) {
    final candidates = launchZoneIds.isEmpty
        ? activeZones
        : activeZones.where((z) => launchZoneIds.contains(z.id));
    // With no zones configured at all, treat the whole country as covered so a
    // fresh environment is usable before someone draws the polygons.
    if (candidates.isEmpty) {
      return DoLocations.isPlausiblyInDominicanRepublic(point);
    }
    return candidates.any((z) => z.contains(point));
  }

  CoverageZone? zoneFor(LatLng point) {
    for (final zone in activeZones) {
      if (zone.contains(point)) return zone;
    }
    return null;
  }
}
