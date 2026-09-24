import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

import '../shared/page_parts.dart';
import '../shared/toast.dart';

/// Operational reporting.
///
/// In production every figure here comes from `reports/daily/{date}`, written
/// by a scheduled rollup — never from a query over `services`. A dashboard that
/// scans the raw collection is how a Firestore bill goes from tens of dollars
/// to thousands, and it gets slower every month the business succeeds.
///
/// Until the rollups exist, this computes the same shapes from the in-memory
/// backend so the layout and the definitions are settled first.
class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

enum _Range {
  today('Hoy', 1),
  week('Últimos 7 días', 7),
  month('Últimos 30 días', 30);

  const _Range(this.label, this.days);

  final String label;
  final int days;
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  _Range _range = _Range.week;

  @override
  Widget build(BuildContext context) {
    final services = ref.watch(demoBackendProvider).allServices;
    final drivers = ref.watch(allDriversProvider).value ?? const [];
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final now = DateTime.now().toUtc();

    final from = DoTime.startOfLocalDay(
      now.subtract(Duration(days: _range.days - 1)),
    );
    final inRange = services
        .where((s) => (s.createdAt ?? now).isAfter(from))
        .toList();

    final completed = inRange
        .where(
          (s) =>
              s.status == ServiceStatus.completed ||
              s.status == ServiceStatus.closed,
        )
        .toList();
    final cancelled = inRange
        .where((s) => s.status == ServiceStatus.cancelled)
        .length;

    final gross = completed.fold(0, (sum, s) => sum + s.totalCents);
    final ticket = completed.isEmpty ? 0 : gross ~/ completed.length;
    final cancellationRate = inRange.isEmpty ? 0.0 : cancelled / inRange.length;

    final arrivalTimes = completed
        .map((s) => s.timeline.timeToArrive)
        .whereType<Duration>()
        .toList();
    final avgArrival = arrivalTimes.isEmpty
        ? Duration.zero
        : Duration(
            seconds:
                arrivalTimes.fold(0, (sum, d) => sum + d.inSeconds) ~/
                arrivalTimes.length,
          );

    // What the choferes have actually confirmed collecting, against what the
    // jobs came to: the gap is money still out on the road.
    final collectedCents = completed
        .where((s) => s.payment.isPaid)
        .fold(0, (sum, s) => sum + s.totalCents);

    String count(int n, String one, String many) => '$n ${n == 1 ? one : many}';

    return ListView(
      padding: const EdgeInsets.all(Insets.xl),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Reportes', style: text.headlineSmall),
                  const SizedBox(height: Insets.xs),
                  Text(
                    'Cómo va la operación en el periodo elegido.',
                    style: text.bodyMedium?.copyWith(color: palette.textMuted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: Insets.md),
            // On a 1024-px screen the export drops below the range picker
            // instead of running off it.
            // Pinned right, so the export button ends where the tiles below
            // end rather than wherever its half of the row did.
            Flexible(
              flex: 2,
              child: Align(
                alignment: Alignment.topRight,
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: Insets.md,
                  runSpacing: Insets.md,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SegmentedButton<_Range>(
                      segments: [
                        for (final range in _Range.values)
                          ButtonSegment(value: range, label: Text(range.label)),
                      ],
                      selected: {_range},
                      showSelectedIcon: false,
                      onSelectionChanged: (s) =>
                          setState(() => _range = s.first),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => showToast(
                        context,
                        'La exportación se genera en una Cloud Function y se '
                        'entrega como URL firmada.',
                        tone: ToastTone.info,
                      ),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 40),
                      ),
                      icon: const Icon(Icons.download_outlined, size: 18),
                      label: const Text('Exportar CSV'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: Insets.xl),
        // Every tile carries a line under its figure, so they are all built
        // the same way and stand the same height: a figure alone next to one
        // with a note read as two sizes of card.
        StatRow(
          children: [
            StatTile(
              icon: Icons.check_circle_outline,
              label: 'Servicios completados',
              value: '${completed.length}',
              detail: 'de ${count(inRange.length, 'solicitud', 'solicitudes')}',
              color: completed.isEmpty ? null : palette.success,
            ),
            StatTile(
              icon: Icons.payments_outlined,
              label: 'Ingresos brutos',
              value: gross.formatDOPCompact,
              detail: 'Total de lo completado',
              // Green, not the brand red: on a money figure red reads as a
              // loss.
              color: gross == 0 ? null : palette.success,
            ),
            StatTile(
              icon: Icons.receipt_long_outlined,
              label: 'Ticket promedio',
              value: ticket.formatDOPCompact,
              detail: 'Por servicio completado',
            ),
            StatTile(
              icon: Icons.cancel_outlined,
              label: 'Tasa de cancelación',
              value: '${(cancellationRate * 100).toStringAsFixed(0)}%',
              detail: count(cancelled, 'cancelada', 'canceladas'),
              color: cancellationRate > 0.15 ? palette.danger : null,
            ),
            StatTile(
              icon: Icons.timer_outlined,
              label: 'Llegada promedio',
              value: avgArrival == Duration.zero
                  ? '—'
                  : DoTime.duration(avgArrival),
              detail: 'De aceptar a llegar al vehículo',
            ),
            StatTile(
              icon: Icons.account_balance_wallet_outlined,
              label: 'Efectivo cobrado',
              value: gross == 0
                  ? '—'
                  : '${(collectedCents / gross * 100).toStringAsFixed(0)}%',
              detail: gross == 0
                  ? 'Sin servicios completados'
                  : '${collectedCents.formatDOPCompact} confirmado',
            ),
          ],
        ),
        const SizedBox(height: Insets.xl),
        _DriverLeaderboard(drivers: drivers),
      ],
    );
  }
}

/// The choferes ranked by what they took home this month.
///
/// This month rather than the range picked above: the figure comes from each
/// chofer's earnings summary, which is kept per month. The chip beside the
/// title says so, so nobody reads it as the last seven days.
class _DriverLeaderboard extends ConsumerWidget {
  const _DriverLeaderboard({required this.drivers});

