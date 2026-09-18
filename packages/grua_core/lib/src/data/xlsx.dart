// The XML below is written as adjacent literals on purpose: whitespace between
// them would change the documents.
// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'dart:convert';
import 'dart:typed_data';

/// A small Office Open XML (.xlsx) writer: enough for invoices and lists that
/// open cleanly in Excel, LibreOffice and Google Sheets.
///
/// Written here rather than pulled in as a package so it runs the same in the
/// browser, in tests and on a phone, with nothing to keep in step. Strings are
/// written inline, the zip is stored uncompressed, and formulas carry their
/// computed value so a viewer that does not calculate still shows numbers.

/// The looks a cell can have. The order is the order of `cellXfs` in
/// [XlsxWorkbook._styles]; do not reorder.
enum XlsxStyle {
  normal,
  bold,
  money,
  date,
  moneyBold,
  header,
  title,
  decimal,
  warning,
  integer,
  muted,
  dateTime,
  integerBold,
}

/// One cell: text, a number, a date, a yes/no, or a formula with its value.
///
/// Immutable. Nothing but `dart:` libraries is imported here, so this file
/// also compiles on its own to JavaScript for checking the bytes it writes.
class XlsxCell {
  const XlsxCell(this.value, {this.style = XlsxStyle.normal, this.formula});

  const XlsxCell.bold(this.value)
      : style = XlsxStyle.bold,
        formula = null;

  /// An amount in cents, written in pesos with the RD$ format.
  factory XlsxCell.money(int cents, {bool bold = false, String? formula}) => XlsxCell(
        cents / 100,
        style: bold ? XlsxStyle.moneyBold : XlsxStyle.money,
        formula: formula,
      );

  /// A day in Santo Domingo; [localWallClock] carries the local fields.
  const XlsxCell.date(DateTime? localWallClock, {bool withTime = false})
      : value = localWallClock,
        style = withTime ? XlsxStyle.dateTime : XlsxStyle.date,
        formula = null;

  /// `String`, `num`, `bool`, `DateTime` (local wall clock) or null.
  final Object? value;
  final XlsxStyle style;

  /// Without the leading `=`.
  final String? formula;
}

/// One worksheet, filled a row at a time.
class XlsxSheet {
  XlsxSheet(String name) : name = XlsxWorkbook.sheetName(name);

  final String name;
  final List<List<XlsxCell?>> _rows = [];

  /// Characters wide, by zero-based column.
  final Map<int, double> columnWidths = {};

  /// Rows kept on screen while scrolling.
  int frozenRows = 0;

  /// A range such as `A10:S20` that gets filter buttons.
  String? autoFilter;

  bool landscape = false;

  List<List<XlsxCell?>> get rows => List.unmodifiable(_rows);

  /// Appends a row and returns its 1-based number.
  int add(List<XlsxCell?> cells) {
    _rows.add(List.unmodifiable(cells));
    return _rows.length;
  }

  /// Appends an empty row and returns its number.
  int blank() => add(const []);

  /// Appends a row of plain values: strings, numbers, dates, booleans.
  int addValues(List<Object?> values, {XlsxStyle style = XlsxStyle.normal}) =>
      add([
        for (final v in values)
          if (v == null) null else XlsxCell(v, style: style),
      ]);

  /// The row number the next [add] will get.
  int get nextRow => _rows.length + 1;
}

/// A workbook of [sheets], encoded with [encode].
class XlsxWorkbook {
  XlsxWorkbook({required this.title, this.creator = 'GRÚAS RD'});

  final String title;
  final String creator;
  final List<XlsxSheet> sheets = [];

  XlsxSheet sheet(String name) {
    final sheet = XlsxSheet(_unique(sheetName(name)));
    sheets.add(sheet);
    return sheet;
  }

  String _unique(String name) {
    var candidate = name;
    var n = 2;
    while (sheets.any((s) => s.name.toLowerCase() == candidate.toLowerCase())) {
      final suffix = ' ($n)';
      candidate = '${name.substring(0, name.length.clamp(0, 31 - suffix.length))}$suffix';
      n++;
    }
    return candidate;
  }

