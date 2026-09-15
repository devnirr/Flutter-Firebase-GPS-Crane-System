import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';

/// Pricing and Dominican time handling.
///
/// These are the pure functions most likely to be wrong in a way nobody notices
/// until a customer disputes an invoice, so they are tested at the boundaries
/// rather than in the middle.
void main() {
  const config = PricingConfig();

  /// A UTC instant for a given Dominican wall-clock hour. Santo Domingo is
  /// UTC-4 year round, so 22:00 local is 02:00 UTC the next day.
  DateTime atLocalHour(int hour, {int day = 15}) =>
      DoTime.fromLocal(DateTime.utc(2026, 6, day, hour));

  /// A trip entirely on city streets.
  TripDistance city(double km) => TripDistance.city(km, includedKm: config.includedKm);

  Quote quote(
    VehicleType type,
    TripDistance distance, {
    int hour = 12,
    int waitingMinutes = 0,
    bool chargeItbis = false,
  }) =>
      Pricing.quoteFor(
        config: config,
        vehicleType: type,
        distance: distance,
        at: atLocalHour(hour),
        waitingMinutes: waitingMinutes,
        chargeItbis: chargeItbis,
      );

  group('the tariff', () {
    test(r"prices the owner's example: a carro, 8 km in the city, RD$1,710", () {
      final q = quote(VehicleType.sedan, city(8));
      expect(q.distanceKm, 8);
      expect(q.cityKm, 3);
      expect(q.highwayKm, 0);
      expect(q.totalCents, 171000);
      expect(q.totalCents.formatDOPShort, r'RD$1,710');
      expect(q.distanceLabel, '8 km');
    });

    test('the first 5 km are in each tarifa base', () {
      expect(quote(VehicleType.sedan, city(5)).totalCents, 150000);
      expect(quote(VehicleType.suv, city(5)).totalCents, 180000);
      expect(quote(VehicleType.camioneta, city(5)).totalCents, 200000);
      expect(quote(VehicleType.sedan, city(1)).totalCents, 150000);
    });

    test(r'carretera kilometres cost RD$130 and city ones RD$70', () {
      final distance = TripDistance.fromStretches(
        [(meters: 10000, highway: false), (meters: 10000, highway: true)],
        includedKm: 5,
      );
      expect(distance.cityKm, 5);
      expect(distance.highwayKm, 10);
      expect(
        quote(VehicleType.sedan, distance).totalCents,
        150000 + 5 * 7000 + 10 * 13000,
      );
    });

    test('the included kilometres come off the start of the trip', () {
      final distance = TripDistance.fromStretches(
        [(meters: 5000, highway: true), (meters: 10000, highway: false)],
        includedKm: 5,
      );
      expect(distance.distanceKm, 15);
      expect(distance.cityKm, 10);
      expect(distance.highwayKm, 0);
    });

    test('agrees with the server on rounding to tenths of a kilometre', () {
      expect(TripDistance.city(8.049, includedKm: 5).distanceKm, 8);
      expect(TripDistance.city(8.05, includedKm: 5).distanceKm, 8.1);
    });

    test('the breakdown names each road and its rate', () {
      final distance = TripDistance.fromStretches(
        [(meters: 10000, highway: false), (meters: 10000, highway: true)],
        includedKm: 5,
      );
      final lines = quote(VehicleType.sedan, distance).breakdown;
      expect(lines.map((l) => l.label), [
        'Tarifa base (incluye 5 km)',
        r'Ciudad 5 km × RD$70',
        r'Carretera 10 km × RD$130',
      ]);
      expect(lines.map((l) => l.cents), [150000, 35000, 130000]);
    });
  });

  group('night surcharge', () {
    test('is 30% of the total for a light vehicle', () {
      final q = quote(VehicleType.sedan, city(8), hour: 23);
      final night = q.surcharges.firstWhere((s) => s.code == 'nocturno');
      expect(night.label, 'Recargo nocturno (30%)');
      expect(night.cents, 51300);
      expect(q.totalCents, 222300);
    });

    test('is not applied during the day', () {
      expect(
        quote(VehicleType.sedan, city(10), hour: 14)
            .surcharges
            .any((s) => s.code == 'nocturno'),
        isFalse,
      );
    });

    test('starts exactly at 22:00 local, not 22:00 UTC', () {
      final justBefore = quote(VehicleType.sedan, city(10), hour: 21);
      final atBoundary = quote(VehicleType.sedan, city(10), hour: 22);
      expect(justBefore.surcharges.any((s) => s.code == 'nocturno'), isFalse);
      expect(atBoundary.surcharges.any((s) => s.code == 'nocturno'), isTrue);
    });

    test('spans midnight and ends at 06:00 local', () {
      for (final hour in [23, 0, 3, 5]) {
        expect(
          quote(VehicleType.sedan, city(10), hour: hour)
              .surcharges
              .any((s) => s.code == 'nocturno'),
          isTrue,
          reason: '$hour:00 local should be a night hour',
        );
      }
      expect(
        quote(VehicleType.sedan, city(10), hour: 6)
            .surcharges
            .any((s) => s.code == 'nocturno'),
        isFalse,
      );
    });

    test('is rounded to whole pesos', () {
      final q = quote(VehicleType.sedan, city(8.1), hour: 23);
      expect(q.surcharges.firstWhere((s) => s.code == 'nocturno').cents, 51500);
    });
  });

  group('vehículos pesados', () {
    test('start at their minimums', () {
      expect(quote(VehicleType.camion, city(5)).totalCents, 500000);
      expect(quote(VehicleType.patana, city(5)).totalCents, 800000);
      expect(quote(VehicleType.equipoPesado, city(5)).totalCents, 1000000);
    });

    test(r'charge RD$250, RD$400 and RD$600 a km past 5, on any road', () {
      final distance = TripDistance.fromStretches(
        [(meters: 5000, highway: false), (meters: 5000, highway: true)],
        includedKm: 5,
      );
      expect(quote(VehicleType.camion, distance).totalCents, 500000 + 5 * 25000);
      expect(quote(VehicleType.patana, distance).totalCents, 800000 + 5 * 40000);
      expect(
        quote(VehicleType.equipoPesado, distance).totalCents,
        1000000 + 5 * 60000,
      );
      // One rate, so one line.
      expect(
        quote(VehicleType.patana, distance).breakdown.map((l) => l.label),
        ['Tarifa base (incluye 5 km)', r'Recorrido 5 km × RD$400'],
      );
    });

    test('add 40% at night', () {
      final q = quote(VehicleType.camion, city(5), hour: 23);
      expect(
        q.surcharges.firstWhere((s) => s.code == 'nocturno').label,
        'Recargo nocturno (40%)',
      );
      expect(q.totalCents, 700000);
    });

    test('are estimates, and a light vehicle is not', () {
      expect(quote(VehicleType.equipoPesado, city(5)).heavy, isTrue);
      expect(quote(VehicleType.suv, city(5)).heavy, isFalse);
    });

    test("the operator's price replaces the total and keeps the estimate", () {
      final estimate = quote(VehicleType.camion, city(10));
      final confirmed = Pricing.confirmed(estimate, 900000);
      expect(confirmed.totalCents, 900000);
      expect(confirmed.baseCents, estimate.baseCents);
      expect(
        confirmed.surcharges.singleWhere((s) => s.code == 'ajuste_operador').cents,
        900000 - estimate.totalCents,
      );
      final again = Pricing.confirmed(confirmed, 800000);
      expect(again.totalCents, 800000);
      expect(again.surcharges.where((s) => s.code == 'ajuste_operador'), hasLength(1));
    });
  });

  test('no service costs less than the minimum', () {
    final cheap = config.copyWith(
      baseCentsByVehicleType: {...config.baseCentsByVehicleType, 'motor': 90000},
    );
    final q = Pricing.quoteFor(
      config: cheap,
      vehicleType: VehicleType.motor,
      distance: city(6),
      at: atLocalHour(12),
      chargeItbis: false,
    );
    expect(q.minimumAdjustmentCents, 150000 - 90000 - 7000);
    expect(q.totalCents, 150000);
  });

  group('waiting time', () {
    test('the free window costs nothing', () {
      expect(
        quote(VehicleType.sedan, city(10), waitingMinutes: config.freeWaitingMinutes)
            .surcharges
            .any((s) => s.code == 'espera'),
        isFalse,
      );
    });

    test('only the minutes past the free window are billed', () {
      final q = quote(
        VehicleType.sedan,
        city(10),
        waitingMinutes: config.freeWaitingMinutes + 7,
      );
      expect(
        q.surcharges.firstWhere((s) => s.code == 'espera').cents,
        7 * config.perWaitingMinuteCents,
      );
    });
  });

  group('ITBIS', () {
    test('is 18% of the subtotal when a fiscal receipt is issued', () {
      final q = quote(VehicleType.sedan, city(20), chargeItbis: true);
      expect(q.itbisCents, (q.subtotalCents * 0.18).round());
      expect(q.totalCents, q.subtotalCents + q.itbisCents);
    });

    test('is omitted otherwise', () {
      final q = quote(VehicleType.sedan, city(20));
      expect(q.itbisCents, 0);
      expect(q.totalCents, q.subtotalCents);
    });
  });

  group('cancellation', () {
    test('is free inside the grace period', () {
      final acceptedAt = DateTime.utc(2026, 6, 15, 12);
      final fee = Pricing.cancellationFeeCents(
        config: config,
        acceptedAt: acceptedAt,
        now: acceptedAt.add(const Duration(minutes: 2)),
      );
      expect(fee, 0);
    });

    test('applies once the chofer has been on the way past the grace period',
        () {
      final acceptedAt = DateTime.utc(2026, 6, 15, 12);
      final fee = Pricing.cancellationFeeCents(
        config: config,
        acceptedAt: acceptedAt,
        now: acceptedAt.add(const Duration(minutes: 5)),
      );
      expect(fee, config.cancellationFeeCents);
    });

    test('is free when no chofer ever accepted', () {
      expect(
        Pricing.cancellationFeeCents(
          config: config,
          acceptedAt: null,
          now: DateTime.utc(2026, 6, 15, 12),
        ),
        0,
      );
    });
  });

  group('money', () {
    test('formats Dominican pesos the way the DR writes them', () {
      // Symbol first, comma thousands, period decimals — not the European
      // layout intl's es_DO data would produce.
      expect(249999.formatDOP, r'RD$ 2,499.99');
      expect(1500000.formatDOPCompact, r'RD$ 15,000');
      // The price summary's tight form: centavos only when there are some.
      expect(171000.formatDOPShort, r'RD$1,710');
      expect(171050.formatDOPShort, r'RD$1,710.50');
    });

    test('basis points are exact at awkward rates', () {
      // 12.5% of RD$ 1,000.00
      expect(Money.bps(100000, 1250), 12500);
      expect(Money.itbis(100000), 18000);
    });

    test('rounds up to a cashable amount', () {
      expect(Money.roundToCashable(249999), 250000);
      expect(Money.roundToCashable(250000), 250000);
    });
  });

  group('Dominican time', () {
    test('is UTC-4 with no daylight saving', () {
      final january = DoTime.toLocal(DateTime.utc(2026, 1, 15, 16));
      final july = DoTime.toLocal(DateTime.utc(2026, 7, 15, 16));
      expect(january.hour, 12);
      expect(july.hour, 12);
    });

    test('the rollup day boundary follows local midnight', () {
      // 03:00 UTC is still the previous day in Santo Domingo.
      expect(DoTime.dateKey(DateTime.utc(2026, 9, 9, 3)), '2026-09-08');
      expect(DoTime.dateKey(DateTime.utc(2026, 9, 9, 5)), '2026-09-09');
    });

    test('round-trips local wall clock through UTC', () {
      final local = DateTime.utc(2026, 9, 8, 22, 30);
      expect(DoTime.toLocal(DoTime.fromLocal(local)), local);
    });
  });

  group('truck type inference', () {
    test('a heavy vehicle always needs the heavy grúa', () {
      for (final type in VehicleType.heavy) {
        for (final condition in VehicleCondition.values) {
          expect(
            ServiceVehicle(type: type, condition: condition).inferredTruckType,
            TruckType.pesada,
          );
        }
      }
    });

    test('matches the model-level rule', () {
      for (final condition in VehicleCondition.values) {
        for (final type in VehicleType.values) {
          expect(
            Pricing.inferTruckType(vehicleType: type, condition: condition),
            ServiceVehicle(type: type, condition: condition).inferredTruckType,
            reason: 'server and app must agree for $type / $condition',
          );
        }
      }
    });
  });
}
