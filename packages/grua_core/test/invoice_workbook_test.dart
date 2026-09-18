import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:intl/date_symbol_data_local.dart';

/// The Excel export: the file format itself, and what an invoice's workbook
/// says.
void main() {
  setUpAll(() => initializeDateFormatting('es_DO'));

  Map<String, String> unzip(Uint8List bytes) => {
        for (final e in StoredZip.decode(bytes).entries) e.key: utf8.decode(e.value),
      };

  group('StoredZip', () {
    test('computes the standard CRC-32', () {
      expect(StoredZip.crc32(ascii.encode('123456789')), 0xCBF43926);
      expect(StoredZip.crc32(const []), 0);
    });

    test('reads back what it wrote, names and bytes', () {
      final files = {
        'a.txt': utf8.encode('hola'),
        'carpeta/ñandú.xml': utf8.encode('<x>€</x>'),
        'vacío': <int>[],
      };
      final zip = StoredZip.encode(files, modified: DateTime.utc(2026, 9, 16, 10, 30, 12));
      // Local header signature, and the end record at the tail.
      expect(zip.sublist(0, 4), [0x50, 0x4b, 0x03, 0x04]);
      expect(zip.sublist(zip.length - 22, zip.length - 18), [0x50, 0x4b, 0x05, 0x06]);
      final back = StoredZip.decode(zip);
      expect(back.keys, files.keys);
      for (final key in files.keys) {
        expect(back[key], files[key]);
      }
    });

    test('refuses a corrupted entry', () {
      final zip = StoredZip.encode({'a.txt': utf8.encode('hola')}, modified: DateTime.utc(2026));
      zip[30 + 5] ^= 0xFF; // a byte of the content
      expect(() => StoredZip.decode(zip), throwsFormatException);
    });
  });

  group('XlsxWorkbook', () {
    test('names columns the way Excel does', () {
      expect(
        [0, 1, 25, 26, 27, 51, 52, 701, 702].map(XlsxWorkbook.column),
        ['A', 'B', 'Z', 'AA', 'AB', 'AZ', 'BA', 'ZZ', 'AAA'],
      );
      expect(XlsxWorkbook.ref(18, 12), 'S12');
    });

    test('numbers days the way Excel does', () {
      expect(XlsxWorkbook.serial(DateTime.utc(1900, 3)), 61);
      expect(XlsxWorkbook.serial(DateTime.utc(2024)), 45292);
      expect(XlsxWorkbook.serial(DateTime.utc(2024, 1, 1, 18)), 45292.75);
    });

    test('keeps sheet names inside what Excel accepts', () {
      expect(XlsxWorkbook.sheetName('Factura: 2026/09 [prueba]?'), 'Factura  2026 09  prueba');
      expect(XlsxWorkbook.sheetName('x' * 40), 'x' * 31);
      expect(XlsxWorkbook.sheetName(' '), 'Hoja');
      final book = XlsxWorkbook(title: 't')..sheet('Datos');
      expect(book.sheet('datos').name, 'datos (2)');
    });

    test('writes a package Excel can open: parts, types, relations, styles', () {
      final book = XlsxWorkbook(title: 'Prueba & <co>');
      book.sheet('Hoja 1')
        ..columnWidths[0] = 20
        ..frozenRows = 1
        ..addValues(['Texto', 'Número'], style: XlsxStyle.header)
        ..add([
          const XlsxCell('a < b & "c"\u0001'),
          XlsxCell.money(123456),
          const XlsxCell(true),
          XlsxCell.date(DateTime.utc(2024)),
          const XlsxCell(3.5, style: XlsxStyle.decimal),
          const XlsxCell(7, formula: 'SUM(A1:A2)'),
        ])
        ..autoFilter = 'A1:F2';
      book.sheet('Otra');

      final files = unzip(book.encode(now: DateTime.utc(2026, 9, 16, 12)));
      expect(files.keys, containsAll([
        '[Content_Types].xml',
        '_rels/.rels',
        'docProps/core.xml',
        'xl/workbook.xml',
        'xl/_rels/workbook.xml.rels',
        'xl/styles.xml',
        'xl/worksheets/sheet1.xml',
        'xl/worksheets/sheet2.xml',
      ]));
      expect(files['[Content_Types].xml'], contains('/xl/worksheets/sheet2.xml'));
      expect(files['xl/_rels/workbook.xml.rels'], contains('Id="rId3"'));
      expect(files['xl/_rels/workbook.xml.rels'], contains('Target="styles.xml"'));
      expect(files['docProps/core.xml'], contains('Prueba &amp; &lt;co&gt;'));
      expect(files['docProps/core.xml'], contains('2026-09-16T12:00:00Z'));

      final workbook = files['xl/workbook.xml']!;
      expect(workbook, contains('<sheet name="Hoja 1" sheetId="1" r:id="rId1"/>'));
      expect(workbook, contains('<sheet name="Otra" sheetId="2" r:id="rId2"/>'));
      expect(workbook, contains(r"'Hoja 1'!$A$1:$F$2"));
      expect(workbook, contains('fullCalcOnLoad="1"'));

      final xml = files['xl/worksheets/sheet1.xml']!;
      expect(xml, contains('<pane ySplit="1" topLeftCell="A2"'));
      expect(xml, contains('<col min="1" max="1" width="20.0" customWidth="1"/>'));
      expect(xml, contains('<dimension ref="A1:F2"/>'));
      expect(
        xml,
        contains(
          '<c r="A2" t="inlineStr"><is><t xml:space="preserve">a &lt; b &amp; &quot;c&quot;</t></is></c>',
        ),
      );
      expect(xml, contains('<c r="B2" s="${XlsxStyle.money.index}"><v>1234.56</v></c>'));
      expect(xml, contains('<c r="C2" t="b"><v>1</v></c>'));
      expect(xml, contains('<c r="D2" s="${XlsxStyle.date.index}"><v>45292</v></c>'));
      expect(xml, contains('<c r="E2" s="${XlsxStyle.decimal.index}"><v>3.5</v></c>'));
      expect(xml, contains('<c r="F2"><f>SUM(A1:A2)</f><v>7</v></c>'));
      expect(xml, contains('<autoFilter ref="A1:F2"/>'));
      expect(xml, isNot(contains('\u0001')));

      // One cellXf per style, in the enum's order.
      final styles = files['xl/styles.xml']!;
      expect(styles, contains('<cellXfs count="${XlsxStyle.values.length}">'));
      expect(RegExp('<xf numFmtId').allMatches(styles).length, XlsxStyle.values.length + 1);
      expect(styles, contains(r'formatCode="&quot;RD$&quot;#,##0.00"'));
    });
  });

  group('InvoiceWorkbook', () {
    InsurerInvoice sample({
      bool test = true,
      InsurerInvoiceStatus status = InsurerInvoiceStatus.issued,
      List<InvoiceTariffRow>? tariff,
    }) =>
        InsurerInvoice(
          id: 'fac-1',
          insurerId: 'ins-a',
          ncf: 'B0100000007',
          insurerName: 'Seguros Núñez & Asociados',
          insurerRnc: '101001577',
          billingEmail: 'facturas@nunez.do',
          periodKey: '2026-09',
          periodLabel: 'septiembre 2026',
          isTestNcf: test,
          ncfExpiresOn: test ? null : '2027-12-31',
          issuer: const InvoiceIssuer(name: 'Titan Grúas, SRL', rnc: '130000001'),
          lines: [
            InsurerInvoiceLine(
              serviceId: 'a1',
              kind: InsurerInvoiceLineKind.tow,
              amountCents: 250000,
              serviceCode: 'GR-260902-AB12',
              finishedAt: DateTime.utc(2026, 9, 2, 15),
              claimNumber: 'SIN-2024-001489',
              policyNumber: 'POL-1',
              insuredName: 'Juan Pérez',
              plate: 'G123456',
              vehicle: 'Toyota Corolla',
              pickupAddress: 'Av. 27 de Febrero',
              dropoffAddress: 'Taller Autocentro',
              distanceKm: 6.4,
              zoneLabel: '0–10 km',
              vehicleClass: 'Vehículo ligero',
              tariff: 'default',
              baseCents: 250000,
            ),
            InsurerInvoiceLine(
              serviceId: 'a2',
              kind: InsurerInvoiceLineKind.tow,
              amountCents: 698000,
              serviceCode: 'GR-260910-CD34',
              finishedAt: DateTime.utc(2026, 9, 10, 20),
              claimNumber: 'SIN-2024-001500',
              distanceKm: 62.3,
              zoneLabel: '+50 km',
              vehicleClass: 'Vehículo ligero',
              tariff: 'default',
              baseCents: 550000,
              extraKm: 12.3,
              extraCents: 148000,
            ),
            InsurerInvoiceLine(
              serviceId: 'a3',
              kind: InsurerInvoiceLineKind.tow,
              amountCents: 350000,
              serviceCode: 'GR-260911-EF56',
              finishedAt: DateTime.utc(2026, 9, 11, 20),
              claimNumber: 'SIN-2024-001511',
              distanceKm: 8,
              zoneLabel: '0–10 km',
              vehicleClass: 'Vehículo ligero',
              tariff: 'default',
              baseCents: 350000,
            ),
            InsurerInvoiceLine(
              serviceId: 'a4',
              kind: InsurerInvoiceLineKind.cancellation,
              amountCents: 50000,
              serviceCode: 'GR-260912-GH78',
              finishedAt: DateTime.utc(2026, 9, 12, 15),
              claimNumber: 'SIN-2024-001520',
            ),
          ],
          tariffTable: tariff ??
              [
                for (final rule in ZonePricing.defaultRules)
                  InvoiceTariffRow(
                    vehicleClass: rule.vehicleClass,
                    zoneMinKm: rule.zoneMinKm,
                    zoneMaxKm: rule.zoneMaxKm,
                    baseCents: rule.baseCents,
                    extraKmCents: rule.extraKmCents,
                    source: 'default',
                  ),
              ],
          towCount: 3,
          cancellationCount: 1,
          subtotalCents: 1348000,
          itbisCents: 242640,
          totalCents: 1590640,
          status: status,
          paymentTermsDays: 30,
          dueAt: DateTime.utc(2026, 11, 1, 3, 59, 59),
          issuedAt: DateTime.utc(2026, 10, 1, 10),
          paidAt: status == InsurerInvoiceStatus.paid ? DateTime.utc(2026, 10, 20, 15) : null,
          paymentReference: status == InsurerInvoiceStatus.paid ? 'TRF-889231' : '',
          voidReason: status == InsurerInvoiceStatus.voided ? 'Precio equivocado' : '',
        );

    /// The inline strings and values of one sheet, row by row.
    Map<String, String> cells(String xml) {
      final out = <String, String>{};
      final cell = RegExp(r'<c r="([A-Z]+\d+)"[^>]*?(?:/>|>(.*?)</c>)');
      for (final m in cell.allMatches(xml)) {
        final body = m.group(2) ?? '';
        if (m.group(2) == null) continue;
        final text = RegExp('<t[^>]*>(.*?)</t>').firstMatch(body)?.group(1);
        final value = RegExp('<v>(.*?)</v>').firstMatch(body)?.group(1);
        final formula = RegExp('<f>(.*?)</f>').firstMatch(body)?.group(1);
        out[m.group(1)!] = [
          if (formula != null) '=$formula',
          text ?? value ?? '',
        ].join(' ');
      }
      return out;
    }

    String? rowOf(Map<String, String> sheet, String text) {
      for (final e in sheet.entries) {
        if (e.value == text) return RegExp(r'\d+').firstMatch(e.key)!.group(0);
      }
      return null;
    }

    test('names the file after the NCF, the company and the month', () {
      expect(
        InvoiceWorkbook.fileName(sample()),
        'Factura_B0100000007_Seguros-Nunez-Asociados_2026-09.xlsx',
      );
      expect(InvoiceWorkbook.listFileName(DateTime.utc(2026, 9, 16, 3)), 'Facturas_2026-09-15.xlsx');
    });

    test('lays out the invoice: parties, lines, and the foot as formulas', () {
      final files = unzip(InvoiceWorkbook.invoice(sample(), now: DateTime.utc(2026, 10, 2)));
      final workbook = files['xl/workbook.xml']!;
      expect(workbook, contains('name="Factura"'));
      expect(workbook, contains('name="Resumen por zona"'));
      expect(workbook, contains('name="Tarifa por zonas"'));

      final s = cells(files['xl/worksheets/sheet1.xml']!);
      expect(s['A1'], 'Factura de crédito fiscal — NCF B0100000007');
      expect(s['A2'], contains('COMPROBANTE DE PRUEBA — SIN VALOR FISCAL (is_test_ncf = sí)'));
      expect(s.values, contains('Titan Grúas, SRL'));
      expect(s.values, contains('1-30-00000-1'));
      expect(s.values, contains('Seguros Núñez &amp; Asociados'));
      expect(s.values, contains('1-01-00157-7'));
      expect(s.values, contains('N/A (prueba)'));
      expect(s.values, contains('Septiembre 2026'));
      expect(s.values, contains('Por cobrar'));

      final header = rowOf(s, 'Siniestro')!;
      final h = int.parse(header);
      expect(s['A$header'], '#');
      expect(s['S$header'], 'Monto');
      // The lines, in pesos, with dates as dates.
      expect(s['D${h + 1}'], 'SIN-2024-001489');
      expect(s['B${h + 1}'], XlsxWorkbook.serial(DateTime.utc(2026, 9, 2, 11)).toString());
      expect(s['K${h + 1}'], '6.4');
      expect(s['L${h + 1}'], '0–10 km');
      expect(s['N${h + 1}'], 'Base');
      expect(s['P${h + 1}'], '2500');
      expect(s['S${h + 1}'], '2500');
      expect(s['Q${h + 2}'], '12.3');
      expect(s['R${h + 2}'], '1480');
      expect(s['S${h + 2}'], '6980');
      // A cancellation has no zone and no price breakdown.
      expect(s['O${h + 4}'], 'Cargo por cancelación');
      expect(s['L${h + 4}'], isNull);
      expect(s['P${h + 4}'], isNull);
      expect(s['S${h + 4}'], '500');

      final subtotal = rowOf(s, 'Subtotal')!;
      final itbis = rowOf(s, 'ITBIS 18%')!;
      final total = rowOf(s, 'Total')!;
      expect(s['S$subtotal'], '=SUM(S${h + 1}:S${h + 4}) 13480');
      expect(s['S$itbis'], '=ROUND(S$subtotal*18%,2) 2426.4');
      expect(s['S$total'], '=S$subtotal+S$itbis 15906.4');
      expect(files['xl/worksheets/sheet1.xml'], contains('<autoFilter ref="A$header:S${h + 4}"/>'));
    });

    test('adds up the zones, and keeps the price list it was billed on', () {
      final files = unzip(InvoiceWorkbook.invoice(sample()));
      final summary = cells(files['xl/worksheets/sheet2.xml']!);
      final header = int.parse(rowOf(summary, 'Clase')!);
      // 0–10 km before +50 km; the cancellation last.
      expect(summary['B${header + 1}'], '0–10 km');
      expect(summary['D${header + 1}'], '2');
      expect(summary['E${header + 1}'], '6000');
      expect(summary['B${header + 2}'], '+50 km');
      expect(summary['E${header + 2}'], '6980');
      expect(summary['A${header + 3}'], 'Cargos por cancelación');
      expect(summary['D${header + 4}'], '=SUM(D${header + 1}:D${header + 3}) 4');
      expect(summary['E${header + 4}'], '=SUM(E${header + 1}:E${header + 3}) 13480');

      final tariff = cells(files['xl/worksheets/sheet3.xml']!);
      final top = int.parse(rowOf(tariff, 'Clase')!);
      expect(tariff['A${top + 1}'], 'Vehículo ligero');
      expect(tariff['B${top + 1}'], '0–10 km');
      expect(tariff['E${top + 1}'], '2500');
      expect(tariff['F${top + 1}'], '—');
      expect(tariff['D${top + 4}'], 'En adelante');
      expect(tariff['F${top + 4}'], '120');
      expect(tariff['A${top + 12}'], 'Vehículo pesado');
      expect(tariff['F${top + 12}'], '250');
      expect(tariff['G${top + 12}'], 'Base');
      expect(tariff.values.where((v) => v == 'Acordada'), isEmpty);
    });

    test('says so when the price list was not kept, and marks negotiated prices', () {
      final none = cells(
        unzip(InvoiceWorkbook.invoice(sample(tariff: const [])))['xl/worksheets/sheet3.xml']!,
      );
      expect(none.values, contains('Esta factura se emitió antes de que se guardara la tarifa con ella.'));

      final own = cells(
        unzip(
          InvoiceWorkbook.invoice(
            sample(
              tariff: const [
                InvoiceTariffRow(
                  vehicleClass: VehicleClass.suv,
                  zoneMinKm: 0,
                  zoneMaxKm: 30,
                  baseCents: 300000,
                  source: 'insurer',
                ),
              ],
            ),
          ),
        )['xl/worksheets/sheet3.xml']!,
      );
      expect(own.values, containsAll(['SUV / Jeepeta', '0–30 km', '3000', 'Acordada']));
    });

    test('marks a real, a paid and a voided invoice', () {
      final real = cells(
        unzip(InvoiceWorkbook.invoice(sample(test: false)))['xl/worksheets/sheet1.xml']!,
      );
      expect(real.values.where((v) => v.contains('PRUEBA')), isEmpty);
      expect(real.values, contains('No'));
      expect(real.values, contains(XlsxWorkbook.serial(DateTime.utc(2027, 12, 31)).toInt().toString()));

      final paid = cells(
        unzip(
          InvoiceWorkbook.invoice(sample(status: InsurerInvoiceStatus.paid)),
        )['xl/worksheets/sheet1.xml']!,
      );
      expect(paid.values, contains('PAGADA · 20/10/2026 · Ref. TRF-889231'));
      expect(paid.values, contains('Cobrada'));

      final voided = cells(
        unzip(
          InvoiceWorkbook.invoice(sample(status: InsurerInvoiceStatus.voided)),
        )['xl/worksheets/sheet1.xml']!,
      );
      expect(voided.values, contains('FACTURA ANULADA: Precio equivocado'));

      final overdue = cells(
        unzip(
          InvoiceWorkbook.invoice(sample(), now: DateTime.utc(2026, 12)),
        )['xl/worksheets/sheet1.xml']!,
      );
      expect(overdue.values, contains('Vencida'));
    });

    test('lists many invoices, leaving the voided ones out of the totals', () {
      final list = [
        sample(),
        sample(status: InsurerInvoiceStatus.paid, test: false),
        sample(status: InsurerInvoiceStatus.voided),
      ];
      final files = unzip(
        InvoiceWorkbook.list(list, subtitle: 'Septiembre 2026', now: DateTime.utc(2026, 10, 5)),
      );
      final s = cells(files['xl/worksheets/sheet1.xml']!);
      final header = int.parse(rowOf(s, 'NCF')!);
      expect(s['B${header + 1}'], 'Sí');
      expect(s['B${header + 2}'], 'No');
      expect(s['H${header + 1}'], 'Por cobrar');
      expect(s['H${header + 2}'], 'Cobrada');
      expect(s['H${header + 3}'], 'Anulada');
      expect(s['N${header + 2}'], 'TRF-889231');
      expect(s['A2'], contains('Septiembre 2026'));

      final totals = rowOf(s, 'Totales')!;
      final range = '${header + 1}:';
      expect(s['L$totals'], startsWith('=SUMIF(H$range'));
      expect(s['L$totals'], contains('&quot;&lt;&gt;Anulada&quot;'));
      expect(s['L$totals'], endsWith(' 31812.8'));
      expect(s['J$totals'], endsWith(' 26960'));

      final empty = unzip(InvoiceWorkbook.list(const []));
      expect(cells(empty['xl/worksheets/sheet1.xml']!).values, contains('Totales'));
    });

    test('writes a file a spreadsheet program can open', () {
      // Left in the build folder for a look with a real spreadsheet program.
      final dir = Directory('build/xlsx_samples')..createSync(recursive: true);
      File('${dir.path}/factura.xlsx').writeAsBytesSync(InvoiceWorkbook.invoice(sample()));
      File('${dir.path}/facturas.xlsx').writeAsBytesSync(
        InvoiceWorkbook.list([sample(), sample(status: InsurerInvoiceStatus.voided)]),
      );
      expect(File('${dir.path}/factura.xlsx').lengthSync(), greaterThan(1000));
    });
  });
}