  /// A name Excel accepts: at most 31 characters, none of `[]:*?/\`.
  static String sheetName(String name) {
    final cleaned = name.replaceAll(RegExp(r'[\[\]:*?/\\]'), ' ').trim();
    final safe = cleaned.isEmpty ? 'Hoja' : cleaned;
    return safe.length > 31 ? safe.substring(0, 31) : safe;
  }

  /// `A`, `B`, … `Z`, `AA` for a zero-based column.
  static String column(int index) {
    var n = index + 1;
    final out = StringBuffer();
    final letters = <String>[];
    while (n > 0) {
      final rem = (n - 1) % 26;
      letters.insert(0, String.fromCharCode(65 + rem));
      n = (n - 1) ~/ 26;
    }
    out.writeAll(letters);
    return out.toString();
  }

  /// `C12` for zero-based [col] and 1-based [row].
  static String ref(int col, int row) => '${column(col)}$row';

  /// Excel's day number for a wall-clock date: days since 30 Dec 1899.
  static double serial(DateTime localWallClock) {
    final utc = DateTime.utc(
      localWallClock.year,
      localWallClock.month,
      localWallClock.day,
      localWallClock.hour,
      localWallClock.minute,
      localWallClock.second,
    );
    return (utc.millisecondsSinceEpoch - _epoch.millisecondsSinceEpoch) / Duration.millisecondsPerDay;
  }

  static final DateTime _epoch = DateTime.utc(1899, 12, 30);

  static const _mainNs = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
  static const _relNs = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';

  static final RegExp _invalidXml = RegExp('[\x00-\x08\x0B\x0C\x0E-\x1F\uFFFE\uFFFF]');

  static String _escape(String value) => value
      .replaceAll(_invalidXml, '')
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  static String _number(num value) {
    if (value is int) return value.toString();
    final d = value.toDouble();
    if (d.isNaN || d.isInfinite) return '0';
    if (d == d.truncateToDouble() && d.abs() < 1e15) return d.toInt().toString();
    return d.toString();
  }

  String _cellXml(XlsxCell cell, String at) {
    final s = cell.style.index == 0 ? '' : ' s="${cell.style.index}"';
    final f = cell.formula == null ? '' : '<f>${_escape(cell.formula!)}</f>';
    final value = cell.value;
    return switch (value) {
      null when f.isEmpty => '<c r="$at"$s/>',
      null => '<c r="$at"$s>$f</c>',
      // Nothing typed is an empty cell, not an empty string: filters and
      // blank checks treat them differently.
      '' when f.isEmpty => '<c r="$at"$s/>',
      final String text when f.isEmpty =>
        '<c r="$at"$s t="inlineStr"><is><t xml:space="preserve">${_escape(text)}</t></is></c>',
      final String text => '<c r="$at"$s t="str">$f<v>${_escape(text)}</v></c>',
      final bool flag => '<c r="$at"$s t="b">$f<v>${flag ? 1 : 0}</v></c>',
      final num n => '<c r="$at"$s>$f<v>${_number(n)}</v></c>',
      final DateTime d => '<c r="$at"$s>$f<v>${_number(serial(d))}</v></c>',
      _ => '<c r="$at"$s t="inlineStr"><is><t xml:space="preserve">'
          '${_escape(value.toString())}</t></is></c>',
    };
  }

