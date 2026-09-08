import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

/// The fleet.
///
/// Expiring paperwork is the point of this screen. A grúa on the road with a
/// lapsed seguro or marbete is a liability, so the soonest of the two expiries
/// gets its own column and a badge, and the list sorts the urgent ones up.
class TrucksScreen extends ConsumerWidget {
  const TrucksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trucks = ref.watch(allTrucksProvider).value ?? const [];
    final text = Theme.of(context).textTheme;
    final now = DateTime.now().toUtc();

    final ordered = [...trucks]..sort((a, b) {
        final da = a.daysUntilNextExpiry(now) ?? 1 << 20;
        final db = b.daysUntilNextExpiry(now) ?? 1 << 20;
        return da.compareTo(db);
      });

    final expiringSoon =
        ordered.where((t) => t.hasExpiringPaperwork(now)).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(Insets.xl),
          child: Row(
            children: [
              Text('Grúas', style: text.headlineSmall),
              const SizedBox(width: Insets.lg),
              Text(
                '${ordered.length} en la flota',
                style: text.bodyMedium?.copyWith(color: BrandColors.grey600),
              ),
              const Spacer(),
              ElevatedButton.icon(
                onPressed: () {},
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(0, 40),
                  padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
                ),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Nueva grúa'),
              ),
            ],
          ),
        ),
        if (expiringSoon > 0)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Insets.xl),
            child: InlineNotice(
              message: '$expiringSoon grúa(s) con seguro o marbete por vencer '
                  'en los próximos 30 días.',
            ),
          ),
        const SizedBox(height: Insets.lg),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.symmetric(horizontal: Insets.xl),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 380,
              mainAxisExtent: 208,
              crossAxisSpacing: Insets.lg,
              mainAxisSpacing: Insets.lg,
            ),
            itemCount: ordered.length,
            itemBuilder: (context, index) =>
                _TruckCard(truck: ordered[index], now: now),
          ),
        ),
      ],
    );
  }
}

class _TruckCard extends StatelessWidget {
  const _TruckCard({required this.truck, required this.now});

  final Truck truck;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final days = truck.daysUntilNextExpiry(now);
    final expired = truck.hasExpiredPaperwork(now);
    final soon = truck.hasExpiringPaperwork(now);

    return FloatingCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: const BoxDecoration(
                  color: BrandColors.redTint,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.local_shipping,
                  size: 20,
                  color: BrandColors.red,
                ),
              ),
              const SizedBox(width: Insets.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(truck.displayPlate, style: text.titleMedium),
                    Text(
                      truck.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall
                          ?.copyWith(color: BrandColors.grey600),
                    ),
                  ],
                ),
              ),
              if (!truck.active)
                const Icon(Icons.pause_circle_outline,
                    size: 18, color: BrandColors.grey400),
            ],
          ),
          const Divider(height: Insets.xl),
          DetailRow(
            label: 'Capacidad',
            value: '${truck.capacityTons.toStringAsFixed(1)} t',
          ),
          DetailRow(
            label: 'Chofer',
            value: truck.isAssigned ? truck.assignedDriverName : 'Sin asignar',
          ),
          const Spacer(),
          if (days != null)
            InlineNotice(
              icon: Icons.event_outlined,
              tone: expired
                  ? NoticeTone.error
                  : soon
                      ? NoticeTone.warning
                      : NoticeTone.success,
              message: expired
                  ? 'Documentos vencidos hace ${-days} días'
                  : soon
                      ? 'Vence en $days días'
                      : 'Documentos al día',
            ),
        ],
      ),
    );
  }
}
