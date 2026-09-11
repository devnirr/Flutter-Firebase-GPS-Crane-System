import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

import 'create_driver_dialog.dart';
import 'driver_details_dialog.dart';
import 'driver_status_dialog.dart';

/// Fleet roster.
///
/// The columns are the ones the office actually acts on: whether the chofer can
/// work, whether they are online right now, how often they take offers, and how
/// much collected cash they are still holding. Acceptance rate and cash owed are
/// the two numbers that start conversations.
class DriversScreen extends ConsumerStatefulWidget {
  const DriversScreen({super.key});

  @override
  ConsumerState<DriversScreen> createState() => _DriversScreenState();
}

class _DriversScreenState extends ConsumerState<DriversScreen> {
  DriverStatus? _filter;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final roster = ref.watch(allDriversProvider);
    final text = Theme.of(context).textTheme;

    // A deleted chofer is archived, not erased; the roster is for the living.
    final drivers = (roster.value ?? const <Driver>[])
        .where((d) => !d.archived)
        .toList();

    final query = _query.trim().toLowerCase();
    final filtered = drivers.where((d) {
      if (_filter != null && d.status != _filter) return false;
      if (query.isEmpty) return true;
      return d.name.toLowerCase().contains(query) ||
          d.cedula.contains(query) ||
          d.assignedTruckPlate.toLowerCase().contains(query);
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(Insets.xl),
          child: Row(
            children: [
              Text('Choferes', style: text.headlineSmall),
              const SizedBox(width: Insets.xl),
              SizedBox(
                width: 260,
                height: 38,
                child: TextField(
                  onChanged: (value) => setState(() => _query = value),
                  decoration: const InputDecoration(
                    hintText: 'Nombre, cédula o placa',
                    prefixIcon: Icon(Icons.search, size: 18),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
              const SizedBox(width: Insets.md),
              _StatusFilter(
                value: _filter,
                onChanged: (value) => setState(() => _filter = value),
              ),
              const Spacer(),
              ElevatedButton.icon(
                onPressed: () => unawaited(_createDriver(context)),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(0, 40),
                  padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
                ),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Nuevo chofer'),
              ),
            ],
          ),
        ),
        Expanded(child: _body(roster, drivers, filtered)),
      ],
    );
  }

  Widget _body(
    AsyncValue<List<Driver>> roster,
    List<Driver> drivers,
    List<Driver> filtered,
  ) {
    // Loading and error only take over before the first roster arrives: once
    // it has, a dropped stream should not blank the table out from under
    // whoever is reading it.
    if (!roster.hasValue) {
      if (roster.hasError) {
        final error = roster.error;
        return EmptyState(
          title: 'No se pudo cargar',
          message: error is Failure
              ? error.userMessage
              : 'La lista de choferes no está disponible ahora mismo.',
          icon: Icons.cloud_off_outlined,
          tone: EmptyStateTone.error,
          actionLabel: 'Reintentar',
          onAction: () => ref.invalidate(allDriversProvider),
        );
      }
      return const BrandLoader(message: 'Cargando choferes…');
    }

    if (drivers.isEmpty) {
      return const EmptyState(
        title: 'Todavía no hay choferes',
        message: 'Crea el primero con "Nuevo chofer", o espera a que alguien '
            'se registre desde la app.',
        icon: Icons.badge_outlined,
      );
    }
    if (filtered.isEmpty) {
      return const EmptyState(
        title: 'Sin resultados',
        message: 'Ningún chofer coincide con ese filtro.',
        icon: Icons.search_off,
      );
    }
    return _DriverTable(
      drivers: filtered,
      // Empty until `/presence` answers: everyone reads as disconnected for a
      // moment, which is better than the roster waiting on a second stream.
      appOpen: ref.watch(connectedDriverIdsProvider).value ?? const {},
      onView: (driver) => unawaited(_viewDriver(driver)),
      onEdit: (driver) => unawaited(_editDriver(driver)),
      onDelete: (driver) => unawaited(_deleteDriver(driver)),
      onChangeStatus: (driver, target) =>
          unawaited(_changeStatus(driver, target)),
    );
  }

  Future<void> _createDriver(BuildContext context) async {
    final driverId = await showCreateDriverDialog(context);
    if (driverId == null || !context.mounted) return;

    // The roster is a live query, so the new chofer is already in the table.
    // Clearing the filters is what makes that visible: a new account is
    // inactive, which the "Activos" filter would otherwise hide.
    setState(() {
      _filter = null;
      _query = '';
    });
  }

