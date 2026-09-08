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

  group('night surcharge', () {
    test('is not applied during the day', () {
      final quote = Pricing.quoteFor(
        config: config,
        truckType: TruckType.gancho,
        distanceKm: 10,
        at: atLocalHour(14),
        chargeItbis: false,
      );
      expect(quote.surcharges.any((s) => s.code == 'nocturno'), isFalse);
    });

    test('starts exactly at 22:00 local, not 22:00 UTC', () {
      final justBefore = Pricing.quoteFor(
        config: config,
        truckType: TruckType.gancho,
        distanceKm: 10,
        at: atLocalHour(21),
        chargeItbis: false,
      );
      final atBoundary = Pricing.quoteFor(
        config: config,
        truckType: TruckType.gancho,
        distanceKm: 10,
        at: atLocalHour(22),
        chargeItbis: false,
      );

      expect(justBefore.surcharges.any((s) => s.code == 'nocturno'), isFalse);
      expect(atBoundary.surcharges.any((s) => s.code == 'nocturno'), isTrue);
      expect(atBoundary.totalCents, greaterThan(justBefore.totalCents));
    });

    test('spans midnight and ends at 06:00 local', () {
      for (final hour in [23, 0, 3, 5]) {
        final quote = Pricing.quoteFor(
          config: config,
          truckType: TruckType.gancho,
          distanceKm: 10,
          at: atLocalHour(hour),
          chargeItbis: false,
        );
        expect(
          quote.surcharges.any((s) => s.code == 'nocturno'),
          isTrue,
          reason: '$hour:00 local should be a night hour',
        );
      }

      final morning = Pricing.quoteFor(
        config: config,
        truckType: TruckType.gancho,
        distanceKm: 10,
        at: atLocalHour(6),
        chargeItbis: false,
      );
      expect(morning.surcharges.any((s) => s.code == 'nocturno'), isFalse);
    });
  });

  group('distance', () {
    test('the included kilometres are free', () {
      final short = Pricing.quoteFor(
        config: config,
        truckType: TruckType.gancho,
        distanceKm: config.includedKm,
        at: atLocalHour(12),
        chargeItbis: false,
      );
      expect(short.distanceCents, 0);
      expect(short.totalCents, config.baseCentsFor(TruckType.gancho));
    });

    test('only the excess is charged', () {
      final quote = Pricing.quoteFor(
        config: config,
        truckType: TruckType.gancho,
        distanceKm: config.includedKm + 10,
        at: atLocalHour(12),
        chargeItbis: false,
      );
      expect(quote.distanceCents, 10 * config.perKmCentsFor(TruckType.gancho));
    });

    test('a heavy tow costs more than a hook tow for the same distance', () {
      int totalFor(TruckType type) => Pricing.quoteFor(
            config: config,
            truckType: type,
            distanceKm: 20,
            at: atLocalHour(12),
            chargeItbis: false,
          ).totalCents;

      expect(totalFor(TruckType.pesada), greaterThan(totalFor(TruckType.plataforma)));
      expect(totalFor(TruckType.plataforma), greaterThan(totalFor(TruckType.gancho)));
    });
  });

  group('waiting time', () {
    test('the free window costs nothing', () {
      final quote = Pricing.quoteFor(
        config: config,
        truckType: TruckType.gancho,
        distanceKm: 10,
        at: atLocalHour(12),
        waitingMinutes: config.freeWaitingMinutes,
        chargeItbis: false,
      );
      expect(quote.surcharges.any((s) => s.code == 'espera'), isFalse);
    });

    test('only the minutes past the free window are billed', () {
      final quote = Pricing.quoteFor(
        config: config,
        truckType: TruckType.gancho,
        distanceKm: 10,
        at: atLocalHour(12),
        waitingMinutes: config.freeWaitingMinutes + 7,
        chargeItbis: false,
      );
      final espera =
          quote.surcharges.firstWhere((s) => s.code == 'espera');
      expect(espera.cents, 7 * config.perWaitingMinuteCents);
    });
  });

  group('ITBIS', () {
    test('is 18% of the subtotal when a fiscal receipt is issued', () {
      final quote = Pricing.quoteFor(
        config: config,
        truckType: TruckType.gancho,
        distanceKm: 20,
        at: atLocalHour(12),
      );
      expect(quote.itbisCents, (quote.subtotalCents * 0.18).round());
      expect(quote.totalCents, quote.subtotalCents + quote.itbisCents);
    });

    test('is omitted otherwise', () {
      final quote = Pricing.quoteFor(
        config: config,
        truckType: TruckType.gancho,
        distanceKm: 20,
        at: atLocalHour(12),
        chargeItbis: false,
      );
      expect(quote.itbisCents, 0);
      expect(quote.totalCents, quote.subtotalCents);
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
