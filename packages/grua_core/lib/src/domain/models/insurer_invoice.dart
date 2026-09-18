import 'package:flutter/foundation.dart';

import '../../data/converters.dart';
import '../../utils/money.dart';
import '../enums.dart';

int _cents(Object? value) => (value as num? ?? 0).round();

String _text(Object? value) => value is String ? value : '';

/// One service on a monthly invoice: a tow, or a late cancellation's fee.
@immutable
class InsurerInvoiceLine {
  const InsurerInvoiceLine({
    required this.serviceId,
    required this.kind,
    required this.amountCents,
    this.serviceCode = '',
    this.finishedAt,
    this.claimNumber = '',
    this.policyNumber = '',
    this.insuredName = '',
    this.plate = '',
    this.vehicle = '',
    this.pickupAddress = '',
    this.dropoffAddress = '',
    this.distanceKm = 0,
    this.zoneLabel = '',
    this.vehicleClass = '',
    this.tariff = '',
    this.baseCents = 0,
    this.extraKm = 0,
    this.extraCents = 0,
  });

  factory InsurerInvoiceLine.fromJson(Map<String, dynamic> json) => InsurerInvoiceLine(
        serviceId: _text(json['serviceId']),
        kind: InsurerInvoiceLineKind.fromWire(json['kind'] as String?),
        amountCents: _cents(json['amountCents']),
        serviceCode: _text(json['serviceCode']),
        finishedAt: const NullableTimestampConverter().fromJson(json['finishedAt']),
        claimNumber: _text(json['claimNumber']),
        policyNumber: _text(json['policyNumber']),
        insuredName: _text(json['insuredName']),
        plate: _text(json['plate']),
        vehicle: _text(json['vehicle']),
        pickupAddress: _text(json['pickupAddress']),
        dropoffAddress: _text(json['dropoffAddress']),
        distanceKm: (json['distanceKm'] as num? ?? 0).toDouble(),
        zoneLabel: _text(json['zoneLabel']),
        vehicleClass: _text(json['vehicleClass']),
        tariff: _text(json['tariff']),
        baseCents: _cents(json['baseCents']),
        extraKm: (json['extraKm'] as num? ?? 0).toDouble(),
        extraCents: _cents(json['extraCents']),
      );

  final String serviceId;
  final InsurerInvoiceLineKind kind;

  /// What the line adds, before ITBIS.
  final int amountCents;
  final String serviceCode;

  /// When the tow was delivered, or cancelled.
  final DateTime? finishedAt;
  final String claimNumber;
  final String policyNumber;
  final String insuredName;
  final String plate;

  /// `Toyota Corolla`, or the kind of vehicle when the make is unknown.
  final String vehicle;
  final String pickupAddress;
  final String dropoffAddress;
  final double distanceKm;

  /// `0–10 km`.
  final String zoneLabel;

  /// `Vehículo ligero`.
  final String vehicleClass;

  /// `insurer` for the company's negotiated prices, `default` for the list.
  final String tariff;

  /// The zone's price, and what the kilometres past its start added. Zero
  /// on a cancellation.
  final int baseCents;
  final double extraKm;
  final int extraCents;

  /// `Acordada`, `Base`, or empty when unknown.
  String get tariffLabel => switch (tariff) {
        'insurer' => 'Acordada',
        'default' => 'Base',
        _ => '',
      };

  bool get isCancellation => kind == InsurerInvoiceLineKind.cancellation;

  /// What the line says it is for.
  String get description => isCancellation
      ? 'Cargo por cancelación'
      : [
          'Servicio de grúa',
          if (zoneLabel.isNotEmpty) zoneLabel,
          if (vehicleClass.isNotEmpty) vehicleClass,
        ].join(' · ');
}

/// The company that issued an invoice, as it was printed on it.
@immutable
class InvoiceIssuer {
  const InvoiceIssuer({
    this.name = '',
    this.rnc = '',
    this.address = '',
    this.phone = '',
    this.email = '',
  });

  factory InvoiceIssuer.fromJson(Map<String, dynamic> json) => InvoiceIssuer(
        name: _text(json['name']),
        rnc: _text(json['rnc']),
        address: _text(json['address']),
        phone: _text(json['phone']),
        email: _text(json['email']),
      );

  final String name;

  /// Empty while the company is being registered.
  final String rnc;
  final String address;
  final String phone;
  final String email;