  String _sheetXml(XlsxSheet sheet) {
    final out = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
      ..write('<worksheet xmlns="$_mainNs" xmlns:r="$_relNs">')
      ..write('<sheetPr><pageSetUpPr fitToPage="1"/></sheetPr>');

    var maxCol = 0;
    for (final row in sheet._rows) {
      if (row.length > maxCol) maxCol = row.length;
    }
    final lastRow = sheet._rows.isEmpty ? 1 : sheet._rows.length;
    out
      ..write('<dimension ref="A1:${ref(maxCol == 0 ? 0 : maxCol - 1, lastRow)}"/>')
      ..write('<sheetViews><sheetView workbookViewId="0"');
    if (sheet.frozenRows > 0) {
      out
        ..write('><pane ySplit="${sheet.frozenRows}" '
            'topLeftCell="A${sheet.frozenRows + 1}" activePane="bottomLeft" state="frozen"/>')
        ..write('<selection pane="bottomLeft" activeCell="A${sheet.frozenRows + 1}" '
            'sqref="A${sheet.frozenRows + 1}"/></sheetView>');
    } else {
      out.write('/>');
    }
    out.write('</sheetViews><sheetFormatPr defaultRowHeight="15"/>');

    if (sheet.columnWidths.isNotEmpty) {
      out.write('<cols>');
      final columns = sheet.columnWidths.keys.toList()..sort();
      for (final c in columns) {
        out.write('<col min="${c + 1}" max="${c + 1}" '
            'width="${sheet.columnWidths[c]!.toStringAsFixed(1)}" customWidth="1"/>');
      }
      out.write('</cols>');
    }

    out.write('<sheetData>');
    for (final (i, row) in sheet._rows.indexed) {
      final r = i + 1;
      if (row.every((c) => c == null)) continue;
      out.write('<row r="$r">');
      for (final (c, cell) in row.indexed) {
        if (cell == null) continue;
        out.write(_cellXml(cell, ref(c, r)));
      }
      out.write('</row>');
    }
    out.write('</sheetData>');

    if (sheet.autoFilter != null) out.write('<autoFilter ref="${sheet.autoFilter}"/>');
    out
      ..write('<pageMargins left="0.4" right="0.4" top="0.5" bottom="0.5" header="0.3" footer="0.3"/>')
      ..write('<pageSetup paperSize="9" orientation="${sheet.landscape ? 'landscape' : 'portrait'}" '
          'fitToWidth="1" fitToHeight="0"/>')
      ..write('</worksheet>');
    return out.toString();
  }

  static const _styles = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<styleSheet xmlns="$_mainNs">'
      '<numFmts count="4">'
      r'<numFmt numFmtId="164" formatCode="&quot;RD$&quot;#,##0.00"/>'
      '<numFmt numFmtId="165" formatCode="dd/mm/yyyy"/>'
      '<numFmt numFmtId="166" formatCode="0.0"/>'
      '<numFmt numFmtId="167" formatCode="dd/mm/yyyy hh:mm"/>'
      '</numFmts>'
      '<fonts count="5">'
      '<font><sz val="11"/><name val="Calibri"/><family val="2"/></font>'
      '<font><b/><sz val="11"/><name val="Calibri"/><family val="2"/></font>'
      '<font><b/><sz val="14"/><name val="Calibri"/><family val="2"/></font>'
      '<font><b/><sz val="11"/><color rgb="FFB42318"/><name val="Calibri"/><family val="2"/></font>'
      '<font><sz val="10"/><color rgb="FF6B6564"/><name val="Calibri"/><family val="2"/></font>'
      '</fonts>'
      '<fills count="3">'
      '<fill><patternFill patternType="none"/></fill>'
      '<fill><patternFill patternType="gray125"/></fill>'
      '<fill><patternFill patternType="solid"><fgColor rgb="FFF4F1F0"/><bgColor indexed="64"/></patternFill></fill>'
      '</fills>'
      '<borders count="2">'
      '<border><left/><right/><top/><bottom/><diagonal/></border>'
      '<border><left/><right/><top/><bottom style="thin"><color rgb="FF9E9897"/></bottom><diagonal/></border>'
      '</borders>'
      '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
      '<cellXfs count="13">'
      // normal
      '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
      // bold
      '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>'
      // money
      '<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
      // date
      '<xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
      // moneyBold
      '<xf numFmtId="164" fontId="1" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1"/>'
      // header
      '<xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" '
      'applyBorder="1" applyAlignment="1"><alignment vertical="center" wrapText="1"/></xf>'
      // title
      '<xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/>'
      // decimal
      '<xf numFmtId="166" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
      // warning
      '<xf numFmtId="0" fontId="3" fillId="0" borderId="0" xfId="0" applyFont="1"/>'
      // integer
      '<xf numFmtId="3" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
      // muted
      '<xf numFmtId="0" fontId="4" fillId="0" borderId="0" xfId="0" applyFont="1"/>'
      // dateTime
      '<xf numFmtId="167" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
      // integerBold
      '<xf numFmtId="3" fontId="1" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1"/>'
      '</cellXfs>'
      '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
      '</styleSheet>';

