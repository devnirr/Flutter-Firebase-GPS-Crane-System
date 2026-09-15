import 'package:freezed_annotation/freezed_annotation.dart';

import '../../data/converters.dart';
import '../enums.dart';
import '../value_objects.dart';

part 'remote_config_models.freezed.dart';
part 'remote_config_models.g.dart';

/// Tariffs at `config/pricing`. Mirrors `PricingConfig` in
/// `functions/src/lib/pricing.ts`.
///
/// [version] is stamped onto every quote so a service priced last month never
/// re-prices when the tariff changes. Bump it whenever any amount below moves.
@freezed
abstract class PricingConfig with _$PricingConfig {
  const factory PricingConfig({
    @Default(2) int version,

    /// Tarifa base per vehicle type, keyed by [VehicleType.wire]. It includes
    /// the first [includedKm] kilometres.
    @Default(<String, int>{
      'sedan': 150000,
      'suv': 180000,
      'camioneta': 200000,
      'motor': 150000,
      'camion': 500000,
      'patana': 800000,
      'equipo_pesado': 1000000,
    })
    Map<String, int> baseCentsByVehicleType,

    /// Per kilometre past the included ones, on city streets.
    @Default(<String, int>{
      'sedan': 7000,
      'suv': 7000,
      'camioneta': 7000,
      'motor': 7000,
      'camion': 25000,
      'patana': 40000,
      'equipo_pesado': 60000,
    })
    Map<String, int> cityPerKmCentsByVehicleType,

    /// Per kilometre past the included ones, on carretera and autopista.
    @Default(<String, int>{
      'sedan': 13000,
      'suv': 13000,
      'camioneta': 13000,
      'motor': 13000,
      'camion': 25000,
      'patana': 40000,
      'equipo_pesado': 60000,
    })
    Map<String, int> highwayPerKmCentsByVehicleType,
    @Default(5) double includedKm,

    /// The least any service costs, before surcharges.
    @Default(150000) int minimumCents,

    /// Night surcharges on the total, between [nightStartHour] and
    /// [nightEndHour] in America/Santo_Domingo. 3000 = 30%.
    @Default(3000) int lightNightSurchargeBps,
    @Default(4000) int heavyNightSurchargeBps,
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

  int baseCentsFor(VehicleType type) => _rate(baseCentsByVehicleType, type);

  int cityPerKmCentsFor(VehicleType type) =>
      _rate(cityPerKmCentsByVehicleType, type);

  int highwayPerKmCentsFor(VehicleType type) =>
      _rate(highwayPerKmCentsByVehicleType, type);

  /// A type the table does not name is priced as a carro.
  static int _rate(Map<String, int> rates, VehicleType type) =>
      rates[type.wire] ?? rates[VehicleType.sedan.wire] ?? 0;

  int nightSurchargeBpsFor(VehicleType type) =>
      type.isHeavy ? heavyNightSurchargeBps : lightNightSurchargeBps;

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
    @Default(60000) int offerTtlMs,
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