  /// `1-30-00000-1`, or a note that it is on its way.
  String get rncLabel => rnc.isEmpty ? 'En trámite' : formatRnc(rnc);
}

/// `130000001` as the DGII prints it: `1-30-00000-1`.
String formatRnc(String rnc) => rnc.length == 9
    ? '${rnc.substring(0, 1)}-${rnc.substring(1, 3)}-'
        '${rnc.substring(3, 8)}-${rnc.substring(8)}'
    : rnc;

/// One row of the zone prices an invoice was billed on, as they stood when it
/// was issued.
@immutable
class InvoiceTariffRow {
  const InvoiceTariffRow({
    required this.vehicleClass,
    required this.zoneMinKm,
    required this.baseCents,
    this.zoneMaxKm,
    this.extraKmCents = 0,
    this.source = '',
  });

  factory InvoiceTariffRow.fromJson(Map<String, dynamic> json) => InvoiceTariffRow(
        vehicleClass: VehicleClass.fromWire(json['vehicleClass'] as String?),
        zoneMinKm: _cents(json['zoneMinKm']),
        zoneMaxKm: (json['zoneMaxKm'] as num?)?.round(),
        baseCents: _cents(json['baseCents']),
        extraKmCents: _cents(json['extraKmCents']),
        source: _text(json['source']),
      );

  final VehicleClass vehicleClass;
  final int zoneMinKm;
  final int? zoneMaxKm;
  final int baseCents;
  final int extraKmCents;

  /// `insurer` or `default`.
  final String source;

  /// `0–10 km`, or `+50 km`.
  String get zoneLabel =>
      zoneMaxKm == null ? '+$zoneMinKm km' : '$zoneMinKm–$zoneMaxKm km';

  bool get isNegotiated => source == 'insurer';
}

/// A monthly invoice to an insurance company, at `insurerInvoices/{id}`.
///
/// Written only by the invoicing callables. Mirrors
/// `functions/src/callables/insurerInvoices.ts`.
@immutable
class InsurerInvoice {
  const InsurerInvoice({
    required this.id,
    required this.insurerId,
    required this.ncf,
    this.insurerName = '',
    this.insurerRnc = '',
    this.billingEmail = '',
    this.periodKey = '',
    this.periodLabel = '',
    this.periodStart,
    this.periodEnd,
    this.cutoff,
    this.ncfType = NcfType.creditoFiscal,
    this.isTestNcf = true,
    this.ncfExpiresOn,
    this.issuer = const InvoiceIssuer(),
    this.lines = const [],
    this.tariffTable = const [],
    this.towCount = 0,
    this.cancellationCount = 0,
    this.subtotalCents = 0,
    this.itbisCents = 0,
    this.totalCents = 0,
    this.status = InsurerInvoiceStatus.unknown,
    this.paymentTermsDays = 30,
    this.dueAt,
    this.paymentReference = '',
    this.note = '',
    this.voidReason = '',
    this.issuedAt,
    this.paidAt,
    this.voidedAt,
    this.createdAt,
  });

  factory InsurerInvoice.fromJson(String id, Map<String, dynamic> json) {
    const ts = NullableTimestampConverter();
    return InsurerInvoice(
      id: id,
      insurerId: _text(json['insurerId']),
      insurerName: _text(json['insurerName']),
      insurerRnc: _text(json['insurerRnc']),
      billingEmail: _text(json['billingEmail']),
      periodKey: _text(json['periodKey']),
      periodLabel: _text(json['periodLabel']),
      periodStart: ts.fromJson(json['periodStart']),
      periodEnd: ts.fromJson(json['periodEnd']),
      cutoff: ts.fromJson(json['cutoff']),
      ncf: _text(json['ncf']),
      ncfType: NcfType.fromWire(json['ncfType'] as String?),
      // Anything not explicitly real is shown as a test: a test receipt
      // passed off as fiscal is the mistake that matters.
      isTestNcf: json['isTestNcf'] != false,
      ncfExpiresOn: json['ncfExpiresOn'] as String?,
      issuer: InvoiceIssuer.fromJson(
        Map<String, dynamic>.from(json['issuer'] as Map? ?? const {}),
      ),
      lines: [
        for (final line in json['lines'] as List<dynamic>? ?? const [])
          InsurerInvoiceLine.fromJson(Map<String, dynamic>.from(line as Map)),
      ],
      tariffTable: [
        for (final row in json['tariffTable'] as List<dynamic>? ?? const [])
          InvoiceTariffRow.fromJson(Map<String, dynamic>.from(row as Map)),
      ],
      towCount: _cents(json['towCount']),
      cancellationCount: _cents(json['cancellationCount']),
      subtotalCents: _cents(json['subtotalCents']),
      itbisCents: _cents(json['itbisCents']),
      totalCents: _cents(json['totalCents']),
      status: InsurerInvoiceStatus.fromWire(json['status'] as String?),
      paymentTermsDays: _cents(json['paymentTermsDays'] ?? 30),
      dueAt: ts.fromJson(json['dueAt']),
      paymentReference: _text(json['paymentReference']),
      note: _text(json['note']),
      voidReason: _text(json['voidReason']),
      issuedAt: ts.fromJson(json['issuedAt']),
      paidAt: ts.fromJson(json['paidAt']),
      voidedAt: ts.fromJson(json['voidedAt']),
      createdAt: ts.fromJson(json['createdAt']),
    );
  }

