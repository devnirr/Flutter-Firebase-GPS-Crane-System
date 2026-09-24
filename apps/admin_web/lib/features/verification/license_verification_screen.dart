import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

import 'license_review_dialog.dart';

/// Licence checks of the choferes who registered from the app.
///
/// The model reads the licence; the office decides. A verified licence only
/// means the account is ready to activate — activating it is still a click
/// here or on Choferes. Choferes the office opened itself never appear: their
/// papers were seen in person.
class LicenseVerificationScreen extends ConsumerStatefulWidget {
  const LicenseVerificationScreen({super.key});

  @override
  ConsumerState<LicenseVerificationScreen> createState() =>
      _LicenseVerificationScreenState();
}

/// The queues the office works through, in the order it works them.
enum LicenseQueue {
  toActivate('Por activar'),
  manualReview('Revisión manual'),
  rejected('Rechazadas'),
  inProgress('En proceso'),
  all('Todas');

  const LicenseQueue(this.label);

  final String label;

  bool contains(Driver driver) {
    final state = driver.licenseVerification?.state;
    return switch (this) {
      LicenseQueue.toActivate => state == LicenseVerificationState.verified &&
          driver.status == DriverStatus.inactive,
      LicenseQueue.manualReview =>
        state == LicenseVerificationState.manualReview,
      LicenseQueue.rejected => state == LicenseVerificationState.rejected,
      LicenseQueue.inProgress =>
        state == LicenseVerificationState.awaitingDocuments ||
            state == LicenseVerificationState.processing,
      LicenseQueue.all => true,
    };
  }
}

/// Choferes with a licence check, the archived left out.
List<Driver> choferesWithLicenseCheck(List<Driver> drivers) => drivers
    .where((d) => !d.archived && d.licenseVerification != null)
    .toList();

/// What the sidebar badge counts: licences waiting on the office.
int licensesNeedingOffice(List<Driver> drivers) =>
    choferesWithLicenseCheck(drivers)
        .where(
          (d) =>
              LicenseQueue.toActivate.contains(d) ||
              LicenseQueue.manualReview.contains(d),
        )
        .length;

class _LicenseVerificationScreenState
    extends ConsumerState<LicenseVerificationScreen> {
  LicenseQueue _queue = LicenseQueue.toActivate;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final roster = ref.watch(allDriversProvider);
    final text = Theme.of(context).textTheme;
    final drivers = choferesWithLicenseCheck(roster.value ?? const []);

    final query = _query.trim().toLowerCase();
    final shown = drivers.where((d) {
      if (!_queue.contains(d)) return false;
      if (query.isEmpty) return true;
      return d.name.toLowerCase().contains(query) || d.cedula.contains(query);
    }).toList()
      // Oldest first: whoever has waited longest is next.
      ..sort(
        (a, b) => (a.licenseVerification?.updatedAt ?? a.createdAt ?? DateTime(0))
            .compareTo(
          b.licenseVerification?.updatedAt ?? b.createdAt ?? DateTime(0),
        ),
      );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Insets.xl,
            Insets.xl,
            Insets.xl,
            Insets.md,
          ),
          child: Wrap(
            spacing: Insets.lg,
            runSpacing: Insets.md,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Verificación de licencias', style: text.headlineSmall),
              SizedBox(
                width: 260,
                height: 38,
                child: TextField(
                  onChanged: (value) => setState(() => _query = value),
                  decoration: const InputDecoration(
                    hintText: 'Nombre o cédula',
                    prefixIcon: Icon(Icons.search, size: 18),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Insets.xl),
          child: Wrap(
            spacing: Insets.sm,
            runSpacing: Insets.sm,
            children: [
              for (final queue in LicenseQueue.values)
                ChoiceChip(
                  label: Text(
                    '${queue.label} '
                    '(${drivers.where(queue.contains).length})',
                  ),
                  selected: _queue == queue,
                  onSelected: (_) => setState(() => _queue = queue),
                ),
            ],
          ),
        ),
        const SizedBox(height: Insets.md),
        Expanded(child: _body(roster, drivers, shown)),
      ],
    );
  }

  Widget _body(
    AsyncValue<List<Driver>> roster,
    List<Driver> drivers,
    List<Driver> shown,
  ) {
    if (!roster.hasValue) {
      if (roster.hasError) {
        return EmptyState(
          title: 'No se pudo cargar',
          message: 'La lista de choferes no está disponible ahora mismo.',
          icon: Icons.cloud_off_outlined,
          tone: EmptyStateTone.error,
          actionLabel: 'Reintentar',
          onAction: () => ref.invalidate(allDriversProvider),
        );
      }
      return const BrandLoader(message: 'Cargando verificaciones…');
    }
    if (drivers.isEmpty) {
      return const EmptyState(
        title: 'Sin registros desde la app',
        message: 'Cuando un chofer se registre desde la app, su licencia '
            'aparecerá aquí.',
        icon: Icons.verified_user_outlined,
      );
    }
    if (shown.isEmpty) {
      return EmptyState(
        title: 'Nada en "${_queue.label}"',
        message: 'Ningún chofer está en esta lista ahora mismo.',
        icon: Icons.inbox_outlined,
      );
    }
    return _Table(
      drivers: shown,
      onReview: (driver) =>
          unawaited(showLicenseReviewDialog(context, driver.id)),
    );
  }
}

