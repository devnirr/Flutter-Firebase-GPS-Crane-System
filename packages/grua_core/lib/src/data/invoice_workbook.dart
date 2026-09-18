import 'dart:typed_data';

import '../domain/enums.dart';
import '../domain/models/insurer_invoice.dart';
import '../utils/date_time_do.dart';
import 'insurer_invoicing.dart';
import 'xlsx.dart';

/// Monthly invoices as Excel workbooks: what the insurance company imports
/// into its own claims system, and what the office hands its accountant.
///
/// Amounts are written in pesos with the RD$ format, dates as real dates, and
/// the foot as formulas over the lines — so the sheet can be checked, and
/// filtered by claim, without trusting a pasted number.
abstract final class InvoiceWorkbook {
  /// `Factura_B0100000001_Seguros-Demo_2026-09.xlsx`.
  static String fileName(InsurerInvoice invoice) =>
      'Factura_${invoice.ncf}_${_slug(invoice.insurerName)}_${invoice.periodKey}.xlsx';

  /// `Facturas_2026-09-16.xlsx`.
  static String listFileName(DateTime now) =>
      'Facturas_${DoTime.dateKey(now)}.xlsx';

  static String _slug(String value) {
    const from = 'áéíóúüñÁÉÍÓÚÜÑ';
    const to = 'aeiouunAEIOUUN';
    final plain = StringBuffer();
    for (final ch in value.split('')) {
      final i = from.indexOf(ch);
      plain.write(i < 0 ? ch : to[i]);
    }
    final slug = plain
        .toString()
        .replaceAll(RegExp('[^A-Za-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (slug.isEmpty) return 'aseguradora';
    return slug.length > 40 ? slug.substring(0, 40) : slug;
  }

  static DateTime? _local(DateTime? instant) =>
      instant == null ? null : DoTime.toLocal(instant);

  static DateTime _localDay(String isoDay) {
    final p = isoDay.split('-').map(int.parse).toList();
    return DateTime.utc(p[0], p[1], p[2]);
  }

  static String periodTitle(InsurerInvoice i) =>
      InvoicePeriod.isKey(i.periodKey) ? InvoicePeriod.parse(i.periodKey).title : i.periodKey;

  static String statusLabel(InsurerInvoice i, DateTime now) =>
      i.isOverdueAt(now) ? 'Vencida' : i.status.label;

  // Columns of the lines table.
  static const _lineHeaders = [
    '#',
    'Fecha y hora',
    'Código',
    'Siniestro',
    'Póliza',
    'Asegurado',
    'Placa',
    'Vehículo',
    'Origen',
    'Destino',
    'Distancia (km)',
    'Zona',
    'Clase',
    'Tarifa',
    'Concepto',
    'Precio de la zona',
    'Km adicionales',
    'Cargo por km adicional',
    'Monto',
  ];
  static const _lineWidths = [
    5.0, 16.0, 17.0, 18.0, 16.0, 24.0, 11.0, 18.0, 32.0, 32.0, //
    12.0, 12.0, 17.0, 10.0, 22.0, 15.0, 12.0, 15.0, 15.0,
  ];
  static const int _amountCol = 18;

  /// One invoice: the invoice itself, a summary by zone, and the zone prices
  /// it was billed on.
  static Uint8List invoice(InsurerInvoice i, {DateTime? now}) {
    final at = (now ?? DateTime.now()).toUtc();
    final book = XlsxWorkbook(title: 'Factura ${i.ncf} ${i.insurerName}');
    _invoiceSheet(book.sheet('Factura'), i, at);
    _summarySheet(book.sheet('Resumen por zona'), i);
    _tariffSheet(book.sheet('Tarifa por zonas'), i);
    return book.encode(now: at);
  }

  static void _invoiceSheet(XlsxSheet sheet, InsurerInvoice i, DateTime now) {
    for (final (c, w) in _lineWidths.indexed) {
      sheet.columnWidths[c] = w;
    }
    sheet
      ..landscape = true
      ..add([XlsxCell('Factura de crédito fiscal — NCF ${i.ncf}', style: XlsxStyle.title)]);
    if (i.isTestNcf) {
      sheet.add(const [
        XlsxCell(
          'COMPROBANTE DE PRUEBA — SIN VALOR FISCAL (is_test_ncf = sí)',
          style: XlsxStyle.warning,
        ),
      ]);
    }
    if (i.isVoided) {
      sheet.add([
        XlsxCell(
          'FACTURA ANULADA${i.voidReason.isEmpty ? '' : ': ${i.voidReason}'}',
          style: XlsxStyle.warning,
        ),
      ]);
    }
    if (i.isPaid) {
      sheet.add([
        XlsxCell(
          [
            'PAGADA',
            if (i.paidAt != null) InvoiceDocument.day(i.paidAt),
            if (i.paymentReference.isNotEmpty) 'Ref. ${i.paymentReference}',
          ].join(' · '),
          style: XlsxStyle.bold,
        ),
      ]);
    }
    sheet.blank();

    void info(String label, Object? value, {XlsxStyle style = XlsxStyle.normal}) =>
        sheet.add([XlsxCell.bold(label), null, XlsxCell(value ?? '—', style: style)]);

    info('Emisor', i.issuer.name);
    info('RNC del emisor', i.issuer.rncLabel);
    if (i.issuer.address.isNotEmpty) info('Dirección', i.issuer.address);
    info('Cliente', i.insurerName);
    info('RNC del cliente', formatRnc(i.insurerRnc));
    info('NCF', i.ncf);
    info('Tipo de comprobante', 'Crédito fiscal (${i.ncfType.wire})');
    info('NCF de prueba', i.isTestNcf ? 'Sí' : 'No');
    if (i.isTestNcf || i.ncfExpiresOn == null || !Ncf.isIsoDay(i.ncfExpiresOn!)) {
      info('Válido hasta', i.isTestNcf ? 'N/A (prueba)' : '—');
    } else {
      info('Válido hasta', _localDay(i.ncfExpiresOn!), style: XlsxStyle.date);
    }
    info('Período', periodTitle(i));
    info('Fecha de emisión', _local(i.issuedAt ?? i.createdAt), style: XlsxStyle.date);
    info('Fecha de vencimiento', _local(i.dueAt), style: XlsxStyle.date);
    info(
      'Condiciones',
      i.paymentTermsDays == 0 ? 'Contado' : '${i.paymentTermsDays} días',
    );
    info('Estado', statusLabel(i, now));
    sheet.blank();

    final headerRow = sheet.addValues(_lineHeaders, style: XlsxStyle.header);
    sheet.frozenRows = headerRow;
    final firstLine = sheet.nextRow;

    for (final (n, line) in i.lines.indexed) {
      final tow = !line.isCancellation;
      sheet.add([
        XlsxCell(n + 1, style: XlsxStyle.integer),
        XlsxCell.date(_local(line.finishedAt), withTime: true),
        XlsxCell(line.serviceCode),
        XlsxCell(line.claimNumber),
        XlsxCell(line.policyNumber),
        XlsxCell(line.insuredName),
        XlsxCell(line.plate),
        XlsxCell(line.vehicle),
        XlsxCell(line.pickupAddress),
        XlsxCell(line.dropoffAddress),
        if (tow && line.distanceKm > 0)
          XlsxCell(line.distanceKm, style: XlsxStyle.decimal)
        else
          null,
        if (tow) XlsxCell(line.zoneLabel) else null,
        if (tow) XlsxCell(line.vehicleClass) else null,
        if (tow) XlsxCell(line.tariffLabel) else null,
        XlsxCell(line.isCancellation ? 'Cargo por cancelación' : 'Servicio de grúa'),
        if (tow && line.baseCents > 0) XlsxCell.money(line.baseCents) else null,
        if (tow && line.extraKm > 0)
          XlsxCell(line.extraKm, style: XlsxStyle.decimal)
        else
          null,
        if (tow && line.extraCents > 0) XlsxCell.money(line.extraCents) else null,
        XlsxCell.money(line.amountCents),
      ]);
    }
    final lastLine = sheet.nextRow - 1;
    if (i.lines.isNotEmpty) {
      sheet.autoFilter = '${XlsxWorkbook.ref(0, headerRow)}:'
          '${XlsxWorkbook.ref(_amountCol, lastLine)}';
    }
    sheet.blank();

    final amount = XlsxWorkbook.column(_amountCol);
    const label = _amountCol - 1;
    List<XlsxCell?> foot(String text, XlsxCell value) =>
        [for (var c = 0; c < label; c++) null, XlsxCell.bold(text), value];

    final subtotalRow = sheet.add(
      foot(
        'Subtotal',
        XlsxCell.money(
          i.subtotalCents,
          formula: i.lines.isEmpty ? null : 'SUM($amount$firstLine:$amount$lastLine)',
        ),
      ),
    );
    final itbisRow = sheet.add(
      foot(
        'ITBIS 18%',
        XlsxCell.money(i.itbisCents, formula: 'ROUND($amount$subtotalRow*18%,2)'),
      ),
    );
    sheet
      ..add(
        foot(
          'Total',
          XlsxCell.money(
            i.totalCents,
            bold: true,
            formula: '$amount$subtotalRow+$amount$itbisRow',
          ),
        ),
      )
      ..blank()
      ..add([
        XlsxCell(
          '${i.towCount} servicio(s) de grúa · ${i.cancellationCount} cargo(s) por '
          'cancelación. Montos en pesos dominicanos (DOP), sin ITBIS por línea; '
          'el ITBIS se calcula una vez sobre el subtotal.',
          style: XlsxStyle.muted,
        ),
      ]);
  }

  static int _zoneStart(String label) =>
      int.tryParse(RegExp(r'\d+').firstMatch(label)?.group(0) ?? '') ?? 1 << 30;

  static int _classOrder(String label) {
    for (final (n, c) in VehicleClass.priced.indexed) {
      if (c.label == label) return n;
    }
    return VehicleClass.priced.length;
  }

  static void _summarySheet(XlsxSheet sheet, InsurerInvoice i) {
    sheet
      ..columnWidths.addAll({0: 20, 1: 14, 2: 12, 3: 12, 4: 16})
      ..add([XlsxCell('Resumen por zona — ${i.ncf}', style: XlsxStyle.title)])
      ..add([XlsxCell('${i.insurerName} · ${periodTitle(i)}', style: XlsxStyle.muted)])
      ..blank();

    final headerRow = sheet.addValues(
      const ['Clase', 'Zona', 'Tarifa', 'Servicios', 'Monto'],
      style: XlsxStyle.header,
    );
    sheet.frozenRows = headerRow;

    final groups = <(String, String, String), (int, int)>{};
    var cancellations = 0;
    var cancellationCents = 0;
    for (final line in i.lines) {
      if (line.isCancellation) {
        cancellations++;
        cancellationCents += line.amountCents;
        continue;
      }
      final key = (line.vehicleClass, line.zoneLabel, line.tariffLabel);
      final (count, cents) = groups[key] ?? (0, 0);
      groups[key] = (count + 1, cents + line.amountCents);
    }
    final keys = groups.keys.toList()
      ..sort((a, b) {
        final byClass = _classOrder(a.$1).compareTo(_classOrder(b.$1));
        if (byClass != 0) return byClass;
        final byZone = _zoneStart(a.$2).compareTo(_zoneStart(b.$2));
        return byZone != 0 ? byZone : a.$3.compareTo(b.$3);
      });

    final first = sheet.nextRow;
    for (final key in keys) {
      final (count, cents) = groups[key]!;
      sheet.add([
        XlsxCell(key.$1.isEmpty ? '—' : key.$1),
        XlsxCell(key.$2.isEmpty ? '—' : key.$2),
        XlsxCell(key.$3),
        XlsxCell(count, style: XlsxStyle.integer),
        XlsxCell.money(cents),
      ]);
    }
    if (cancellations > 0) {
      sheet.add([
        const XlsxCell('Cargos por cancelación'),
        null,
        null,
        XlsxCell(cancellations, style: XlsxStyle.integer),
        XlsxCell.money(cancellationCents),
      ]);
    }
    final last = sheet.nextRow - 1;
    final hasRows = last >= first;
    sheet.add([
      const XlsxCell.bold('Subtotal'),
      null,
      null,
      XlsxCell(
        i.lines.length,
        style: XlsxStyle.integerBold,
        formula: hasRows ? 'SUM(D$first:D$last)' : null,
      ),
      XlsxCell.money(
        i.subtotalCents,
        bold: true,
        formula: hasRows ? 'SUM(E$first:E$last)' : null,
      ),
    ]);
  }

  static void _tariffSheet(XlsxSheet sheet, InsurerInvoice i) {
    sheet
      ..columnWidths.addAll({0: 20, 1: 12, 2: 11, 3: 11, 4: 18, 5: 22, 6: 12})
      ..add([const XlsxCell('Tarifa por zonas (sin ITBIS)', style: XlsxStyle.title)])
      ..add([
        XlsxCell(
          'Precios fijos por kilómetro de recorrido, vigentes al emitir la factura '
          '${i.ncf} a ${i.insurerName}.',
          style: XlsxStyle.muted,
        ),
      ])
      ..blank();

    if (i.tariffTable.isEmpty) {
      sheet.add(const [
        XlsxCell(
          'Esta factura se emitió antes de que se guardara la tarifa con ella.',
          style: XlsxStyle.warning,
        ),
      ]);
      return;
    }

    final headerRow = sheet.addValues(
      const [
        'Clase',
        'Zona',
        'Desde (km)',
        'Hasta (km)',
        'Precio de la zona',
        'Por km adicional',
        'Tarifa',
      ],
      style: XlsxStyle.header,
    );
    sheet.frozenRows = headerRow;
    for (final row in i.tariffTable) {
      sheet.add([
        XlsxCell(row.vehicleClass.label),
        XlsxCell(row.zoneLabel),
        XlsxCell(row.zoneMinKm, style: XlsxStyle.integer),
        if (row.zoneMaxKm == null)
          const XlsxCell('En adelante')
        else
          XlsxCell(row.zoneMaxKm, style: XlsxStyle.integer),
        XlsxCell.money(row.baseCents),
        if (row.extraKmCents > 0) XlsxCell.money(row.extraKmCents) else const XlsxCell('—'),
        XlsxCell(row.isNegotiated ? 'Acordada' : 'Base'),
      ]);
    }
    sheet
      ..blank()
      ..add(const [
        XlsxCell(
          'Cada servicio se cobra al precio de su zona según la distancia recorrida. '
          'En la zona abierta se suma cada kilómetro pasado su inicio por el precio '
          'por km adicional.',
          style: XlsxStyle.muted,
        ),
      ]);
  }

  /// Many invoices, one row each: the office's register of what it billed.
  static Uint8List list(
    List<InsurerInvoice> invoices, {
    String subtitle = '',
    DateTime? now,
  }) {
    final at = (now ?? DateTime.now()).toUtc();
    final book = XlsxWorkbook(title: 'Facturas a aseguradoras');
    final sheet = book.sheet('Facturas')
      ..landscape = true
      ..columnWidths.addAll({
        0: 15, 1: 8, 2: 30, 3: 14, 4: 16, 5: 12, 6: 12, 7: 12, //
        8: 10, 9: 15, 10: 15, 11: 15, 12: 12, 13: 18,
      })
      ..add([const XlsxCell('Facturas a aseguradoras', style: XlsxStyle.title)])
      ..add([
        XlsxCell(
          [
            'Generado el ${InvoiceDocument.day(at)}',
            if (subtitle.isNotEmpty) subtitle,
            'Las anuladas no suman en los totales.',
          ].join(' · '),
          style: XlsxStyle.muted,
        ),
      ])
      ..blank();

    final headerRow = sheet.addValues(
      const [
        'NCF',
        'Prueba',
        'Aseguradora',
        'RNC',
        'Período',
        'Emitida',
        'Vence',
        'Estado',
        'Servicios',
        'Subtotal',
        'ITBIS',
        'Total',
        'Cobrada el',
        'Referencia',
      ],
      style: XlsxStyle.header,
    );
    sheet.frozenRows = headerRow;
    final first = sheet.nextRow;
    for (final i in invoices) {
      sheet.add([
        XlsxCell(i.ncf),
        XlsxCell(i.isTestNcf ? 'Sí' : 'No'),
        XlsxCell(i.insurerName),
        XlsxCell(formatRnc(i.insurerRnc)),
        XlsxCell(periodTitle(i)),
        XlsxCell.date(_local(i.issuedAt ?? i.createdAt)),
        XlsxCell.date(_local(i.dueAt)),
        XlsxCell(statusLabel(i, at)),
        XlsxCell(i.lines.length, style: XlsxStyle.integer),
        XlsxCell.money(i.subtotalCents),
        XlsxCell.money(i.itbisCents),
        XlsxCell.money(i.totalCents),
        if (i.paidAt != null) XlsxCell.date(_local(i.paidAt)) else null,
        XlsxCell(i.paymentReference),
      ]);
    }
    final last = sheet.nextRow - 1;
    if (invoices.isNotEmpty) {
      sheet.autoFilter = '${XlsxWorkbook.ref(0, headerRow)}:${XlsxWorkbook.ref(13, last)}';
    }
    final live = invoices.where((i) => !i.isVoided);
    int sum(int Function(InsurerInvoice) of) => live.fold(0, (s, i) => s + of(i));
    String? sumIf(String col) => invoices.isEmpty
        ? null
        : 'SUMIF(H$first:H$last,"<>${InsurerInvoiceStatus.voided.label}",$col$first:$col$last)';
    sheet
      ..blank()
      ..add([
        for (var c = 0; c < 8; c++) null,
        const XlsxCell.bold('Totales'),
        XlsxCell.money(sum((i) => i.subtotalCents), bold: true, formula: sumIf('J')),
        XlsxCell.money(sum((i) => i.itbisCents), bold: true, formula: sumIf('K')),
        XlsxCell.money(sum((i) => i.totalCents), bold: true, formula: sumIf('L')),
      ]);
    return book.encode(now: at);
  }
}
