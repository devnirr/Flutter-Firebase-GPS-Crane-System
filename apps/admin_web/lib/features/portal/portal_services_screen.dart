import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';
import '../shared/page_parts.dart';
import '../shared/toast.dart';
import 'portal_shell.dart';

enum _Filter {
  all('Todos'),
  active('En curso'),
  done('Completados'),
  cancelled('Cancelados');

  const _Filter(this.label);
  final String label;

  bool matches(Service s) => switch (this) {
    _Filter.all => true,
    _Filter.active => s.isActive,
    _Filter.done =>
      s.status == ServiceStatus.completed || s.status == ServiceStatus.closed,
    _Filter.cancelled =>
      s.status == ServiceStatus.cancelled ||
          s.status == ServiceStatus.expired ||
          s.status == ServiceStatus.failed,
  };
}

/// Every tow the company ordered, newest first, searchable by what the
/// company knows it by: claim, policy, plate, insured, or our code.
class PortalServicesScreen extends ConsumerStatefulWidget {
  const PortalServicesScreen({super.key});

  @override
  ConsumerState<PortalServicesScreen> createState() =>
      _PortalServicesScreenState();
}

class _PortalServicesScreenState extends ConsumerState<PortalServicesScreen> {
  _Filter _filter = _Filter.all;
  var _query = '';

  /// Tows found for a claim beyond the latest ones loaded, and the claim they
  /// were found for.
  List<Service>? _found;
  String _foundFor = '';
  var _searching = false;

  /// A claim number as the server compares it: `sin 2024-01` is `SIN202401`.
  static String _claimKey(String value) =>
      value.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');

  Future<void> _searchHistory() async {
    final insurerId = ref.read(currentInsurerIdProvider).value;
    final key = _claimKey(_query);
    if (insurerId == null || key.isEmpty) return;
    setState(() => _searching = true);
    final result = await ref
        .read(serviceRepositoryProvider)
        .findInsurerServicesByClaim(insurerId, key);
    if (!mounted) return;
    setState(() {
      _searching = false;
      _found = result.valueOrNull ?? const [];
      _foundFor = key;
    });
    if (result case Err(:final failure)) {
      showToast(context, failure.userMessage, tone: ToastTone.error);
    }
  }

  static String _fold(String s) =>
      s.toUpperCase().replaceAll(RegExp('[^A-Z0-9ÁÉÍÓÚÑÜ]'), '');

