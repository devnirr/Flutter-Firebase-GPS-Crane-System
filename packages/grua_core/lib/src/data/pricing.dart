import '../domain/enums.dart';
import '../domain/models/remote_config_models.dart';
import '../domain/models/service.dart';
import '../utils/date_time_do.dart';
import '../utils/money.dart';

/// The pricing formula, in one place.
///
/// This is a port of `functions/src/lib/pricing.ts`, and the two must stay
/// identical: the app uses it to show a customer what a tow will cost before
/// they commit, and the server uses it to decide what to actually charge. When
/// they disagree the server wins, and the customer sees a price change at the
/// worst possible moment — so any edit here is an edit there.
///
/// The tariff: a tarifa base per vehicle type that includes the first 5 km and
/// is never below the minimum; each kilometre after that at the city or the
/// carretera rate; and at night, 30% on top for a light vehicle and 40% for a
/// heavy one, whose price is only an estimate until the operator confirms it.
///
/// Everything is integer DOP cents.
abstract final class Pricing {
  /// Builds a full quote for a tow.
  ///
  /// [at] must be an instant, not a local wall clock: night-rate boundaries are
  /// evaluated in `America/Santo_Domingo`, which is where a UTC-based
  /// implementation quietly applies the 22:00 surcharge at 6 p.m.
  static Quote quoteFor({
    required PricingConfig config,
    required VehicleType vehicleType,
    required TripDistance distance,
    required DateTime at,
    bool chargeItbis = true,
    int waitingMinutes = 0,
    int tollsCents = 0,
  }) {
    final baseCents = config.baseCentsFor(vehicleType);
    final cityPerKmCents = config.cityPerKmCentsFor(vehicleType);
    final highwayPerKmCents = config.highwayPerKmCentsFor(vehicleType);

    final distanceCents = (distance.cityKm * cityPerKmCents).round() +
        (distance.highwayKm * highwayPerKmCents).round();
    final minimumAdjustment =
        (config.minimumCents - (baseCents + distanceCents)).clamp(0, 1 << 40);
    // What the percentages are taken from: the tow itself.
    final fareCents = baseCents + distanceCents + minimumAdjustment;

    final surcharges = <QuoteSurcharge>[];

    final local = DoTime.toLocal(at);
    if (config.isNightHour(local.hour)) {
      final rate = config.nightSurchargeBpsFor(vehicleType);
      surcharges.add(
        QuoteSurcharge(
          code: 'nocturno',
          label: 'Recargo nocturno (${_percent(rate)}%)',
          cents: toPeso(Money.bps(fareCents, rate)),
        ),
      );
    }

    if (config.holidayDates.contains(DoTime.dateKey(at))) {
      surcharges.add(
        QuoteSurcharge(
          code: 'feriado',
          label: 'Recargo por día feriado',
          cents: toPeso(Money.bps(fareCents, config.holidaySurchargeBps)),
        ),
      );
    }

    final billableWaiting =
        (waitingMinutes - config.freeWaitingMinutes).clamp(0, 1 << 30);
    if (billableWaiting > 0) {
      surcharges.add(
        QuoteSurcharge(
          code: 'espera',
          label: 'Tiempo de espera ($billableWaiting min)',
          cents: billableWaiting * config.perWaitingMinuteCents,
        ),
      );
    }

    if (tollsCents > 0) {
      surcharges.add(
        QuoteSurcharge(code: 'peajes', label: 'Peajes', cents: tollsCents),
      );
    }

    final surchargeTotal = surcharges.fold(0, (sum, s) => sum + s.cents);
    final subtotal = fareCents + surchargeTotal;
    final itbis = (chargeItbis && config.chargeItbis) ? Money.itbis(subtotal) : 0;

    return Quote(
      pricingVersion: config.version,
      vehicleType: vehicleType,
      heavy: vehicleType.isHeavy,
      baseCents: baseCents,
      includedKm: config.includedKm,
      perKmCents: cityPerKmCents,
      cityPerKmCents: cityPerKmCents,
      highwayPerKmCents: highwayPerKmCents,
      distanceKm: distance.distanceKm,
      cityKm: distance.cityKm,
      highwayKm: distance.highwayKm,
      distanceCents: distanceCents,
      minimumAdjustmentCents: minimumAdjustment,
      surcharges: surcharges,
      subtotalCents: subtotal,
      itbisCents: itbis,
      totalCents: subtotal + itbis,
    );
  }

  /// To the nearest whole peso: nobody hands a chofer 51 centavos.
  static int toPeso(int cents) => ((cents + 50) ~/ 100) * 100;

  static String _percent(int bps) =>
      bps % 100 == 0 ? '${bps ~/ 100}' : (bps / 100).toStringAsFixed(1);

  /// The quote with the total an operator confirmed for a heavy job. Mirrors
  /// `confirmedQuote` on the server: the difference is its own line, and the
  /// figure is what the customer pays, ITBIS included when there is any.
  static Quote confirmed(Quote quote, int totalCents) {
    final subtotal = quote.itbisCents > 0
        ? (totalCents * 10000 / (10000 + 1800)).round()
        : totalCents;
    final previous = quote.surcharges
        .where((s) => s.code == 'ajuste_operador')
        .fold(0, (sum, s) => sum + s.cents);
    final line = subtotal - quote.subtotalCents + previous;
    return quote.copyWith(
      surcharges: [
        ...quote.surcharges.where((s) => s.code != 'ajuste_operador'),
        if (line != 0)
          QuoteSurcharge(
            code: 'ajuste_operador',
            label: 'Ajuste confirmado por el operador',
            cents: line,
          ),
      ],
      subtotalCents: subtotal,
      itbisCents: quote.itbisCents > 0 ? totalCents - subtotal : 0,
      totalCents: totalCents,
    );
  }

  /// What a client owes for cancelling after the grace period.
  static int cancellationFeeCents({
    required PricingConfig config,
    required DateTime? acceptedAt,
    required DateTime now,
  }) {
    if (acceptedAt == null) return 0;
    final grace = Duration(minutes: config.cancellationGraceMinutes);
    if (now.difference(acceptedAt) <= grace) return 0;
    return config.cancellationFeeCents;
  }

  /// How much to hold on the card at accept time: the quote plus headroom for
  /// waiting and reroutes, so a normal job needs one authorization and one
  /// capture rather than a second charge the customer did not expect.
  static int authorizationAmountCents({
    required PricingConfig config,
    required int quoteTotalCents,
  }) =>
      quoteTotalCents + Money.bps(quoteTotalCents, config.authorizationBufferBps);

  /// The company's cut of a completed job.
  static int commissionCents({
    required PricingConfig config,
    required int grossCents,
  }) =>
      Money.bps(grossCents, config.commissionBps);

  /// The truck type a vehicle needs. Mirrors [ServiceVehicle.inferredTruckType]
  /// and exists so the server can call the same rule without a model instance.
  static TruckType inferTruckType({
    required VehicleType vehicleType,
    required VehicleCondition condition,
  }) {
    if (vehicleType.isHeavy) return TruckType.pesada;
    if (condition.requiresFlatbed) return TruckType.plataforma;
    return TruckType.gancho;
  }
}