  Future<void> _viewDriver(Driver driver) => showDriverDetailsDialog(
        context,
        driver,
        onEdit: () => unawaited(_editDriver(driver)),
        onChangeStatus: (target) => unawaited(_changeStatus(driver, target)),
      );

  /// Activates, deactivates or suspends [driver] after the office confirms.
  ///
  /// The roster is live, so the new status pill appears without anything done
  /// here beyond reporting how it went.
  Future<void> _changeStatus(Driver driver, DriverStatus target) async {
    final messenger = ScaffoldMessenger.of(context);

    // The server refuses this too; saying so first saves typing a reason for
    // a change that cannot happen.
    if (!target.canWork && driver.isBusy) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Este chofer tiene un servicio en curso. Reasígnalo primero.',
          ),
        ),
      );
      return;
    }

    final reason = await showDriverStatusDialog(context, driver, target);
    if (reason == null || !mounted) return;

    final result = await ref.read(functionsGatewayProvider).setDriverStatus(
          driverId: driver.id,
          status: target,
          reason: reason,
        );
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          result.isErr
              ? result.failureOrNull?.userMessage ??
                  'No se pudo cambiar el estado del chofer.'
              : switch (target) {
                  DriverStatus.active => '${driver.name} ya puede trabajar.',
                  DriverStatus.suspended => '${driver.name} fue suspendido.',
                  _ => '${driver.name} quedó inactivo.',
                },
        ),
      ),
    );
  }

  // The roster is live, so a saved edit shows up without anything done here.
  Future<void> _editDriver(Driver driver) =>
      showEditDriverDialog(context, driver);

  /// Archives rather than erases: services, earnings and the audit trail all
  /// name this chofer. The account is disabled and the row leaves the roster.
  Future<void> _deleteDriver(Driver driver) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('¿Eliminar a ${driver.name}?'),
        content: const Text(
          'Sale de la lista de choferes y ya no puede entrar a la app. '
          'Sus servicios y ganancias se conservan.',
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
    if (confirmed != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final result =
        await ref.read(functionsGatewayProvider).archiveDriver(driver.id);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          result.isErr
              ? result.failureOrNull?.userMessage ??
                  'No se pudo eliminar al chofer.'
              : '${driver.name} fue eliminado.',
        ),
      ),
    );
  }
}

class _StatusFilter extends StatelessWidget {
  const _StatusFilter({required this.value, required this.onChanged});

  final DriverStatus? value;
  final ValueChanged<DriverStatus?> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonHideUnderline(
      child: DropdownButton<DriverStatus?>(
        value: value,
        hint: const Text('Todos'),
        onChanged: onChanged,
        items: const [
          DropdownMenuItem(child: Text('Todos')),
          DropdownMenuItem(value: DriverStatus.active, child: Text('Activos')),
          DropdownMenuItem(
            value: DriverStatus.inactive,
            child: Text('Inactivos'),
          ),
          DropdownMenuItem(
            value: DriverStatus.suspended,
            child: Text('Suspendidos'),
          ),
        ],
      ),
    );
  }
}

class _DriverTable extends StatelessWidget {
  const _DriverTable({
    required this.drivers,
    required this.appOpen,
    required this.onView,
    required this.onEdit,
    required this.onDelete,
    required this.onChangeStatus,
  });

  final List<Driver> drivers;

