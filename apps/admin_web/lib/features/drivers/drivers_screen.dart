import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

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
    final drivers = ref.watch(allDriversProvider).value ?? const [];
    final text = Theme.of(context).textTheme;

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
                onPressed: () => _showCreateNotice(context),
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
        Expanded(
          child: filtered.isEmpty
              ? const EmptyState(
                  title: 'Sin resultados',
                  message: 'Ningún chofer coincide con ese filtro.',
                  icon: Icons.search_off,
                )
              : _DriverTable(drivers: filtered),
        ),
      ],
    );
  }

  void _showCreateNotice(BuildContext context) {
    // Fire-and-forget: nothing depends on which button closed the dialog.
    unawaited(showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Crear chofer'),
        content: const SizedBox(
          width: 420,
          child: Text(
            'La creación de cuentas llama a la Cloud Function createDriver, '
            'que crea el usuario de Auth, fija el rol y deja la cuenta '
            'inactiva hasta verificar los documentos. Se habilita al conectar '
            'Firebase.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Entendido'),
          ),
        ],
      ),
    ));
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
  const _DriverTable({required this.drivers});

  final List<Driver> drivers;

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
            headingRowColor: const WidgetStatePropertyAll(BrandColors.offWhite),
            headingTextStyle: text.labelSmall,
            dividerThickness: 1,
            columns: const [
              DataColumn(label: Text('CHOFER')),
              DataColumn(label: Text('CÉDULA')),
              DataColumn(label: Text('GRÚA')),
              DataColumn(label: Text('ESTADO')),
              DataColumn(label: Text('EN LÍNEA')),
              DataColumn(label: Text('ACEPTA'), numeric: true),
              DataColumn(label: Text('SERVICIOS'), numeric: true),
              DataColumn(label: Text('EFECTIVO'), numeric: true),
            ],
            rows: [
              for (final driver in drivers)
                DataRow(
                  cells: [
                    DataCell(
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(driver.name, style: text.titleSmall),
                          Text(
                            driver.phone,
                            style: text.bodySmall
                                ?.copyWith(color: BrandColors.grey600),
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
                    DataCell(_StatusPill(status: driver.status)),
                    DataCell(
                      Icon(
                        driver.isOnline ? Icons.circle : Icons.circle_outlined,
                        size: 12,
                        color: driver.isOnline
                            ? BrandColors.success
                            : BrandColors.grey400,
                      ),
                    ),
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
