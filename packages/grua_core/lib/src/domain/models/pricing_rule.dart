import 'package:flutter/foundation.dart';

import '../enums.dart';

/// One row of the insurer zone tariff, at `pricingRules/{id}`: the price of one
/// distance zone for one class of vehicle.
///
/// Mirrors `PricingRule` in `functions/src/lib/zonePricing.ts`.
@immutable
class PricingRule {
  const PricingRule({
    required this.vehicleClass,
    required this.zoneMinKm,
    required this.zoneMaxKm,
    required this.baseCents,
    this.extraKmCents = 0,
    this.insurerId,
  });

  factory PricingRule.fromJson(Map<String, dynamic> json) => PricingRule(
        vehicleClass: VehicleClass.fromWire(json['vehicleClass'] as String?),
        zoneMinKm: (json['zoneMinKm'] as num? ?? 0).toInt(),
        zoneMaxKm: (json['zoneMaxKm'] as num?)?.toInt(),
        baseCents: (json['baseCents'] as num? ?? 0).round(),
        extraKmCents: (json['extraKmCents'] as num? ?? 0).round(),
        insurerId: json['insurerId'] as String?,
      );

  final VehicleClass vehicleClass;
  final int zoneMinKm;

  /// `null` for the last, open-ended zone.
  final int? zoneMaxKm;
  final int baseCents;

  /// Per kilometre past [zoneMinKm]. Zero for a flat-priced zone.
  final int extraKmCents;

  /// `null` for the default list every company is billed on.
  final String? insurerId;

  bool get isOpenEnded => zoneMaxKm == null;

  /// The document id: the table, the class and the zone.
  String get id => '${insurerId ?? 'default'}__${vehicleClass.wire}__$zoneMinKm';

  /// `0–10 km`, or `+50 km` for the open zone.
  String get zoneLabel =>
      zoneMaxKm == null ? '+$zoneMinKm km' : '$zoneMinKm–$zoneMaxKm km';

  Map<String, Object?> toJson() => {
        'vehicleClass': vehicleClass.wire,
        'zoneMinKm': zoneMinKm,
        'zoneMaxKm': zoneMaxKm,
        'baseCents': baseCents,
        'extraKmCents': extraKmCents,
        'insurerId': insurerId,
      };

  @override
  bool operator ==(Object other) =>
      other is PricingRule &&
      other.vehicleClass == vehicleClass &&
      other.zoneMinKm == zoneMinKm &&
      other.zoneMaxKm == zoneMaxKm &&
      other.baseCents == baseCents &&
      other.extraKmCents == extraKmCents &&
      other.insurerId == insurerId;

  @override
  int get hashCode => Object.hash(
        vehicleClass,
        zoneMinKm,
        zoneMaxKm,
        baseCents,
        extraKmCents,
        insurerId,
      );

  @override
  String toString() => 'PricingRule($id, $baseCents + $extraKmCents/km)';
}
