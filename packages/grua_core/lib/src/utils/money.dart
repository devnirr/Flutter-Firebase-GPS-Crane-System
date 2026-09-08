import 'package:intl/intl.dart';

/// Money in this system is always an `int` of Dominican peso **cents**.
///
/// Doubles are banned: `0.1 + 0.2` is not `0.3`, and a tow that costs
/// RD$ 2,499.99 must not become RD$ 2,499.98999999 in a ledger the office
/// reconciles by hand. Every field that holds money is named `*Cents`, and this
/// extension is the only sanctioned way to turn one into text.
extension MoneyCents on int {
  static final NumberFormat _dop = NumberFormat.currency(
    locale: 'es_DO',
    symbol: r'RD$ ',
    decimalDigits: 2,
  );

  static final NumberFormat _dopCompact = NumberFormat.currency(
    locale: 'es_DO',
    symbol: r'RD$ ',
    decimalDigits: 0,
  );

  /// `249999` -> `RD$ 2,499.99`.
  String get formatDOP => _dop.format(this / 100);

  /// `249999` -> `RD$ 2,500`. For dense tables and chart axes, never for a
  /// figure someone is about to pay or be paid.
  String get formatDOPCompact => _dopCompact.format((this / 100).round());

  /// The peso part only, for split displays like a large "2,500" over a small
  /// "RD$".
  String get formatDOPAmountOnly =>
      NumberFormat.decimalPattern('es_DO').format(this / 100);

  double get asPesos => this / 100;
}

/// Helpers for building money values without scattering `* 100` through the code.
abstract final class Money {
  static const int zero = 0;

  /// `Money.pesos(2500)` -> `250000` cents.
  static int pesos(num amount) => (amount * 100).round();

  /// Applies a basis-point rate. `Money.bps(100000, 1500)` takes 15% of
  /// RD$ 1,000.00 and returns `15000`.
  ///
  /// Basis points keep commission configuration exact — 12.5% is `1250`, with
  /// no float anywhere in the calculation.
  static int bps(int cents, int basisPoints) =>
      (cents * basisPoints / 10000).round();

  /// Dominican ITBIS, 18%, applied only when a fiscal receipt is issued.
  static const int itbisBps = 1800;

  static int itbis(int subtotalCents) => bps(subtotalCents, itbisBps);

  /// Rounds up to the nearest RD$ 5 — Dominican cash reality, where a chofer
  /// carrying exact change for RD$ 2,499.99 does not exist.
  static int roundToCashable(int cents) {
    const step = 500;
    final remainder = cents % step;
    return remainder == 0 ? cents : cents + (step - remainder);
  }

  /// Change breakdown for the notes a customer is likely to hand over, largest
  /// first. Used by the chofer's cash-collection screen.
  static const List<int> commonBillsCents = [
    200000, // RD$ 2,000
    100000, // RD$ 1,000
    50000, // RD$ 500
    20000, // RD$ 200
    10000, // RD$ 100
    5000, // RD$ 50
  ];
}