  /// The workbook as `.xlsx` bytes. [now] stamps the document properties.
  Uint8List encode({DateTime? now}) {
    if (sheets.isEmpty) sheet('Hoja');
    final stamp = (now ?? DateTime.now()).toUtc();
    final iso = '${stamp.toIso8601String().split('.').first}Z';

    final contentTypes = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
      ..write('<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">')
      ..write('<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>')
      ..write('<Default Extension="xml" ContentType="application/xml"/>')
      ..write('<Override PartName="/xl/workbook.xml" '
          'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>')
      ..write('<Override PartName="/xl/styles.xml" '
          'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>')
      ..write('<Override PartName="/docProps/core.xml" '
          'ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>');
    for (var i = 1; i <= sheets.length; i++) {
      contentTypes.write('<Override PartName="/xl/worksheets/sheet$i.xml" '
          'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>');
    }
    contentTypes.write('</Types>');

    const rootRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" '
        'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" '
        'Target="xl/workbook.xml"/>'
        '<Relationship Id="rId2" '
        'Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" '
        'Target="docProps/core.xml"/>'
        '</Relationships>';

    final core = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<cp:coreProperties '
        'xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:dcterms="http://purl.org/dc/terms/" '
        'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
        '<dc:title>${_escape(title)}</dc:title>'
        '<dc:creator>${_escape(creator)}</dc:creator>'
        '<dcterms:created xsi:type="dcterms:W3CDTF">$iso</dcterms:created>'
        '<dcterms:modified xsi:type="dcterms:W3CDTF">$iso</dcterms:modified>'
        '</cp:coreProperties>';

    final workbook = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
      ..write('<workbook xmlns="$_mainNs" xmlns:r="$_relNs">')
      ..write('<bookViews><workbookView/></bookViews><sheets>');
    for (final (i, s) in sheets.indexed) {
      workbook.write('<sheet name="${_escape(s.name)}" sheetId="${i + 1}" r:id="rId${i + 1}"/>');
    }
    workbook.write('</sheets>');
    final filters = [
      for (final (i, s) in sheets.indexed)
        if (s.autoFilter != null) (i, s),
    ];
    if (filters.isNotEmpty) {
      workbook.write('<definedNames>');
      for (final (i, s) in filters) {
        final quoted = "'${s.name.replaceAll("'", "''")}'";
        final absolute = s.autoFilter!
            .split(':')
            .map((part) => r'$' + part.replaceAllMapped(RegExp(r'(\d+)$'), (m) => r'$' + m[1]!))
            .join(':');
        workbook.write('<definedName name="_xlnm._FilterDatabase" localSheetId="$i" hidden="1">'
            '${_escape('$quoted!$absolute')}</definedName>');
      }
      workbook.write('</definedNames>');
    }
    workbook.write('<calcPr calcId="191029" fullCalcOnLoad="1"/></workbook>');

    final workbookRels = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
      ..write('<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">');
    for (var i = 1; i <= sheets.length; i++) {
      workbookRels.write('<Relationship Id="rId$i" '
          'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" '
          'Target="worksheets/sheet$i.xml"/>');
    }
    workbookRels
      ..write('<Relationship Id="rId${sheets.length + 1}" '
          'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" '
          'Target="styles.xml"/>')
      ..write('</Relationships>');

    return StoredZip.encode(
      {
        '[Content_Types].xml': utf8.encode(contentTypes.toString()),
        '_rels/.rels': utf8.encode(rootRels),
        'docProps/core.xml': utf8.encode(core),
        'xl/workbook.xml': utf8.encode(workbook.toString()),
        'xl/_rels/workbook.xml.rels': utf8.encode(workbookRels.toString()),
        'xl/styles.xml': utf8.encode(_styles),
        for (final (i, s) in sheets.indexed)
          'xl/worksheets/sheet${i + 1}.xml': utf8.encode(_sheetXml(s)),
      },
      modified: stamp,
    );
  }
}

