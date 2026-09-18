import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';
import '../shared/page_parts.dart';
import 'portal_shell.dart';

/// The company's front page: this month in five numbers, and what is on the
/// road right now.
class PortalDashboardScreen extends ConsumerWidget {
  const PortalDashboardScreen({super.key});

  /// Rows in a [ListCard] run edge to edge, so they pad themselves.
  static const _rowPadding = EdgeInsets.symmetric(
    horizontal: Insets.lg,
    vertical: Insets.md,
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
    final stats = ref.watch(myInsurerStatsProvider);
    final services = ref.watch(myInsurerServicesProvider);
    final active = [
      for (final s in services.value ?? const <Service>[])
        if (s.isActive) s,
    ];
    final recent = (services.value ?? const <Service>[]).take(8).toList();
    final month = stats.value?.monthStart;

    return ListView(
      padding: const EdgeInsets.all(Insets.xl),
      children: [
        PortalHeader(
          title: 'Inicio',
          subtitle: month == null
              ? 'Tus servicios de este mes.'
              : 'Tus servicios desde el ${DoTime.fullDate(month)}. Los montos '
                    'son lo que va sumando tu factura del mes.',
          action: ElevatedButton.icon(
            key: const Key('portal-new-service'),
            onPressed: () => context.go(Routes.portalNew),
            style: ElevatedButton.styleFrom(minimumSize: const Size(0, 44)),
            icon: const Icon(Icons.add),
            label: const Text('Nuevo servicio'),
          ),
        ),
        const SizedBox(height: Insets.xl),
        switch (stats) {
          // One line of equal tiles, each with a note under its figure, so
          // they stand the same height and end where the cards below do.
          AsyncValue(:final value?) => StatRow(
            children: [
              PortalKpi(
                key: const Key('kpi-month-services'),
                width: null,
                label: 'Servicios del mes',
                value: '${value.requested}',
                icon: Icons.local_shipping_outlined,
                detail:
                    '${_count(value.completed, 'completado', 'completados')}'
                    ' · '
                    '${_count(value.cancelled, 'cancelado', 'cancelados')}',
              ),
              PortalKpi(
                key: const Key('kpi-month-cost'),
                width: null,
                label: 'Costo del mes',
                value: value.cost.totalCents.formatDOP,
                icon: Icons.receipt_long_outlined,
                detail:
                    '${value.cost.subtotalCents.formatDOP} + ITBIS '
                    '${value.cost.itbisCents.formatDOP}',
              ),
              PortalKpi(
                key: const Key('kpi-average-arrival'),
                width: null,
                label: 'Llegada promedio',
                value: InsurerStats.minutes(value.averageArrival),
                icon: Icons.timer_outlined,
                detail: 'Del pedido a la llegada',
              ),
              PortalKpi(
                key: const Key('kpi-average-total'),
                width: null,
                label: 'Duración promedio',
                value: InsurerStats.minutes(value.averageTotal),
                icon: Icons.schedule,
                detail: 'Del pedido a la entrega',
              ),
              PortalKpi(
                key: const Key('kpi-active'),
                width: null,
                label: 'En curso ahora',
                value: '${value.active}',
                icon: Icons.near_me_outlined,
                detail: value.active == 0
                    ? 'Ninguna grúa en camino'
                    : 'En camino o trabajando',
                color: value.active > 0 ? palette.info : null,
              ),
            ],
          ),
          AsyncValue(:final error?) => InlineNotice(
            tone: NoticeTone.error,
            icon: Icons.error_outline,
            message: _problem(error),
          ),
          _ => const Padding(
            padding: EdgeInsets.all(Insets.xl),
            child: BrandLoader(),
          ),
        },
        const SizedBox(height: Insets.xl),
        ListCard(
          title: 'En curso',
          trailing: active.isEmpty
              ? null
              : TextButton.icon(
                  onPressed: () => context.go(Routes.portalMap),
                  style: _headerButton,
                  icon: const Icon(Icons.map_outlined, size: 18),
                  label: const Text('Ver en el mapa'),
                ),
          children: [
            if (active.isEmpty)
              _QuietLine(
                icon: Icons.check_circle_outline,
                text: 'No tienes grúas en camino ahora mismo.',
                color: palette.textMuted,
              )
            else
              for (final s in active)
                PortalServiceTile(
                  service: s,
                  padding: _rowPadding,
                  onTap: () => context.go(Routes.portalServiceFor(s.id)),
                ),
          ],
        ),
        const SizedBox(height: Insets.xl),
        ListCard(
          title: 'Últimos servicios',
          trailing: recent.isEmpty
              ? null
              : TextButton(
                  onPressed: () => context.go(Routes.portalServices),
                  style: _headerButton,
                  child: const Text('Ver todos'),
                ),
          children: [
            switch (services) {
              AsyncValue(:final error?) when !services.hasValue => _QuietLine(
                icon: Icons.error_outline,
                text: _problem(error),
                color: palette.danger,
              ),
              _ when recent.isEmpty && services.isLoading => const Padding(
                padding: EdgeInsets.all(Insets.xl),
                child: BrandLoader(),
              ),
              _ when recent.isEmpty => EmptyState(
                icon: Icons.local_shipping_outlined,
                title: 'Sin servicios todavía',
                message: 'Todavía no has pedido ningún servicio.',
                actionLabel: 'Pedir una grúa',
                onAction: () => context.go(Routes.portalNew),
              ),
              _ => Column(
                children: [
                  for (final (index, s) in recent.indexed) ...[
                    if (index > 0) const Divider(height: 1),
                    PortalServiceTile(
                      service: s,
                      padding: _rowPadding,
                      onTap: () => context.go(Routes.portalServiceFor(s.id)),
                    ),
                  ],
                ],
              ),
            },
          ],
        ),
      ],
    );
  }
}

/// A one-line state inside a card: nothing on the road, or a load that failed.
class _QuietLine extends StatelessWidget {
  const _QuietLine({
    required this.icon,
    required this.text,
    required this.color,
  });

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(Insets.lg),
    child: Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: Insets.sm),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: color),
          ),
        ),
      ],
    ),
  );
}

/// "1 completado", "3 completados".
String _count(int n, String one, String many) => '$n ${n == 1 ? one : many}';

/// A link-sized button for a card's title row. The theme's full-size tap
/// padding made a header with one taller than a header without.
final ButtonStyle _headerButton = TextButton.styleFrom(
  minimumSize: Size.zero,
  padding: const EdgeInsets.symmetric(horizontal: Insets.sm, vertical: 2),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

String _problem(Object error) => error is Failure
    ? error.userMessage
    : 'No pudimos cargar tus servicios. Recarga la página.';
