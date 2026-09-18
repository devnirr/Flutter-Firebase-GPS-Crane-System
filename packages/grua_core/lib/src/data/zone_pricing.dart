import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../domain/enums.dart';
import '../domain/models/pricing_rule.dart';
import '../utils/money.dart';
import 'pricing.dart';

/// Which table a zone price came from.
enum ZoneTariffSource {
  /// The company's negotiated prices.
  insurer('insurer'),

  /// The default list. (`default` is a Dart keyword.)
  standard('default');

  const ZoneTariffSource(this.wire);

  final String wire;
}

/// What one trip costs an insurance company, before ITBIS.
@immutable
class ZoneQuote {
  const ZoneQuote({
    required this.vehicleClass,
    required this.tariff,
    required this.distanceKm,
    required this.zoneMinKm,
    required this.zoneMaxKm,
    required this.baseCents,
    required this.extraKm,
    required this.extraKmCents,
    required this.extraCents,
    required this.subtotalCents,
  });

  final VehicleClass vehicleClass;
  final ZoneTariffSource tariff;

  /// The road distance, to a tenth of a kilometre.
  final double distanceKm;
  final int zoneMinKm;
  final int? zoneMaxKm;
  final int baseCents;

  /// Kilometres past the start of the zone, to a tenth.
  final double extraKm;
  final int extraKmCents;
  final int extraCents;
  final int subtotalCents;
}

/// Subtotal + ITBIS (18%) = Total.
@immutable
class ItbisTotals {
  const ItbisTotals({
    required this.subtotalCents,
    required this.itbisCents,
    required this.totalCents,
  });

  final int subtotalCents;
  final int itbisCents;
  final int totalCents;
}

/// Thrown for a table that does not cover every distance exactly once.
class ZoneTableException implements Exception {
  const ZoneTableException(this.message);

  final String message;

  @override
  String toString() => 'ZoneTableException: $message';
}

/// The tariff insurance companies are billed on: fixed prices by distance
/// zone.
///
/// A port of `functions/src/lib/zonePricing.ts`; the two run the same cases
/// from `test/fixtures/zone_pricing_cases.json`. The panel uses this to show a
/// price before a tow is ordered, and the server decides what is billed — so
/// any edit here is an edit there.
///
///     price = base + (km past the start of the zone) × extra rate
///
/// Everything is integer DOP cents; distances are worked in tenths of a
/// kilometre.
abstract final class ZonePricing {
  static PricingRule _row(
    VehicleClass vehicleClass,
    int zoneMinKm,
    int? zoneMaxKm,
    int basePesos, [
    int extraKmPesos = 0,
  ]) =>
      PricingRule(
        vehicleClass: vehicleClass,
        zoneMinKm: zoneMinKm,
        zoneMaxKm: zoneMaxKm,
        baseCents: Money.pesos(basePesos),
        extraKmCents: Money.pesos(extraKmPesos),
      );

  /// "Tabla de precios base — sin ITBIS". Used for any class the stored
  /// default has no rows for.
  static final List<PricingRule> defaultRules = List.unmodifiable([
    _row(VehicleClass.light, 0, 10, 2500),
    _row(VehicleClass.light, 10, 25, 3500),
    _row(VehicleClass.light, 25, 50, 5500),
    _row(VehicleClass.light, 50, null, 5500, 120),
    _row(VehicleClass.suv, 0, 10, 3200),
    _row(VehicleClass.suv, 10, 25, 4500),
    _row(VehicleClass.suv, 25, 50, 7000),
    _row(VehicleClass.suv, 50, null, 7000, 150),
    _row(VehicleClass.heavy, 0, 10, 5500),
    _row(VehicleClass.heavy, 10, 25, 7000),
    _row(VehicleClass.heavy, 25, 50, 11000),
    _row(VehicleClass.heavy, 50, null, 11000, 250),
  ]);

  static List<PricingRule> defaultRulesFor(VehicleClass vehicleClass) => [
        for (final rule in defaultRules)
          if (rule.vehicleClass == vehicleClass) rule,
      ];

