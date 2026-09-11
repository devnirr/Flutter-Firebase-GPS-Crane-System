import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

import 'truck_form_dialog.dart';

/// The fleet.
///
/// Expiring paperwork is the point of this screen. A grúa on the road with a
/// lapsed seguro or marbete is a liability, so the soonest of the two expiries
/// gets its own column and a badge, and the list sorts the urgent ones up.
class TrucksScreen extends ConsumerWidget {
  const TrucksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fleet = ref.watch(allTrucksProvider);
    final text = Theme.of(context).textTheme;
    final now = DateTime.now().toUtc();

    // A deleted grúa is archived, not erased; the fleet is for the living.
    final ordered = [...?fleet.value?.where((t) => !t.archived)]
      ..sort((a, b) {
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
                onPressed: () => unawaited(showCreateTruckDialog(context)),
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
        Expanded(child: _body(context, ref, fleet, ordered, now)),
      ],
    );
  }

  Widget _body(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<List<Truck>> fleet,
    List<Truck> ordered,
    DateTime now,
  ) {
    // Loading and error only take over before the first fleet arrives: once it
    // has, a dropped stream should not blank the grid out from under anyone.
    if (!fleet.hasValue) {
      if (fleet.hasError) {
        final error = fleet.error;
        return EmptyState(
          title: 'No se pudo cargar',
          message: error is Failure
              ? error.userMessage
              : 'La flota no está disponible ahora mismo.',
          icon: Icons.cloud_off_outlined,
          tone: EmptyStateTone.error,
          actionLabel: 'Reintentar',
          onAction: () => ref.invalidate(allTrucksProvider),
        );
      }
      return const BrandLoader(message: 'Cargando grúas…');
    }

    if (ordered.isEmpty) {
      return EmptyState(
        title: 'Todavía no hay grúas',
        message: 'Agrega la primera con "Nueva grúa". Después la asignas a un '
            'chofer desde su formulario.',
        icon: Icons.local_shipping_outlined,
        actionLabel: 'Nueva grúa',
        onAction: () => unawaited(showCreateTruckDialog(context)),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(Insets.xl, 0, Insets.xl, Insets.xl),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 380,
        // Header, two detail rows and the paperwork badge, with room to spare:
        // 208 clipped the badge by 20 px.
        mainAxisExtent: 236,
        crossAxisSpacing: Insets.lg,
        mainAxisSpacing: Insets.lg,
      ),
      itemCount: ordered.length,
      itemBuilder: (context, index) {
        final truck = ordered[index];
        return _TruckCard(
          truck: truck,
          now: now,
          onEdit: () => unawaited(showEditTruckDialog(context, truck)),
          onDelete: () => unawaited(_deleteTruck(context, ref, truck)),
        );
      },
    );
  }

  /// Archives rather than erases: services name the grúa. Its plate is freed
  /// and the chofer on it is left without one.
  Future<void> _deleteTruck(
    BuildContext context,
    WidgetRef ref,
    Truck truck,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('¿Eliminar la grúa ${truck.displayPlate}?'),
        content: Text(
          truck.isAssigned
              ? 'Sale de la flota y ${truck.assignedDriverName} queda sin grúa '
                  'y fuera de línea hasta que le asignes otra. Sus servicios '
                  'se conservan.'
              : 'Sale de la flota. Sus servicios se conservan.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: BrandColors.danger),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final result =
        await ref.read(functionsGatewayProvider).archiveTruck(truck.id);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          result.isErr
              ? result.failureOrNull?.userMessage ??
                  'No se pudo eliminar la grúa.'
              : 'Grúa ${truck.displayPlate} eliminada.',
        ),
      ),
    );
  }
}

class _TruckCard extends StatelessWidget {
  const _TruckCard({
    required this.truck,
    required this.now,
    required this.onEdit,
    required this.onDelete,
  });

  final Truck truck;
  final DateTime now;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final days = truck.daysUntilNextExpiry(now);
    final expired = truck.hasExpiredPaperwork(now);
    final soon = truck.hasExpiringPaperwork(now);

    return FloatingCard(
      onTap: onEdit,
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
              IconButton(
                tooltip: 'Editar',
                visualDensity: VisualDensity.compact,
                onPressed: onEdit,
                icon: const Icon(Icons.edit_outlined, size: 20),
              ),
              IconButton(
                tooltip: 'Eliminar',
                visualDensity: VisualDensity.compact,
                onPressed: onDelete,
                icon: const Icon(
                  Icons.delete_outline,
                  size: 20,
                  color: BrandColors.danger,
                ),
              ),
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