  final String id;
  final String insurerId;
  final String insurerName;
  final String insurerRnc;
  final String billingEmail;

  /// `2026-09`.
  final String periodKey;

  /// `septiembre 2026`.
  final String periodLabel;
  final DateTime? periodStart;
  final DateTime? periodEnd;

  /// Services finished before this instant are on the invoice.
  final DateTime? cutoff;

  /// `B0100000001`.
  final String ncf;
  final NcfType ncfType;

  /// Numbered from a made-up range while the company has no DGII
  /// authorisation: `is_test_ncf`.
  final bool isTestNcf;

  /// `2027-12-31`: the last day the NCF's range is valid. Null on a test one.
  final String? ncfExpiresOn;
  final InvoiceIssuer issuer;
  final List<InsurerInvoiceLine> lines;

  /// The zone prices the lines were billed on. Empty on invoices issued
  /// before it was kept.
  final List<InvoiceTariffRow> tariffTable;
  final int towCount;
  final int cancellationCount;
  final int subtotalCents;
  final int itbisCents;
  final int totalCents;
  final InsurerInvoiceStatus status;
  final int paymentTermsDays;
  final DateTime? dueAt;

  /// The transfer that paid it.
  final String paymentReference;
  final String note;
  final String voidReason;
  final DateTime? issuedAt;
  final DateTime? paidAt;
  final DateTime? voidedAt;
  final DateTime? createdAt;

  bool get isIssued => status == InsurerInvoiceStatus.issued;

  bool get isPaid => status == InsurerInvoiceStatus.paid;

  bool get isVoided => status == InsurerInvoiceStatus.voided;

  /// Unpaid past its due date.
  bool isOverdueAt(DateTime now) => isIssued && dueAt != null && now.isAfter(dueAt!);

  /// `B01-00000001`, as a receipt prints it.
  String get displayNcf =>
      ncf.length == 11 ? '${ncf.substring(0, 3)}-${ncf.substring(3)}' : ncf;

  String get totalLabel => totalCents.formatDOP;
}

/// One invoice a run made.
@immutable
class IssuedInvoiceRef {
  const IssuedInvoiceRef({
    required this.invoiceId,
    required this.insurerId,
    required this.ncf,
    this.isTestNcf = true,
    this.totalCents = 0,
    this.lineCount = 0,
  });

  factory IssuedInvoiceRef.fromJson(Map<String, dynamic> json) => IssuedInvoiceRef(
        invoiceId: _text(json['invoiceId']),
        insurerId: _text(json['insurerId']),
        ncf: _text(json['ncf']),
        isTestNcf: json['isTestNcf'] != false,
        totalCents: _cents(json['totalCents']),
        lineCount: _cents(json['lineCount']),
      );

  final String invoiceId;
  final String insurerId;
  final String ncf;
  final bool isTestNcf;
  final int totalCents;
  final int lineCount;
}

/// What a run of `generateInsurerInvoices` did.
@immutable
class InvoiceRun {
  const InvoiceRun({
    required this.periodKey,
    this.created = const [],
    this.failed = const [],
  });

  factory InvoiceRun.fromJson(Map<String, dynamic> json) => InvoiceRun(
        periodKey: _text(json['periodKey']),
        created: [
          for (final c in json['created'] as List<dynamic>? ?? const [])
            IssuedInvoiceRef.fromJson(Map<String, dynamic>.from(c as Map)),
        ],
        failed: [
          for (final f in json['failed'] as List<dynamic>? ?? const [])
            (
              insurerId: _text((f as Map)['insurerId']),
              message: _text(f['message']),
            ),
        ],
      );

