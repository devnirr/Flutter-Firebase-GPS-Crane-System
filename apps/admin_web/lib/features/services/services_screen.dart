import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

import 'service_detail_dialog.dart';

/// Every service, past and present.
///
/// Operaciones is the live map: what is happening now. This is the record: the
/// job a customer calls about three days later, the week's cancellations, the
/// tow a chofer says he was never paid for. So it is a table, newest first,
/// filtered on the server by state and period and searched by what the person
/// on the phone can read out — the code, their number, the chofer, a plate.
class ServicesScreen extends ConsumerStatefulWidget {
  const ServicesScreen({this.initialQuery, this.openServiceId, super.key});

  /// Search text handed over from the top bar.
  final String? initialQuery;

  /// A service to open on arrival: a pasted link to one job.
  final String? openServiceId;

  @override
  ConsumerState<ServicesScreen> createState() => _ServicesScreenState();
}

/// What the list can be narrowed to, as the office thinks of a job's fate.
enum _StatusFilter {
  all('Todos', null),
  active('En curso', ServiceStatus.active),
  needsManual('Requieren asignación', {ServiceStatus.needsManual}),
  done('Completados', {ServiceStatus.completed, ServiceStatus.closed}),
  cancelled('Cancelados', {ServiceStatus.cancelled}),
  lost('Expirados o con problema', {ServiceStatus.expired, ServiceStatus.failed});

  const _StatusFilter(this.label, this.statuses);

  final String label;
  final Set<ServiceStatus>? statuses;
}

enum _Period {
  today('Hoy'),
  week('Últimos 7 días'),
  month('Últimos 30 días'),
  all('Todo');

  const _Period(this.label);

  final String label;

  /// The first instant in the window, by the Dominican calendar: "hoy" at
  /// 1 a.m. in Santo Domingo is not yesterday evening in UTC.
  DateTime? start(DateTime now) => switch (this) {
        _Period.today => DoTime.startOfLocalDay(now),
        _Period.week =>
          DoTime.startOfLocalDay(now).subtract(const Duration(days: 6)),
        _Period.month =>
          DoTime.startOfLocalDay(now).subtract(const Duration(days: 29)),
        _Period.all => null,
      };
}

class _ServicesScreenState extends ConsumerState<ServicesScreen> {
  static const _pageSize = 50;

  /// What the office types when a customer reads their code: `GR-260908-0431`,
  /// with or without the dashes.
  static final _codePattern = RegExp(r'^GR-?\d{6}-?\d{3,}$', caseSensitive: false);

  final _search = TextEditingController();

  _StatusFilter _filter = _StatusFilter.all;
  _Period _period = _Period.month;

  final _items = <Service>[];
  Object? _cursor;
  var _hasMore = false;
  var _loading = false;
  Failure? _error;

  /// Bumped on every fresh query, so a slow page that answers after the
  /// filters changed is thrown away instead of mixed into the new list.
  var _generation = 0;

  String get _query => _search.text.trim();