  bool _matchesQuery(Service s) {
    final q = _fold(_query);
    if (q.isEmpty) return true;
    final claim = s.insurance;
    return [
      s.code,
      s.vehicle.plate,
      claim?.claimNumber ?? '',
      claim?.policyNumber ?? '',
      claim?.insuredName ?? '',
      claim?.insuredPhone ?? '',
    ].any((field) => _fold(field).contains(q));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final services = ref.watch(myInsurerServicesProvider);
    final all = services.value ?? const <Service>[];
    final key = _claimKey(_query);
    final found = _foundFor == key && key.isNotEmpty ? _found : null;
    final shown = [
      for (final s in all)
        if (_filter.matches(s) && _matchesQuery(s)) s,
      // Older tows found for this claim, not already in the list.
      if (found != null)
        for (final s in found)
          if (_filter.matches(s) && !all.any((a) => a.id == s.id)) s,
    ];
    final billed = shown.fold<int>(
      0,
      (sum, s) => sum + (portalPriceOf(s) ?? 0),
    );

    return ListView(
      padding: const EdgeInsets.all(Insets.xl),
      children: [
        const PortalHeader(
          title: 'Servicios',
          subtitle:
              'Historial de las grúas que ha pedido tu aseguradora. Los '
              'montos son antes de ITBIS; la factura del mes lo suma al final.',
        ),
        const SizedBox(height: Insets.xl),
        // What to show on the left, what it adds up to on the right.
        LayoutBuilder(
          builder: (context, constraints) => Row(
            children: [
              // A share of the row, up to 360 px. A bare Flexible gave up what
              // it did not use, and the total box then stopped short of the
              // right edge; a width worked out here takes only what it needs.
              SizedBox(
                width: (constraints.maxWidth * 0.3).clamp(200.0, 360.0),
                child: TextField(
                  key: const Key('portal-services-search'),
                  onChanged: (v) => setState(() => _query = v),
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: Insets.md,
                      vertical: Insets.sm + 2,
                    ),
                    hintText: 'Siniestro, póliza, placa, asegurado o código',
                    prefixIcon: Icon(Icons.search, size: 18),
                  ),
                ),
              ),
              const SizedBox(width: Insets.lg),
              Expanded(
                child: Wrap(
                  spacing: Insets.sm,
                  runSpacing: Insets.sm,
                  children: [
                    for (final f in _Filter.values)
                      ChoiceChip(
                        key: Key('portal-filter-${f.name}'),
                        label: Text(f.label),
                        selected: _filter == f,
                        onSelected: (_) => setState(() => _filter = f),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: Insets.lg),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: Insets.lg,
                  vertical: Insets.sm,
                ),
                decoration: BoxDecoration(
                  color: palette.surface,
                  borderRadius: Corners.brMd,
                  border: Border.all(color: palette.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      billed.formatDOP,
                      key: const Key('portal-services-total'),
                      style: text.titleMedium,
                    ),
                    Text(
                      '${shown.length == 1 ? '1 servicio' : '${shown.length} servicios'}'
                      ' · antes de ITBIS',
                      style: text.bodySmall?.copyWith(color: palette.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Insets.lg),
        switch (services) {
          AsyncValue(:final error?) when !services.hasValue => FloatingCard(
            child: EmptyState(
              icon: Icons.error_outline,
              tone: EmptyStateTone.error,
              title: 'No pudimos cargar tus servicios',
              message: error is Failure
                  ? error.userMessage
                  : 'Recarga la página para intentarlo de nuevo.',
            ),
          ),
          _ when shown.isEmpty && services.isLoading => const FloatingCard(
            child: Padding(
              padding: EdgeInsets.all(Insets.xl),
              child: BrandLoader(),
            ),
          ),
          _ when shown.isEmpty => FloatingCard(
            child: Column(
              children: [
                EmptyState(
                  key: const Key('portal-services-empty'),
                  icon: found != null || key.isNotEmpty
                      ? Icons.search_off
                      : Icons.local_shipping_outlined,
                  title: found != null || key.isNotEmpty
                      ? 'Sin resultados'
                      : 'Sin servicios todavía',
                  message: found != null
                      ? 'Ningún servicio con ese número de siniestro.'
                      : all.isEmpty && key.isEmpty
                      ? 'Todavía no has pedido ningún servicio.'
                      : 'Ningún servicio reciente coincide con la búsqueda.',
                ),
                // The list holds the latest tows; a claim can be older.
                if (key.isNotEmpty && found == null) ...[
                  OutlinedButton.icon(
                    key: const Key('portal-search-history'),
                    onPressed: _searching ? null : _searchHistory,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 44),
                    ),
                    icon: const Icon(Icons.manage_search),
                    label: const Text(
                      'Buscar el siniestro en todo el historial',
                    ),
                  ),
                  const SizedBox(height: Insets.xl),
                ],
              ],
            ),
          ),
          _ => ListCard(
            children: [
              for (final s in shown)
                PortalServiceTile(
                  service: s,
                  padding: const EdgeInsets.symmetric(
                    horizontal: Insets.lg,
                    vertical: Insets.md,
                  ),
                  onTap: () => context.go(Routes.portalServiceFor(s.id)),
                ),
            ],
          ),
        },
        if (all.length >= 200) ...[
          const SizedBox(height: Insets.md),
          Text(
            'Se muestran los 200 servicios más recientes.',
            style: text.bodySmall?.copyWith(color: palette.textMuted),
          ),
        ],
      ],
    );
  }
}