class _Table extends StatelessWidget {
  const _Table({required this.drivers, required this.onReview});

  final List<Driver> drivers;
  final ValueChanged<Driver> onReview;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: Insets.xl),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: MediaQuery.sizeOf(context).width - 300,
          ),
          child: DataTable(
            dataRowMinHeight: 64,
            dataRowMaxHeight: 68,
            columnSpacing: 28,
            headingRowColor: WidgetStatePropertyAll(palette.canvas),
            headingTextStyle: text.labelSmall,
            showCheckboxColumn: false,
            columns: const [
              DataColumn(label: Text('CHOFER')),
              DataColumn(label: Text('CÉDULA')),
              DataColumn(label: Text('LICENCIA')),
              DataColumn(label: Text('VERIFICACIÓN')),
              DataColumn(label: Text('INTENTOS'), numeric: true),
              DataColumn(label: Text('CUENTA')),
              DataColumn(label: Text('ACTUALIZADA')),
              DataColumn(label: Text('')),
            ],
            rows: [
              for (final driver in drivers)
                DataRow(
                  onSelectChanged: (_) => onReview(driver),
                  cells: [
                    DataCell(
                      Row(
                        children: [
                          DriverAvatar.of(driver),
                          const SizedBox(width: Insets.md),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(driver.name, style: text.titleSmall),
                              Text(
                                driver.email,
                                style: text.bodySmall
                                    ?.copyWith(color: palette.textMuted),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    DataCell(Text(driver.displayCedula)),
                    DataCell(
                      Text(
                        '${driver.licenseNumber}\n'
                        'Vence ${driver.licenseExpiry == null ? '—' : DoTime.fullDate(driver.licenseExpiry!)}',
                        style: text.bodySmall,
                      ),
                    ),
                    DataCell(
                      LicenseStatePill(
                        state: driver.licenseVerification!.state,
                      ),
                    ),
                    DataCell(Text('${driver.licenseVerification!.attempts}')),
                    DataCell(
                      Text(
                        switch (driver.status) {
                          DriverStatus.active => 'Activa',
                          DriverStatus.suspended => 'Suspendida',
                          _ => 'Inactiva',
                        },
                        style: text.bodyMedium?.copyWith(
                          color: driver.status == DriverStatus.active
                              ? palette.success
                              : palette.textMuted,
                        ),
                      ),
                    ),
                    DataCell(
                      Text(
                        _when(driver.licenseVerification!.updatedAt),
                        style: text.bodySmall
                            ?.copyWith(color: palette.textMuted),
                      ),
                    ),
                    DataCell(
                      OutlinedButton(
                        onPressed: () => onReview(driver),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 36),
                          padding: const EdgeInsets.symmetric(
                            horizontal: Insets.md,
                          ),
                        ),
                        child: const Text('Revisar'),
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

  static String _when(DateTime? at) =>
      at == null ? '—' : DoTime.dateAndTime(at);
}

/// A licence check's state as a coloured pill.
class LicenseStatePill extends StatelessWidget {
  const LicenseStatePill({required this.state, super.key});

  final LicenseVerificationState state;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final (fg, bg) = switch (state) {
      LicenseVerificationState.verified => (palette.success, palette.successTint),
      LicenseVerificationState.rejected => (palette.danger, palette.dangerTint),
      LicenseVerificationState.manualReview =>
        (palette.warning, palette.warningTint),
      _ => (palette.textMuted, palette.surfaceSubtle),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Insets.sm, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: Corners.brXs),
      child: Text(
        state.label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg),
      ),
    );
  }
}