  @override
  void initState() {
    super.initState();
    _search.text = widget.initialQuery ?? '';
    unawaited(_reload());
    final id = widget.openServiceId;
    if (id != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openById(id));
    }
    if (_codePattern.hasMatch(_query)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _lookUpCode());
    }
  }

  @override
  void didUpdateWidget(ServicesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A second search from the top bar while already on this page arrives as
    // a new query parameter, not a new page.
    final query = widget.initialQuery;
    if (query != null && query != oldWidget.initialQuery) {
      _search.text = query;
      setState(() {});
      if (_codePattern.hasMatch(query.trim())) unawaited(_lookUpCode());
    }
    final id = widget.openServiceId;
    if (id != null && id != oldWidget.openServiceId) unawaited(_openById(id));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Data
  // ---------------------------------------------------------------------------

  Future<void> _reload() async {
    final generation = ++_generation;
    setState(() {
      _items.clear();
      _cursor = null;
      _hasMore = false;
      _error = null;
      _loading = true;
    });
    await _fetch(generation);
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() => _loading = true);
    await _fetch(_generation);
  }

  Future<void> _fetch(int generation) async {
    final result = await ref.read(serviceRepositoryProvider).fetchServices(
          statuses: _filter.statuses,
          from: _period.start(DateTime.now().toUtc()),
          limit: _pageSize,
          cursor: _cursor,
        );
    if (!mounted || generation != _generation) return;

    setState(() {
      _loading = false;
      switch (result) {
        case Ok(value: final page):
          _items.addAll(page.items);
          _cursor = page.cursor;
          _hasMore = page.hasMore;
        case Err(:final failure):
          _error = failure;
      }
    });
  }

  /// Opens a service by its code, wherever it is in time — the customer on
  /// the phone may be calling about last year.
  Future<void> _lookUpCode() async {
    final code = _query.toUpperCase();
    final normalized = code.contains('-')
        ? code
        : code.replaceFirstMapped(
            RegExp(r'^GR(\d{6})(\d+)$'),
            (m) => 'GR-${m[1]}-${m[2]}',
          );

    final result =
        await ref.read(serviceRepositoryProvider).fetchServiceByCode(normalized);
    if (!mounted) return;

    switch (result) {
      case Ok(value: final service?):
        await showServiceDetailDialog(context, service);
      case Ok():
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No hay un servicio con el código $normalized.')),
        );
      case Err(:final failure):
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(failure.userMessage)),
        );
    }
  }

  Future<void> _openById(String id) async {
    final loaded = _items.where((s) => s.id == id).firstOrNull;
    final service = loaded ??
        await ref
            .read(serviceByIdProvider(id).future)
            .catchError((Object _) => null);
    if (!mounted) return;
    if (service == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ese servicio no existe.')),
      );
      return;
    }
    await showServiceDetailDialog(context, service);
  }

  /// Narrows the loaded rows to the search. Digits match phone numbers however
  /// they were typed; everything else matches names, codes and plates.
  List<Service> get _visible {
    final query = _query.toLowerCase();
    if (query.isEmpty) return _items;
    final digits = DoValidators.digits(query);

    return _items.where((s) {
      final haystack = [
        s.code,
        s.clientName,
        s.driverName,
        s.truckPlate,
        s.vehicle.plate,
      ].join(' ').toLowerCase();
      if (haystack.contains(query)) return true;
      // Three digits is the least that means "a phone number" rather than a
      // stray digit in a code.
      return digits.length >= 3 &&
          (DoValidators.digits(s.clientPhone).contains(digits) ||
              DoValidators.digits(s.driverPhone).contains(digits));
    }).toList();
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final visible = _visible;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(Insets.xl),
          child: Wrap(
            spacing: Insets.md,
            runSpacing: Insets.md,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Servicios', style: text.headlineSmall),
              SizedBox(
                width: 320,
                height: 38,
                child: TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) {
                    if (_codePattern.hasMatch(_query)) unawaited(_lookUpCode());
                  },
                  decoration: InputDecoration(
                    hintText: 'Código, teléfono, cliente, chofer o placa',
                    prefixIcon: const Icon(Icons.search, size: 18),
                    contentPadding: EdgeInsets.zero,
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Borrar búsqueda',
                            icon: const Icon(Icons.close, size: 16),
                            onPressed: () => setState(_search.clear),
                          ),
                  ),
                ),
              ),
              _Dropdown<_StatusFilter>(
                value: _filter,
                values: _StatusFilter.values,
                label: (f) => f.label,
                onChanged: (value) {
                  _filter = value;
                  unawaited(_reload());
                },
              ),
              _Dropdown<_Period>(
                value: _period,
                values: _Period.values,
                label: (p) => p.label,
                onChanged: (value) {
                  _period = value;
                  unawaited(_reload());
                },
              ),
              IconButton(
                tooltip: 'Actualizar',
                onPressed: _loading ? null : () => unawaited(_reload()),
                icon: const Icon(Icons.refresh, size: 20),
              ),
              if (_items.isNotEmpty)
                Text(
                  _query.isEmpty
                      ? '${_items.length}${_hasMore ? '+' : ''} servicios'
                      : '${visible.length} de ${_items.length} cargados',
                  style: text.bodySmall?.copyWith(color: BrandColors.grey600),
                ),
            ],
          ),
        ),
        Expanded(child: _body(visible)),
      ],
    );
  }

  Widget _body(List<Service> visible) {
    if (_items.isEmpty) {
      if (_loading) return const BrandLoader(message: 'Cargando servicios…');
      final error = _error;
      if (error != null) {
        return EmptyState(
          title: 'No se pudo cargar',
          message: error.userMessage,
          icon: Icons.cloud_off_outlined,
          tone: EmptyStateTone.error,
          actionLabel: 'Reintentar',
          onAction: () => unawaited(_reload()),
        );
      }
      return EmptyState(
        title: 'Sin servicios',
        message: _filter == _StatusFilter.all && _period == _Period.all
            ? 'Todavía no se ha solicitado ningún servicio.'
            : 'Ningún servicio coincide con esos filtros.',
        icon: Icons.receipt_long_outlined,
      );
    }

    if (visible.isEmpty) {
      return EmptyState(
        title: 'Sin resultados',
        message: _hasMore
            ? 'Ningún servicio cargado coincide. Carga más, o busca por el '
                'código completo y presiona Enter.'
            : 'Ningún servicio coincide con esa búsqueda.',
        icon: Icons.search_off,
        actionLabel: _hasMore ? 'Cargar más' : null,
        onAction: _hasMore ? () => unawaited(_loadMore()) : null,
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(Insets.xl, 0, Insets.xl, Insets.xl),
      children: [
        _ServicesTable(
          services: visible,
          onOpen: (s) => unawaited(showServiceDetailDialog(context, s)),
        ),
        if (_error != null) ...[
          const SizedBox(height: Insets.md),
          InlineNotice(
            message: _error!.userMessage,
            tone: NoticeTone.error,
            actionLabel: 'Reintentar',
            onAction: () => unawaited(_loadMore()),
          ),
        ],
        if (_hasMore) ...[
          const SizedBox(height: Insets.lg),
          Center(
            child: OutlinedButton(
              onPressed: _loading ? null : () => unawaited(_loadMore()),
              child: _loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Cargar más'),
            ),
          ),
        ],
      ],
    );
  }
}