  final String periodKey;
  final List<IssuedInvoiceRef> created;

  /// Companies that could not be invoiced, and why.
  final List<({String insurerId, String message})> failed;

  int get totalCents => created.fold(0, (sum, c) => sum + c.totalCents);
}

/// The company that issues receipts, at `fiscal/issuer`.
@immutable
class FiscalIssuer {
  const FiscalIssuer({
    this.name = defaultName,
    this.rnc = '',
    this.address = defaultAddress,
    this.phone = '',
    this.email = '',
    this.paymentTermsDays = 30,
    this.updatedAt,
  });

  factory FiscalIssuer.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const FiscalIssuer();
    final name = _text(json['name']);
    final terms = json['paymentTermsDays'];
    return FiscalIssuer(
      name: name.isEmpty ? defaultName : name,
      rnc: _text(json['rnc']),
      address: json['address'] is String ? json['address'] as String : defaultAddress,
      phone: _text(json['phone']),
      email: _text(json['email']),
      paymentTermsDays: terms is int && terms >= 0 ? terms : 30,
      updatedAt: const NullableTimestampConverter().fromJson(json['updatedAt']),
    );
  }

  /// What the receipts say before the office fills anything in. Mirrors
  /// `DEFAULT_ISSUER` in `functions/src/lib/fiscal.ts`.
  static const defaultName = 'GRÚAS RD, SRL (en constitución)';
  static const defaultAddress = 'Santo Domingo, República Dominicana';

  final String name;
  final String rnc;
  final String address;
  final String phone;
  final String email;
  final int paymentTermsDays;
  final DateTime? updatedAt;

  bool get hasRnc => rnc.isNotEmpty;

  Map<String, Object?> toJson() => {
        'name': name.trim(),
        'rnc': rnc.trim(),
        'address': address.trim(),
        'phone': phone.trim(),
        'email': email.trim(),
        'paymentTermsDays': paymentTermsDays,
      };
}

/// The NCF range a kind of receipt is numbered from, at `fiscal/ncf_{prefix}`.
@immutable
class NcfSequence {
  const NcfSequence({
    required this.prefix,
    required this.nextNumber,
    required this.lastNumber,
    this.expiresOn,
    this.isTest = true,
    this.lastIssued = '',
    this.lastIssuedAt,
    this.updatedAt,
  });

  /// What the office numbers from before it has entered any range: test
  /// numbers from `B0100000001`.
  const NcfSequence.test(this.prefix)
      : nextNumber = 1,
        lastNumber = maxNumber,
        expiresOn = null,
        isTest = true,
        lastIssued = '',
        lastIssuedAt = null,
        updatedAt = null;

  /// A stored range, or the test one when there is none or it is unreadable.
  factory NcfSequence.fromJson(String prefix, Map<String, dynamic>? json) {
    final next = json?['nextNumber'];
    final last = json?['lastNumber'];
    if (json == null || next is! int || last is! int) return NcfSequence.test(prefix);
    const ts = NullableTimestampConverter();
    return NcfSequence(
      prefix: prefix,
      nextNumber: next,
      lastNumber: last,
      expiresOn: json['expiresOn'] as String?,
      isTest: json['isTest'] != false,
      lastIssued: _text(json['lastIssued']),
      lastIssuedAt: ts.fromJson(json['lastIssuedAt']),
      updatedAt: ts.fromJson(json['updatedAt']),
    );
  }

  static const maxNumber = 99999999;

  /// `B01`.
  final String prefix;
  final int nextNumber;
  final int lastNumber;

  /// `2027-12-31`.
  final String? expiresOn;
  final bool isTest;

  /// The NCF most recently issued from this range.
  final String lastIssued;
  final DateTime? lastIssuedAt;
  final DateTime? updatedAt;

  /// Receipts left, the next one included.
  int get remaining => lastNumber - nextNumber + 1 < 0 ? 0 : lastNumber - nextNumber + 1;

  Map<String, Object?> toJson() => {
        'prefix': prefix,
        'nextNumber': nextNumber,
        'lastNumber': lastNumber,
        'expiresOn': expiresOn,
        'isTest': isTest,
      };
}
