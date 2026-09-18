import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

import '../shared/toast.dart';

/// Zone prices for one table owner: a company, or the default list when
/// [insurerId] is null. One class of vehicle at a time.
class ZoneTariffPanel extends StatefulWidget {
  const ZoneTariffPanel({
    required this.insurerId,
    this.canEdit = true,
    super.key,
  });

  final String? insurerId;

  /// Only an admin changes prices; anyone else reads them.
  final bool canEdit;

  @override
  State<ZoneTariffPanel> createState() => _ZoneTariffPanelState();
}

class _ZoneTariffPanelState extends State<ZoneTariffPanel> {
  VehicleClass _class = VehicleClass.light;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Sized to its three words rather than stretched across the window:
        // full width, each segment read as a page-wide tab bar.
        Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<VehicleClass>(
            key: const Key('tariff-class'),
            segments: [
              for (final c in VehicleClass.priced)
                ButtonSegment(value: c, label: Text(c.label)),
            ],
            selected: {_class},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _class = s.first),
          ),
        ),
        const SizedBox(height: Insets.lg),
        ZoneTableEditor(
          // A fresh editor per table: typed-in rows belong to the table they
          // were typed for.
          key: ValueKey('${widget.insurerId ?? 'default'}-${_class.wire}'),
          insurerId: widget.insurerId,
          vehicleClass: _class,
          canEdit: widget.canEdit,
        ),
      ],
    );
  }
}

/// The table's column widths. Wide enough for what goes in them — a limit in
/// kilometres, a price of a few thousand pesos — and no wider.
const _kmColumn = 132.0;
const _moneyColumn = 176.0;

/// The two km columns, the two money ones, their gaps and the remove button.
const _tableWidth = _kmColumn * 2 + _moneyColumn * 2 + Insets.md * 2 + 48;

class _Row {
  _Row({required int? maxKm, required int baseCents, required int extraKmCents})
    : max = TextEditingController(text: maxKm?.toString() ?? ''),
      base = TextEditingController(text: _pesos(baseCents)),
      extra = TextEditingController(text: _pesos(extraKmCents));

  final TextEditingController max;
  final TextEditingController base;
  final TextEditingController extra;

  static String _pesos(int cents) =>
      cents % 100 == 0 ? '${cents ~/ 100}' : (cents / 100).toStringAsFixed(2);

  void dispose() {
    max.dispose();
    base.dispose();
    extra.dispose();
  }
}

/// Edits one class's whole table and saves it at once.
///
/// A zone starts where the one before it ends, so only the upper limits are
/// typed; the last zone has none. The server refuses a table that does not
/// cover every distance, and so does this form before sending it.
class ZoneTableEditor extends ConsumerStatefulWidget {
  const ZoneTableEditor({
    required this.insurerId,
    required this.vehicleClass,
    this.canEdit = true,
    super.key,
  });

  final String? insurerId;
  final VehicleClass vehicleClass;
  final bool canEdit;

  @override
  ConsumerState<ZoneTableEditor> createState() => _ZoneTableEditorState();
}