class _Dropdown<T> extends StatelessWidget {
  const _Dropdown({
    required this.value,
    required this.values,
    required this.label,
    required this.onChanged,
  });

  final T value;
  final List<T> values;
  final String Function(T) label;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonHideUnderline(
      child: DropdownButton<T>(
        value: value,
        onChanged: (v) {
          if (v != null && v != value) onChanged(v);
        },
        items: [
          for (final v in values)
            DropdownMenuItem(value: v, child: Text(label(v))),
        ],
      ),
    );
  }
}

class _ServicesTable extends StatelessWidget {
  const _ServicesTable({required this.services, required this.onOpen});

  final List<Service> services;
  final ValueChanged<Service> onOpen;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: BrandColors.grey600);

    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: constraints.maxWidth),
          child: DataTable(
            showCheckboxColumn: false,
            dataRowMinHeight: 56,
            dataRowMaxHeight: 60,
            columnSpacing: 28,
            headingRowColor: const WidgetStatePropertyAll(BrandColors.offWhite),
            headingTextStyle: text.labelSmall,
            dividerThickness: 1,
            columns: const [
              DataColumn(label: Text('CÓDIGO')),
              DataColumn(label: Text('FECHA')),
              DataColumn(label: Text('CLIENTE')),
              DataColumn(label: Text('CHOFER')),
              DataColumn(label: Text('ESTADO')),
              DataColumn(label: Text('PAGO')),
              DataColumn(label: Text('TOTAL'), numeric: true),
            ],
            rows: [
              for (final s in services)
                DataRow(
                  onSelectChanged: (_) => onOpen(s),
                  cells: [
                    DataCell(Text(s.code.isEmpty ? '—' : s.code, style: text.titleSmall)),
                    DataCell(
                      Text(
                        s.createdAt == null ? '—' : DoTime.dateAndTime(s.createdAt!),
                      ),
                    ),
                    DataCell(
                      _TwoLines(
                        top: s.clientName.isEmpty ? '—' : s.clientName,
                        bottom: s.clientPhone,
                        style: muted,
                      ),
                    ),
                    DataCell(
                      s.hasDriver
                          ? _TwoLines(
                              top: s.driverName,
                              bottom: s.truckPlate,
                              style: muted,
                            )
                          : Text('Sin asignar', style: muted),
                    ),
                    DataCell(StatusChip(s.status, label: s.status.officeLabel, compact: true)),
                    DataCell(
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            s.payment.isCash
                                ? Icons.payments_outlined
                                : Icons.credit_card,
                            size: 16,
                            color: BrandColors.grey600,
                          ),
                          const SizedBox(width: Insets.xs),
                          Text(s.payment.method.label),
                        ],
                      ),
                    ),
                    DataCell(Text(s.totalCents.formatDOP, style: text.titleSmall)),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TwoLines extends StatelessWidget {
  const _TwoLines({required this.top, required this.bottom, this.style});

  final String top;
  final String bottom;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(top, maxLines: 1, overflow: TextOverflow.ellipsis),
        if (bottom.isNotEmpty)
          Text(bottom, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
      ],
    );
  }
}
