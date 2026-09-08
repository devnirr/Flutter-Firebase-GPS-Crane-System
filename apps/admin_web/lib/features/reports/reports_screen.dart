import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

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
    final now = DateTime.now().toUtc();

    final from = DoTime.startOfLocalDay(
      now.subtract(Duration(days: _range.days - 1)),
    );
    final inRange = services
        .where((s) => (s.createdAt ?? now).isAfter(from))
        .toList();

    final completed = inRange
        .where((s) =>
            s.status == ServiceStatus.completed ||
            s.status == ServiceStatus.closed)
        .toList();
    final cancelled =
        inRange.where((s) => s.status == ServiceStatus.cancelled).length;

    final gross = completed.fold(0, (sum, s) => sum + s.totalCents);
    final ticket = completed.isEmpty ? 0 : gross ~/ completed.length;
    final cancellationRate =
        inRange.isEmpty ? 0.0 : cancelled / inRange.length;

    final arrivalTimes = completed
        .map((s) => s.timeline.timeToArrive)
        .whereType<Duration>()
        .toList();
    final avgArrival = arrivalTimes.isEmpty
        ? Duration.zero
        : Duration(
            seconds: arrivalTimes.fold(0, (sum, d) => sum + d.inSeconds) ~/
                arrivalTimes.length,
          );

    final cardCents = completed
        .where((s) => s.payment.isCard)
        .fold(0, (sum, s) => sum + s.totalCents);

    return ListView(
      padding: const EdgeInsets.all(Insets.xl),
      children: [
        Row(
          children: [
            Text('Reportes', style: text.headlineSmall),
            const Spacer(),
            SegmentedButton<_Range>(
              segments: [
                for (final range in _Range.values)
                  ButtonSegment(value: range, label: Text(range.label)),
              ],
              selected: {_range},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _range = s.first),
            ),
            const SizedBox(width: Insets.md),
            OutlinedButton.icon(
              onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'La exportación se genera en una Cloud Function y se '
                    'entrega como URL firmada.',
                  ),
                ),
              ),
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40)),
              icon: const Icon(Icons.download_outlined, size: 18),
              label: const Text('Exportar CSV'),
            ),
          ],
        ),
        const SizedBox(height: Insets.xl),

        Wrap(
          spacing: Insets.lg,
          runSpacing: Insets.lg,
          children: [
            _Kpi(
              label: 'Servicios completados',
              value: '${completed.length}',
              icon: Icons.check_circle_outline,
            ),
            _Kpi(
              label: 'Ingresos brutos',
              value: gross.formatDOPCompact,
              icon: Icons.payments_outlined,
              accent: true,
            ),
            _Kpi(
              label: 'Ticket promedio',
              value: ticket.formatDOPCompact,
              icon: Icons.receipt_long_outlined,
            ),
            _Kpi(
              label: 'Tasa de cancelación',
              value: '${(cancellationRate * 100).toStringAsFixed(0)}%',
              icon: Icons.cancel_outlined,
              warn: cancellationRate > 0.15,
            ),
            _Kpi(
              label: 'Tiempo promedio de llegada',
              value: avgArrival == Duration.zero
                  ? '—'
                  : DoTime.duration(avgArrival),
              icon: Icons.timer_outlined,
            ),
            _Kpi(
              label: 'Cobrado con tarjeta',
              value: gross == 0
                  ? '—'
                  : '${(cardCents / gross * 100).toStringAsFixed(0)}%',
              icon: Icons.credit_card,
            ),
          ],
        ),
        const SizedBox(height: Insets.xl),

        FloatingCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Choferes por ganancia neta', style: text.titleMedium),
              const SizedBox(height: Insets.md),
              _DriverLeaderboard(drivers: drivers, ref: ref),
            ],
          ),
        ),
      ],
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi({
    required this.label,
    required this.value,
    required this.icon,
    this.accent = false,
    this.warn = false,
  });

  final String label;
  final String value;
  final IconData icon;
  final bool accent;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final color = warn
        ? BrandColors.danger
        : accent
            ? BrandColors.red
            : BrandColors.ink;

    return SizedBox(
      width: 236,
      child: FloatingCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 16, color: BrandColors.grey400),
                const SizedBox(width: Insets.sm),
                Expanded(child: FieldLabel(label)),
              ],
            ),
            const SizedBox(height: Insets.sm),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.headlineMedium?.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

class _DriverLeaderboard extends StatelessWidget {
  const _DriverLeaderboard({required this.drivers, required this.ref});

  final List<Driver> drivers;
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    final backend = ref.watch(demoBackendProvider);
    final text = Theme.of(context).textTheme;

    final rows = drivers
        .map((d) => (driver: d, summary: backend.earnings(d.id)))
        .where((r) => r.summary != null)
        .toList()
      ..sort((a, b) =>
          b.summary!.monthNetCents.compareTo(a.summary!.monthNetCents));

    if (rows.isEmpty) {
      return Text(
        'Sin datos en el rango seleccionado.',
        style: text.bodyMedium?.copyWith(color: BrandColors.grey600),
      );
    }

    final max = rows.first.summary!.monthNetCents;

    return Column(
      children: [
        for (final row in rows.take(8))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Insets.sm),
            child: Row(
              children: [
                SizedBox(
                  width: 160,
                  child: Text(row.driver.shortName, style: text.bodyMedium),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: Corners.brXs,
                    child: LinearProgressIndicator(
                      value: max == 0 ? 0 : row.summary!.monthNetCents / max,
                      minHeight: 8,
                      backgroundColor: BrandColors.grey100,
                    ),
                  ),
                ),
                const SizedBox(width: Insets.lg),
                SizedBox(
                  width: 110,
                  child: Text(
                    row.summary!.monthNetCents.formatDOP,
                    textAlign: TextAlign.end,
                    style: text.bodyMedium,
                  ),
                ),
                SizedBox(
                  width: 70,
                  child: Text(
                    '${row.summary!.monthServices} serv.',
                    textAlign: TextAlign.end,
                    style: text.bodySmall
                        ?.copyWith(color: BrandColors.grey600),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