  static List<PricingRule> _sorted(List<PricingRule> rules) =>
      [...rules]..sort((a, b) => a.zoneMinKm.compareTo(b.zoneMinKm));

  /// Why [rules] cannot price one class of vehicle, or `null` when they can.
  static String? tableProblem(List<PricingRule> rules) {
    if (rules.isEmpty) return 'La tabla no tiene zonas.';

    final first = rules.first;
    if (rules.any(
      (r) => r.vehicleClass != first.vehicleClass || r.insurerId != first.insurerId,
    )) {
      return 'La tabla mezcla tipos de vehículo o aseguradoras.';
    }

    final sorted = _sorted(rules);
    if (sorted.first.zoneMinKm != 0) return 'La primera zona debe empezar en 0 km.';

    for (var i = 0; i < sorted.length; i++) {
      final zone = sorted[i];
      final last = i == sorted.length - 1;
      final max = zone.zoneMaxKm;

      if (max == null) {
        if (!last) {
          return 'Solo la última zona puede no tener límite (${zone.zoneMinKm} km).';
        }
        continue;
      }
      if (max <= zone.zoneMinKm) {
        return 'La zona ${zone.zoneMinKm}–$max km termina antes de empezar.';
      }
      if (last) return 'La última zona debe quedar abierta (sin kilómetro máximo).';

      final next = sorted[i + 1];
      if (next.zoneMinKm != max) {
        return 'Las zonas no son continuas entre $max y ${next.zoneMinKm} km.';
      }
    }
    return null;
  }

  /// Prices one trip on one class's table.
  ///
  /// A zone includes its upper bound: exactly 10 km is in 0–10. Throws
  /// [ZoneTableException] for a table [tableProblem] refuses.
  static ZoneQuote quote({
    required List<PricingRule> rules,
    required double distanceKm,
    required ZoneTariffSource tariff,
  }) {
    final problem = tableProblem(rules);
    if (problem != null) throw ZoneTableException(problem);
    if (!distanceKm.isFinite || distanceKm < 0) {
      throw RangeError.value(distanceKm, 'distanceKm', 'must be a non-negative number');
    }

    final tenths = (distanceKm * 10).round();
    final zone = _sorted(rules).firstWhere(
      (r) => r.zoneMaxKm == null || tenths <= r.zoneMaxKm! * 10,
    );

    // math.max, not clamp(0, 1 << 40): compiled to JavaScript the shift is
    // 32-bit, the bound becomes 0, and every extra kilometre is dropped.
    final extraTenths = math.max(0, tenths - zone.zoneMinKm * 10);
    final extraCents = Pricing.toPeso((extraTenths * zone.extraKmCents / 10).round());

    return ZoneQuote(
      vehicleClass: zone.vehicleClass,
      tariff: tariff,
      distanceKm: tenths / 10,
      zoneMinKm: zone.zoneMinKm,
      zoneMaxKm: zone.zoneMaxKm,
      baseCents: zone.baseCents,
      extraKm: extraTenths / 10,
      extraKmCents: zone.extraKmCents,
      extraCents: extraCents,
      subtotalCents: zone.baseCents + extraCents,
    );
  }

  /// The chofer's share of an insurer's tow when the company sets none.
  static const int defaultDriverPayoutBps = 7000;

  /// What the chofer is paid of [subtotalCents], rounded to the peso; the
  /// company keeps the rest. Mirrors `payoutSplit` in
  /// `functions/src/lib/insurerService.ts`.
  static int driverPayoutCents(int subtotalCents, int driverPayoutBps) {
    final raw = Money.bps(subtotalCents, driverPayoutBps);
    final pesos = Pricing.toPeso(raw);
    return pesos > subtotalCents ? subtotalCents : pesos;
  }

  /// The tax at the foot of an invoice, applied once to the subtotal.
  static ItbisTotals withItbis(int subtotalCents) {
    final itbis = Money.itbis(subtotalCents);
    return ItbisTotals(
      subtotalCents: subtotalCents,
      itbisCents: itbis,
      totalCents: subtotalCents + itbis,
    );
  }
}