class _ZoneTableEditorState extends ConsumerState<ZoneTableEditor>
    with AutomaticKeepAliveClientMixin {
  List<_Row>? _rows;

  /// The stored table the rows were filled from.
  List<PricingRule> _loaded = const [];

  // Kept while the company page switches tabs: typed prices are not lost.
  @override
  bool get wantKeepAlive => true;

  static String _shape(List<PricingRule> rules) => [
    for (final r in rules)
      '${r.zoneMinKm}-${r.zoneMaxKm}-${r.baseCents}-${r.extraKmCents}',
  ].join('|');

  /// Whether the rows say something other than the table they came from.
  bool get _edited {
    final (typed, _) = _read();
    return typed == null || _shape(typed) != _shape(_loaded);
  }

  var _saving = false;
  String? _error;

  bool get _isDefault => widget.insurerId == null;

  @override
  void dispose() {
    for (final r in _rows ?? const <_Row>[]) {
      r.dispose();
    }
    super.dispose();
  }

  /// The table as it stands: this owner's rows, else what applies instead.
  (List<PricingRule>, bool) _current(
    List<PricingRule> own,
    List<PricingRule> defaults,
  ) {
    List<PricingRule> ofClass(List<PricingRule> rules) => [
      for (final r in rules)
        if (r.vehicleClass == widget.vehicleClass) r,
    ]..sort((a, b) => a.zoneMinKm.compareTo(b.zoneMinKm));
    final mine = ofClass(own);
    if (mine.isNotEmpty) return (mine, true);
    final stored = ofClass(defaults);
    if (!_isDefault && stored.isNotEmpty) return (stored, false);
    return (ZonePricing.defaultRulesFor(widget.vehicleClass), false);
  }

  void _load(List<PricingRule> rules) {
    final old = _rows;
    if (old != null) {
      // Still attached to this frame's fields; let them go after it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final r in old) {
          r.dispose();
        }
      });
    }
    _loaded = rules;
    _rows = [
      for (final r in rules)
        _Row(
          maxKm: r.zoneMaxKm,
          baseCents: r.baseCents,
          extraKmCents: r.extraKmCents,
        ),
    ];
  }

  /// The rows as typed, or the reason they cannot be read.
  (List<PricingRule>?, String?) _read() {
    final rows = _rows!;
    final rules = <PricingRule>[];
    var min = 0;
    for (var i = 0; i < rows.length; i++) {
      final last = i == rows.length - 1;
      final row = rows[i];
      int? max;
      if (!last) {
        max = int.tryParse(row.max.text.trim());
        if (max == null) {
          return (null, 'Escribe hasta qué kilómetro llega la zona ${i + 1}.');
        }
      }
      final base = double.tryParse(row.base.text.trim().replaceAll(',', ''));
      final extra = double.tryParse(
        row.extra.text.trim().isEmpty
            ? '0'
            : row.extra.text.trim().replaceAll(',', ''),
      );
      if (base == null || base < 0 || extra == null || extra < 0) {
        return (null, 'Revisa los precios de la zona ${i + 1}.');
      }
      rules.add(
        PricingRule(
          vehicleClass: widget.vehicleClass,
          zoneMinKm: min,
          zoneMaxKm: max,
          baseCents: Money.pesos(base),
          extraKmCents: Money.pesos(extra),
          insurerId: widget.insurerId,
        ),
      );
      min = max ?? min;
    }
    final problem = ZonePricing.tableProblem(rules);
    return problem == null ? (rules, null) : (null, problem);
  }

  void _addZone() {
    final rows = _rows!;
    // A new bounded zone just before the open one, 10 km past the last limit.
    final lastLimit = rows.length < 2
        ? 0
        : int.tryParse(rows[rows.length - 2].max.text) ?? 0;
    final open = rows.last;
    rows.insert(
      rows.length - 1,
      _Row(
        maxKm: lastLimit + 10,
        baseCents: Money.pesos(double.tryParse(open.base.text) ?? 0),
        extraKmCents: 0,
      ),
    );
    setState(() {});
  }

  void _removeZone(int index) {
    _rows!.removeAt(index).dispose();
    setState(() {});
  }

  Future<void> _save() async {
    final (rules, problem) = _read();
    if (rules == null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await ref
        .read(functionsGatewayProvider)
        .savePricingTable(
          insurerId: widget.insurerId,
          vehicleClass: widget.vehicleClass,
          rows: rules,
        );
    if (!mounted) return;
    setState(() => _saving = false);
    switch (result) {
      case Ok():
        showToast(context, 'Tarifa de ${widget.vehicleClass.label} guardada.');
      case Err(:final failure):
        setState(() => _error = failure.userMessage);
    }
  }

  Future<void> _reset() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await ref
        .read(functionsGatewayProvider)
        .resetPricingTable(
          insurerId: widget.insurerId,
          vehicleClass: widget.vehicleClass,
        );
    if (!mounted) return;
    setState(() {
      _saving = false;
      // Back to the stored table, whenever its new version arrives.
      _load(_loaded);
    });
    switch (result) {
      case Ok():
        showToast(
          context,
          _isDefault
              ? 'Se volvió a la lista de precios incluida.'
              : 'Esta aseguradora vuelve a la tarifa base.',
        );
      case Err(:final failure):
        setState(() => _error = failure.userMessage);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final own = ref.watch(pricingRulesProvider(widget.insurerId ?? '')).value;
    final defaults = ref.watch(pricingRulesProvider('')).value;
    if (own == null || defaults == null) return const BrandLoader();

    final (rules, isOwn) = _current(own, defaults);
    // Follows the stored table — a reset, another admin's save — unless
    // something typed here would be thrown away.
    if (_rows == null ||
        (!_saving && !_edited && _shape(rules) != _shape(_loaded))) {
      _load(rules);
    }
    final rows = _rows!;
    final muted = text.bodySmall?.copyWith(color: palette.textMuted);

    final (preview, _) = _read();
    const samples = [5.0, 20.0, 62.0];

    return FloatingCard(
      // The table is as wide as its columns, and the notice above it and the
      // buttons below it line up with that rather than running off across a
      // wide monitor on their own.
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _tableWidth),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InlineNotice(
              key: const Key('tariff-source'),
              tone: NoticeTone.info,
              icon: Icons.info_outline,
              message: switch ((_isDefault, isOwn)) {
                (true, true) => 'Tarifa base guardada. La usan todas las aseguradoras sin precio propio.',
                (true, false) => 'Lista de precios incluida. Al guardar, pasa a ser la tarifa base.',
                (false, true) => 'Precio negociado de esta aseguradora.',
                (false, false) => 'Esta aseguradora usa la tarifa base. Al guardar, tendrá su propio precio.',
              },
            ),
            const SizedBox(height: Insets.lg),
            // Columns sized to what goes in them. Stretched, a four-digit price
            // sat in a box wide enough for a paragraph, and the eye had to cross
            // it to reach the next figure.
            Row(
              children: [
                const SizedBox(width: _kmColumn, child: Text('')),
                SizedBox(
                  width: _kmColumn,
                  child: Text('Hasta', style: muted),
                ),
                const SizedBox(width: Insets.md),
                SizedBox(
                  width: _moneyColumn,
                  child: Text('Precio (sin ITBIS)', style: muted),
                ),
                const SizedBox(width: Insets.md),
                SizedBox(
                  width: _moneyColumn,
                  child: Text('Extra por km', style: muted),
                ),
              ],
            ),
            const SizedBox(height: Insets.xs),
            const Divider(height: 1),
            for (var i = 0; i < rows.length; i++)
              Padding(
                key: Key('zone-row-$i'),
                padding: const EdgeInsets.symmetric(vertical: Insets.sm),
                child: Row(
                  children: [
                    // Where the zone starts: the one before it ended there, so
                    // it is read, never typed.
                    SizedBox(
                      width: _kmColumn,
                      child: Text(
                        'Desde ${i == 0 ? '0' : rows[i - 1].max.text} km',
                        style: muted,
                      ),
                    ),
                    SizedBox(
                      width: _kmColumn,
                      child: i == rows.length - 1
                          ? Text('Sin límite', style: muted)
                          : TextField(
                              key: Key('zone-max-$i'),
                              controller: rows[i].max,
                              enabled: widget.canEdit,
                              keyboardType: TextInputType.number,
                              onChanged: (_) => setState(() {}),
                              decoration: const InputDecoration(
                                isDense: true,
                                suffixText: 'km',
                              ),
                            ),
                    ),
                    const SizedBox(width: Insets.md),
                    SizedBox(
                      width: _moneyColumn,
                      child: TextField(
                        key: Key('zone-base-$i'),
                        controller: rows[i].base,
                        enabled: widget.canEdit,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          isDense: true,
                          prefixText: r'RD$ ',
                        ),
                      ),
                    ),
                    const SizedBox(width: Insets.md),
                    SizedBox(
                      width: _moneyColumn,
                      child: TextField(
                        key: Key('zone-extra-$i'),
                        controller: rows[i].extra,
                        enabled: widget.canEdit,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          isDense: true,
                          prefixText: r'RD$ ',
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 48,
                      child:
                          widget.canEdit &&
                              rows.length > 1 &&
                              i < rows.length - 1
                          ? IconButton(
                              key: Key('zone-remove-$i'),
                              tooltip: 'Quitar zona',
                              onPressed: () => _removeZone(i),
                              icon: const Icon(
                                Icons.remove_circle_outline,
                                size: 20,
                              ),
                            )
                          : null,
                    ),
                  ],
                ),
              ),
            if (widget.canEdit)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('zone-add'),
                  onPressed: _addZone,
                  icon: const Icon(Icons.add),
                  label: const Text('Agregar zona'),
                ),
              ),
            const SizedBox(height: Insets.md),
            // What the table above charges, recomputed on every keystroke. It is
            // the only way to tell a good table from a typo, so it is given the
            // weight of an answer rather than of a footnote.
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: Insets.lg,
                  vertical: Insets.md,
                ),
                decoration: BoxDecoration(
                  color: palette.surfaceSubtle,
                  borderRadius: Corners.brMd,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.calculate_outlined,
                      size: 18,
                      color: palette.textMuted,
                    ),
                    const SizedBox(width: Insets.sm),
                    Text(
                      preview == null
                          ? 'Ejemplos: completa la tabla para verlos.'
                          : 'Ejemplos: ${[for (final km in samples) '${km.toStringAsFixed(0)} km = ${ZonePricing.quote(rules: preview, distanceKm: km, tariff: ZoneTariffSource.standard).subtotalCents.formatDOP}'].join(' · ')}',
                      key: const Key('tariff-examples'),
                      style: text.bodyMedium?.copyWith(color: palette.text),
                    ),
                  ],
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: Insets.md),
              InlineNotice(
                key: const Key('tariff-error'),
                tone: NoticeTone.error,
                icon: Icons.error_outline,
                message: _error!,
              ),
            ],
            if (widget.canEdit) ...[
              const SizedBox(height: Insets.lg),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (isOwn)
                    TextButton(
                      key: const Key('tariff-reset'),
                      onPressed: _saving ? null : _reset,
                      child: Text(
                        _isDefault
                            ? 'Volver a la lista incluida'
                            : 'Usar la tarifa base',
                      ),
                    ),
                  const SizedBox(width: Insets.sm),
                  ElevatedButton(
                    key: const Key('tariff-save'),
                    onPressed: _saving ? null : _save,
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(0, 42),
                    ),
                    child: const Text('Guardar tarifa'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
