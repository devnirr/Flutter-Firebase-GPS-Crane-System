import 'package:freezed_annotation/freezed_annotation.dart';

import '../../data/converters.dart';
import '../../utils/money.dart';
import '../enums.dart';

part 'billing.freezed.dart';
part 'billing.g.dart';

@freezed
abstract class InvoiceLine with _$InvoiceLine {
  const factory InvoiceLine({
    required String code,
    required String label,
    @Default(1) num quantity,
    @CentsConverter() @Default(0) int unitCents,
    @CentsConverter() @Default(0) int totalCents,
  }) = _InvoiceLine;

  const InvoiceLine._();

  factory InvoiceLine.fromJson(Map<String, dynamic> json) =>
      _$InvoiceLineFromJson(json);
}

/// A Dominican tax receipt at `invoices/{invoiceId}`.
///
/// The NCF is allocated transactionally from a sequence in `config/ncf`, so two
/// services completing in the same second can never share one. Note that this
/// produces the *document*; DGII e-CF electronic filing is a separate
/// compliance project.
@freezed
abstract class Invoice with _$Invoice {
  const factory Invoice({
    required String id,
    required String serviceId,
    required String clientId,
    @Default('') String serviceCode,

    /// Número de Comprobante Fiscal, e.g. `B0200000123`.
    @Default('') String ncf,
    @Default(NcfType.consumo) NcfType ncfType,
    @Default('') String clientName,
    @Default('') String clientRnc,
    @Default('') String clientAddress,
    @Default(<InvoiceLine>[]) List<InvoiceLine> lines,
    @CentsConverter() @Default(0) int subtotalCents,
    @CentsConverter() @Default(0) int itbisCents,
    @CentsConverter() @Default(0) int totalCents,
    @Default('DOP') String currency,
    @Default(PaymentMethod.cash) PaymentMethod paymentMethod,
    @Default('') String pdfPath,
    @NullableTimestampConverter() DateTime? issuedAt,
    @NullableTimestampConverter() DateTime? createdAt,
  }) = _Invoice;

  const Invoice._();

  factory Invoice.fromJson(Map<String, dynamic> json) => _$InvoiceFromJson(json);

  bool get hasPdf => pdfPath.isNotEmpty;

  bool get isFiscal => ncfType == NcfType.creditoFiscal;

  String get totalLabel => totalCents.formatDOP;

  /// `B0200000123` reads better as `B02-00000123` on a printed receipt.
  String get displayNcf {
    if (ncf.length < 4) return ncf;
    return '${ncf.substring(0, 3)}-${ncf.substring(3)}';
  }
}

/// One completed job's money, at `earnings/{driverId}/entries/{serviceId}`.
///
/// Written by a trigger keyed on the service id, which makes it idempotent: a
/// retried trigger overwrites rather than double-paying.
@freezed
abstract class EarningEntry with _$EarningEntry {
  const factory EarningEntry({
    required String serviceId,
    required String driverId,
    @Default('') String serviceCode,
    @CentsConverter() @Default(0) int grossCents,
    @CentsConverter() @Default(0) int commissionCents,
    @CentsConverter() @Default(0) int netCents,
    @Default(PaymentMethod.cash) PaymentMethod method,
    @Default('') String pickupAddress,
    @Default('') String dropoffAddress,
    @Default(false) bool settled,
    String? settlementId,
    @NullableTimestampConverter() DateTime? completedAt,
    @NullableTimestampConverter() DateTime? settledAt,
  }) = _EarningEntry;

  const EarningEntry._();

  factory EarningEntry.fromJson(Map<String, dynamic> json) =>
      _$EarningEntryFromJson(json);

  /// On a cash job the chofer holds the customer's money and owes the company
  /// its commission. On a card job the company holds it and owes the chofer
  /// the net. Same entry, opposite direction — this is the distinction the
  /// office actually reconciles.
  bool get driverOwesCompany => method == PaymentMethod.cash;

  int get balanceEffectCents =>
      driverOwesCompany ? commissionCents : -netCents;
}

/// Rollup totals at `earnings/{driverId}`, maintained by the same trigger.
///
/// The driver app reads these instead of summing history client-side — a chofer
/// two years in would otherwise pull thousands of documents to draw one card.
@freezed
abstract class EarningsSummary with _$EarningsSummary {
  const factory EarningsSummary({
    required String driverId,
    @CentsConverter() @Default(0) int todayGrossCents,
    @CentsConverter() @Default(0) int todayNetCents,
    @Default(0) int todayServices,
    @CentsConverter() @Default(0) int weekGrossCents,
    @CentsConverter() @Default(0) int weekNetCents,
    @Default(0) int weekServices,
    @CentsConverter() @Default(0) int monthGrossCents,
    @CentsConverter() @Default(0) int monthNetCents,
    @Default(0) int monthServices,
    @CentsConverter() @Default(0) int lifetimeNetCents,

    /// Cash collected but not yet handed in. The number the office chases.
    @CentsConverter() @Default(0) int cashOwedCents,
    @Default(<int>[]) List<int> last7DaysNetCents,
    @NullableTimestampConverter() DateTime? updatedAt,
  }) = _EarningsSummary;

  const EarningsSummary._();

  factory EarningsSummary.fromJson(Map<String, dynamic> json) =>
      _$EarningsSummaryFromJson(json);

  bool get owesCash => cashOwedCents > 0;

  String get cashOwedLabel => cashOwedCents.formatDOP;
}
