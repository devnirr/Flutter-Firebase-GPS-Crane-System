import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';

/// The insurer zone tariff, run against the examples the server also runs.
///
/// `functions/test/zonePricing.test.ts` reads the same file, so a price that
/// changes on one side only fails a test on the other.
void main() {
  final fixture = jsonDecode(
    File('test/fixtures/zone_pricing_cases.json').readAsStringSync(),
  ) as Map<String, dynamic>;

  List<PricingRule> rulesOf(Object? json) => [
        for (final row in json! as List<dynamic>)
          PricingRule.fromJson(row as Map<String, dynamic>),
      ];

  VehicleType vehicle(String wire) => VehicleType.fromWire(wire);

  group('the default table', () {
    test('is the table in the shared examples', () {
      expect(ZonePricing.defaultRules, rulesOf(fixture['defaultRules']));
    });

    test('is complete for every priced class', () {
      for (final vehicleClass in VehicleClass.priced) {
        expect(
          ZonePricing.tableProblem(ZonePricing.defaultRulesFor(vehicleClass)),
          isNull,
          reason: vehicleClass.wire,
        );
      }
    });

    test('has a row id per zone, matching the server', () {
      final ids = ZonePricing.defaultRules.map((r) => r.id).toSet();
      expect(ids, hasLength(ZonePricing.defaultRules.length));
      expect(ZonePricing.defaultRules.first.id, 'default__light__0');
    });

    test('labels zones the way the price list does', () {
      final light = ZonePricing.defaultRulesFor(VehicleClass.light);
      expect(light.first.zoneLabel, '0–10 km');
      expect(light.last.zoneLabel, '+50 km');
    });
  });

  group('VehicleClass.of', () {
    final classes = fixture['vehicleClasses'] as Map<String, dynamic>;
    for (final entry in classes.entries) {
      test('prices ${entry.key} as ${entry.value ?? 'nothing'}', () {
        final expected = entry.value == null
            ? VehicleClass.unknown
            : VehicleClass.fromWire(entry.value as String);
        expect(VehicleClass.of(vehicle(entry.key)), expected);
      });
    }

    test('every vehicle type the app offers has a column', () {
      for (final type in VehicleType.values) {
        if (type == VehicleType.unknown) continue;
        expect(VehicleClass.priced, contains(VehicleClass.of(type)), reason: type.wire);
      }
    });
  });

  group('ZonePricing.quote on the default table', () {
    for (final raw in fixture['defaultCases'] as List<dynamic>) {
      final c = raw as Map<String, dynamic>;
      test(c['name'] as String, () {
        final vehicleClass = VehicleClass.of(vehicle(c['vehicleType'] as String));
        final quote = ZonePricing.quote(
          rules: ZonePricing.defaultRulesFor(vehicleClass),
          distanceKm: (c['distanceKm'] as num).toDouble(),
          tariff: ZoneTariffSource.standard,
        );

        expect(quote.vehicleClass, vehicleClass);
        expect(quote.zoneMinKm, c['zoneMinKm']);
        expect(quote.distanceKm, (c['distanceOut'] as num).toDouble());
        expect(quote.extraKm, (c['extraKm'] as num).toDouble());
        expect(quote.extraCents, c['extraCents']);
        expect(quote.subtotalCents, c['subtotalCents']);
        expect(quote.tariff.wire, 'default');
      });
    }

    test('refuses a distance that is not a distance', () {
      final rules = ZonePricing.defaultRulesFor(VehicleClass.light);
      for (final d in [-1.0, double.nan, double.infinity]) {
        expect(
          () => ZonePricing.quote(rules: rules, distanceKm: d, tariff: ZoneTariffSource.standard),
          throwsRangeError,
          reason: '$d',
        );
      }
    });
  });

  group('ZonePricing.quote on other tables', () {
    for (final rawTable in fixture['customTables'] as List<dynamic>) {
      final table = rawTable as Map<String, dynamic>;
      for (final raw in table['cases'] as List<dynamic>) {
        final c = raw as Map<String, dynamic>;
        test('${table['name']}: ${c['distanceKm']} km', () {
          final quote = ZonePricing.quote(
            rules: rulesOf(table['rules']),
            distanceKm: (c['distanceKm'] as num).toDouble(),
            tariff: ZoneTariffSource.insurer,
          );
          expect(quote.zoneMinKm, c['zoneMinKm']);
          expect(quote.extraCents, c['extraCents']);
          expect(quote.subtotalCents, c['subtotalCents']);
        });
      }
    }
  });

  group('ZonePricing.tableProblem', () {
    for (final raw in fixture['invalidTables'] as List<dynamic>) {
      final table = raw as Map<String, dynamic>;
      test('refuses a table: ${table['name']}', () {
        final rules = rulesOf(table['rules']);
        expect(ZonePricing.tableProblem(rules), isA<String>());
        expect(
          () => ZonePricing.quote(
            rules: rules,
            distanceKm: 5,
            tariff: ZoneTariffSource.standard,
          ),
          throwsA(isA<ZoneTableException>()),
        );
      });
    }
  });

  group('ZonePricing.withItbis', () {
    for (final raw in fixture['itbis'] as List<dynamic>) {
      final c = raw as Map<String, dynamic>;
      test('${c['subtotalCents']} + 18%', () {
        final totals = ZonePricing.withItbis(c['subtotalCents'] as int);
        expect(totals.itbisCents, c['itbisCents']);
        expect(totals.totalCents, c['totalCents']);
      });
    }
  });

  group('ZonePricing.driverPayoutCents', () {
    test('defaults to 70%', () {
      expect(ZonePricing.defaultDriverPayoutBps, 7000);
    });

    for (final raw in fixture['payouts'] as List<dynamic>) {
      final c = raw as Map<String, dynamic>;
      test('${c['driverPayoutBps']} bps of ${c['subtotalCents']}', () {
        expect(
          ZonePricing.driverPayoutCents(
            c['subtotalCents'] as int,
            c['driverPayoutBps'] as int,
          ),
          c['driverPayoutCents'],
        );
      });
    }
  });

  group('PricingRule', () {
    test('reads what it writes', () {
      for (final rule in ZonePricing.defaultRules) {
        expect(PricingRule.fromJson(rule.toJson()), rule);
      }
    });

    test('an unknown class reads as unknown and cannot be priced', () {
      final rule = PricingRule.fromJson(const {
        'vehicleClass': 'moto',
        'zoneMinKm': 0,
        'zoneMaxKm': null,
        'baseCents': 1,
        'extraKmCents': 0,
        'insurerId': null,
      });
      expect(rule.vehicleClass, VehicleClass.unknown);
      expect(VehicleClass.priced, isNot(contains(rule.vehicleClass)));
    });
  });

  test('the collection name matches the backend', () {
    expect(Paths.pricingRulesCollection, 'pricingRules');
  });
}