  /// Ids of the choferes with the app open right now.
  final Set<String> appOpen;
  final ValueChanged<Driver> onView;
  final ValueChanged<Driver> onEdit;
  final ValueChanged<Driver> onDelete;
  final void Function(Driver driver, DriverStatus target) onChangeStatus;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: Insets.xl),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: MediaQuery.sizeOf(context).width - 300,
          ),
          child: DataTable(
            // Room for the avatar beside the three-line name cell.
            dataRowMinHeight: 68,
            dataRowMaxHeight: 72,
            // Tighter than the default 56, so the actions column fits a laptop
            // screen instead of sitting past a sideways scroll.
            columnSpacing: 28,
            headingRowColor: const WidgetStatePropertyAll(BrandColors.offWhite),
            headingTextStyle: text.labelSmall,
            dividerThickness: 1,
            columns: const [
              DataColumn(label: Text('CHOFER')),
              DataColumn(label: Text('CÉDULA')),
              DataColumn(label: Text('GRÚA')),
              DataColumn(label: Text('ESTADO')),
              DataColumn(label: Text('ACEPTA'), numeric: true),
              DataColumn(label: Text('SERVICIOS'), numeric: true),
              DataColumn(label: Text('EFECTIVO'), numeric: true),
              DataColumn(label: Text('ACCIONES')),
            ],
            rows: [
              for (final driver in drivers)
                DataRow(
                  cells: [
                    DataCell(
                      Row(
                        children: [
                          DriverAvatar.of(
                            driver,
                            appOpen: appOpen.contains(driver.id),
                          ),
                          const SizedBox(width: Insets.md),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(driver.name, style: text.titleSmall),
                              // Under the name rather than a column of its
                              // own, which would push the actions off-screen.
                              if (driver.email.isNotEmpty)
                                Text(
                                  driver.email,
                                  style: text.bodySmall
                                      ?.copyWith(color: BrandColors.grey800),
                                ),
                              Text(
                                driver.phone,
                                style: text.bodySmall
                                    ?.copyWith(color: BrandColors.grey600),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    DataCell(Text(driver.displayCedula)),
                    DataCell(
                      Text(
                        driver.assignedTruckId == null
                            ? 'Sin asignar'
                            : '${driver.assignedTruckPlate} · '
                                '${driver.truckType.label}',
                      ),
                    ),
                    // Presence is the avatar's dot, with its label on hover.
                    DataCell(_StatusPill(status: driver.status)),
                    DataCell(
                      Text(
                        driver.acceptanceLabel,
                        style: text.bodyMedium?.copyWith(
                          // Below 60% is either a notification problem or
                          // cherry-picking; both need looking at.
                          color: driver.acceptanceRate < 0.6
                              ? BrandColors.danger
                              : BrandColors.ink,
                        ),
                      ),
                    ),
                    DataCell(Text('${driver.completedServices}')),
                    DataCell(
                      Text(
                        driver.cashOwedCents == 0
                            ? '—'
                            : driver.cashOwedCents.formatDOP,
                        style: text.bodyMedium?.copyWith(
                          color: driver.cashOwedCents > 0
                              ? BrandColors.warning
                              : BrandColors.grey600,
                        ),
                      ),
                    ),
                    DataCell(
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Ver',
                            visualDensity: VisualDensity.compact,
                            onPressed: () => onView(driver),
                            icon: const Icon(Icons.visibility_outlined, size: 20),
                          ),
                          IconButton(
                            tooltip: 'Editar',
                            visualDensity: VisualDensity.compact,
                            onPressed: () => onEdit(driver),
                            icon: const Icon(Icons.edit_outlined, size: 20),
                          ),
                          // The one status change each row most often needs:
                          // clearing a new account, or stopping a working one.
                          // Marking inactive lives in the details dialog.
                          if (driver.status.canWork)
                            IconButton(
                              tooltip: 'Suspender',
                              visualDensity: VisualDensity.compact,
                              onPressed: () => onChangeStatus(
                                driver,
                                DriverStatus.suspended,
                              ),
                              icon: const Icon(
                                Icons.block,
                                size: 20,
                                color: BrandColors.warning,
                              ),
                            )
                          else
                            IconButton(
                              tooltip: 'Activar',
                              visualDensity: VisualDensity.compact,
                              onPressed: () =>
                                  onChangeStatus(driver, DriverStatus.active),
                              icon: const Icon(
                                Icons.check_circle_outline,
                                size: 20,
                                color: BrandColors.success,
                              ),
                            ),
                          IconButton(
                            tooltip: 'Eliminar',
                            visualDensity: VisualDensity.compact,
                            onPressed: () => onDelete(driver),
                            icon: const Icon(
                              Icons.delete_outline,
                              size: 20,
                              color: BrandColors.danger,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});

  final DriverStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, fg, bg) = switch (status) {
      DriverStatus.active => ('Activo', BrandColors.success, BrandColors.successTint),
      DriverStatus.inactive => ('Inactivo', BrandColors.grey600, BrandColors.grey100),
      DriverStatus.suspended =>
        ('Suspendido', BrandColors.danger, BrandColors.dangerTint),
      DriverStatus.unknown => ('—', BrandColors.grey600, BrandColors.grey100),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Insets.sm, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: Corners.brXs),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg),
      ),
    );
  }
}
