import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';
import 'portal_shell.dart';

/// The company's front page: this month in four numbers, and what is on the
/// road right now.
class PortalDashboardScreen extends ConsumerWidget {
  const PortalDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
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
          AsyncValue(:final value?) => Wrap(
              spacing: Insets.lg,
              runSpacing: Insets.lg,
              children: [
                PortalKpi(
                  key: const Key('kpi-month-services'),
                  label: 'Servicios del mes',
                  value: '${value.requested}',
                  icon: Icons.local_shipping_outlined,
                  detail: '${value.completed} completados · '
                      '${value.cancelled} cancelados',
                ),
                PortalKpi(
                  key: const Key('kpi-month-cost'),
                  label: 'Costo del mes',
                  value: value.cost.totalCents.formatDOP,
                  icon: Icons.receipt_long_outlined,
                  detail: '${value.cost.subtotalCents.formatDOP} + ITBIS '
                      '${value.cost.itbisCents.formatDOP}',
                ),
                PortalKpi(
                  key: const Key('kpi-average-arrival'),
                  label: 'Tiempo promedio de llegada',
                  value: InsurerStats.minutes(value.averageArrival),
                  icon: Icons.timer_outlined,
                  detail: 'Desde el pedido hasta que la grúa llega',
                ),
                PortalKpi(
                  key: const Key('kpi-average-total'),
                  label: 'Tiempo promedio total',
                  value: InsurerStats.minutes(value.averageTotal),
                  icon: Icons.schedule,
                  detail: 'Desde el pedido hasta la entrega',
                ),
                PortalKpi(
                  key: const Key('kpi-active'),
                  label: 'En curso ahora',
                  value: '${value.active}',
                  icon: Icons.near_me_outlined,
                  color: value.active > 0 ? palette.info : null,
                ),
              ],
            ),
          AsyncValue(:final error?) => InlineNotice(
              tone: NoticeTone.error,
              message: _problem(error),
            ),
          _ => const Padding(
              padding: EdgeInsets.all(Insets.xl),
              child: Center(child: CircularProgressIndicator()),
            ),
        },
        const SizedBox(height: Insets.xl),
        Row(
          children: [
            Expanded(child: Text('En curso', style: text.titleMedium)),
            if (active.isNotEmpty)
              TextButton.icon(
                onPressed: () => context.go(Routes.portalMap),
                icon: const Icon(Icons.map_outlined, size: 18),
                label: const Text('Ver en el mapa'),
              ),
          ],
        ),
        const SizedBox(height: Insets.sm),
        FloatingCard(
          child: active.isEmpty
              ? Text(
                  'No tienes grúas en camino ahora mismo.',
                  style: text.bodyMedium?.copyWith(color: palette.textMuted),
                )
              : Column(
                  children: [
                    for (final s in active)
                      PortalServiceTile(
                        service: s,
                        onTap: () => context.go(Routes.portalServiceFor(s.id)),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: Insets.xl),
        Row(
          children: [
            Expanded(child: Text('Últimos servicios', style: text.titleMedium)),
            TextButton(
              onPressed: () => context.go(Routes.portalServices),
              child: const Text('Ver todos'),
            ),
          ],
        ),
        const SizedBox(height: Insets.sm),
        FloatingCard(
          child: switch (services) {
            AsyncValue(:final error?) when !services.hasValue => Text(
                _problem(error),
                style: text.bodyMedium?.copyWith(color: palette.danger),
              ),
            _ when recent.isEmpty => Text(
                services.isLoading
                    ? 'Cargando…'
                    : 'Todavía no has pedido ningún servicio.',
                style: text.bodyMedium?.copyWith(color: palette.textMuted),
              ),
            _ => Column(
                children: [
                  for (final s in recent)
                    PortalServiceTile(
                      service: s,
                      onTap: () => context.go(Routes.portalServiceFor(s.id)),
                    ),
                ],
              ),
          },
        ),
      ],
    );
  }
}

String _problem(Object error) => error is Failure
    ? error.userMessage
    : 'No pudimos cargar tus servicios. Recarga la página.';