  final List<Driver> drivers;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final backend = ref.watch(demoBackendProvider);
    final text = Theme.of(context).textTheme;
    final palette = context.palette;

    final rows =
        drivers
            .map((d) => (driver: d, summary: backend.earnings(d.id)))
            .where((r) => r.summary != null && r.summary!.monthServices > 0)
            .toList()
          ..sort(
            (a, b) =>
                b.summary!.monthNetCents.compareTo(a.summary!.monthNetCents),
          );
    final top = rows.take(8).toList();
    final max = top.isEmpty ? 0 : top.first.summary!.monthNetCents;

    return ListCard(
      title: 'Choferes por ganancia neta',
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: Insets.sm, vertical: 2),
        decoration: BoxDecoration(
          color: palette.surfaceSubtle,
          borderRadius: Corners.brSm,
        ),
        child: Text(
          'Este mes',
          style: text.labelMedium?.copyWith(color: palette.textMuted),
        ),
      ),
      children: [
        if (top.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: Insets.lg),
            child: EmptyState(
              icon: Icons.leaderboard_outlined,
              title: 'Sin ganancias este mes',
              message:
                  'Cuando un chofer complete su primer servicio del mes, '
                  'aparece aquí.',
            ),
          )
        else
          for (final (index, row) in top.indexed)
            Padding(
              key: ValueKey(row.driver.id),
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.lg,
                vertical: Insets.md,
              ),
              child: Row(
                children: [
                  // The rank, so the order is read rather than inferred from
                  // bar lengths.
                  SizedBox(
                    width: 28,
                    child: Text(
                      '${index + 1}',
                      style: text.titleSmall?.copyWith(
                        color: index == 0 ? palette.brand : palette.textMuted,
                      ),
                    ),
                  ),
                  DriverAvatar.of(row.driver),
                  const SizedBox(width: Insets.md),
                  SizedBox(
                    width: 180,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          row.driver.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.titleSmall,
                        ),
                        Text(
                          row.summary!.monthServices == 1
                              ? '1 servicio'
                              : '${row.summary!.monthServices} servicios',
                          style: text.bodySmall?.copyWith(
                            color: palette.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: Insets.lg),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: Corners.brXs,
                      child: LinearProgressIndicator(
                        value: max == 0 ? 0 : row.summary!.monthNetCents / max,
                        minHeight: 8,
                        color: palette.brand,
                        backgroundColor: palette.surfaceSubtle,
                      ),
                    ),
                  ),
                  const SizedBox(width: Insets.lg),
                  SizedBox(
                    width: 130,
                    child: Text(
                      row.summary!.monthNetCents.formatDOP,
                      textAlign: TextAlign.end,
                      style: text.titleSmall,
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }
}