/// A zip archive with every entry stored as is — the one kind of zip needed
/// here, and small enough to get right by hand.
abstract final class StoredZip {
  static final Uint32List _crcTable = () {
    final table = Uint32List(256);
    for (var n = 0; n < 256; n++) {
      var c = n;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
      }
      table[n] = c;
    }
    return table;
  }();

  static int crc32(List<int> bytes) {
    var crc = 0xFFFFFFFF;
    for (final b in bytes) {
      crc = _crcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  static Uint8List encode(Map<String, List<int>> files, {required DateTime modified}) {
    final t = modified.toUtc();
    final dosTime = (t.hour << 11) | (t.minute << 5) | (t.second ~/ 2);
    final dosDate = (((t.year - 1980).clamp(0, 127)) << 9) | (t.month << 5) | t.day;

    final out = BytesBuilder(copy: false);
    final central = BytesBuilder(copy: false);
    var offset = 0;

    for (final entry in files.entries) {
      final name = utf8.encode(entry.key);
      final data = entry.value;
      final crc = crc32(data);

      final local = ByteData(30)
        ..setUint32(0, 0x04034b50, Endian.little)
        ..setUint16(4, 20, Endian.little)
        ..setUint16(6, 0x0800, Endian.little)
        ..setUint16(8, 0, Endian.little)
        ..setUint16(10, dosTime, Endian.little)
        ..setUint16(12, dosDate, Endian.little)
        ..setUint32(14, crc, Endian.little)
        ..setUint32(18, data.length, Endian.little)
        ..setUint32(22, data.length, Endian.little)
        ..setUint16(26, name.length, Endian.little)
        ..setUint16(28, 0, Endian.little);
      out
        ..add(local.buffer.asUint8List())
        ..add(name)
        ..add(data);

      final header = ByteData(46)
        ..setUint32(0, 0x02014b50, Endian.little)
        ..setUint16(4, 20, Endian.little)
        ..setUint16(6, 20, Endian.little)
        ..setUint16(8, 0x0800, Endian.little)
        ..setUint16(10, 0, Endian.little)
        ..setUint16(12, dosTime, Endian.little)
        ..setUint16(14, dosDate, Endian.little)
        ..setUint32(16, crc, Endian.little)
        ..setUint32(20, data.length, Endian.little)
        ..setUint32(24, data.length, Endian.little)
        ..setUint16(28, name.length, Endian.little)
        ..setUint16(30, 0, Endian.little)
        ..setUint16(32, 0, Endian.little)
        ..setUint16(34, 0, Endian.little)
        ..setUint16(36, 0, Endian.little)
        ..setUint32(38, 0, Endian.little)
        ..setUint32(42, offset, Endian.little);
      central
        ..add(header.buffer.asUint8List())
        ..add(name);

      offset += 30 + name.length + data.length;
    }

    final centralBytes = central.takeBytes();
    final end = ByteData(22)
      ..setUint32(0, 0x06054b50, Endian.little)
      ..setUint16(4, 0, Endian.little)
      ..setUint16(6, 0, Endian.little)
      ..setUint16(8, files.length, Endian.little)
      ..setUint16(10, files.length, Endian.little)
      ..setUint32(12, centralBytes.length, Endian.little)
      ..setUint32(16, offset, Endian.little)
      ..setUint16(20, 0, Endian.little);
    out
      ..add(centralBytes)
      ..add(end.buffer.asUint8List());
    return out.takeBytes();
  }

  /// The entries of a zip [encode] wrote, by name. For tests and checks.
  static Map<String, Uint8List> decode(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    final entries = <String, Uint8List>{};
    var at = 0;
    while (at + 30 <= bytes.length && data.getUint32(at, Endian.little) == 0x04034b50) {
      final method = data.getUint16(at + 8, Endian.little);
      final crc = data.getUint32(at + 14, Endian.little);
      final size = data.getUint32(at + 18, Endian.little);
      final nameLength = data.getUint16(at + 26, Endian.little);
      final extraLength = data.getUint16(at + 28, Endian.little);
      if (method != 0) throw const FormatException('Only stored entries are supported.');
      final nameStart = at + 30;
      final dataStart = nameStart + nameLength + extraLength;
      final name = utf8.decode(bytes.sublist(nameStart, nameStart + nameLength));
      final content = Uint8List.sublistView(bytes, dataStart, dataStart + size);
      if (crc32(content) != crc) throw FormatException('Bad CRC for $name');
      entries[name] = content;
      at = dataStart + size;
    }
    return entries;
  }
}
