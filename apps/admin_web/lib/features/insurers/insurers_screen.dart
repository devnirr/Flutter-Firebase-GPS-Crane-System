import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';
import '../shared/toast.dart';
import 'insurer_form_dialog.dart';
import 'insurer_users_panel.dart';
import 'zone_table_editor.dart';

/// Aseguradoras: the insurance companies that order tows and are billed
/// monthly. Only an admin changes anything here.
class InsurersScreen extends ConsumerWidget {
  const InsurersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final insurers = ref.watch(allInsurersProvider).value;
    final isAdmin = ref.watch(currentRoleProvider).value == UserRole.admin;

    return ListView(
      padding: const EdgeInsets.all(Insets.xl),
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Aseguradoras', style: text.headlineSmall),
                  const SizedBox(height: Insets.xs),
                  Text(
                    'Empresas que piden grúas para sus asegurados y pagan a fin de mes.',
                    style: text.bodyMedium?.copyWith(
                      color: palette.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            OutlinedButton.icon(
              key: const Key('open-default-tariff'),
              onPressed: () => context.go(Routes.defaultTariff),
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
              icon: const Icon(Icons.price_change_outlined),
              label: const Text('Tarifa base'),
            ),
            if (isAdmin) ...[
              const SizedBox(width: Insets.sm),
              ElevatedButton.icon(
                key: const Key('create-insurer'),
                onPressed: () async {
                  final id = await showCreateInsurerDialog(context);
                  if (id != null && context.mounted) {
                    context.go(Routes.insurerFor(id));
                  }
                },
                style: ElevatedButton.styleFrom(minimumSize: const Size(0, 44)),
                icon: const Icon(Icons.add_business_outlined),
                label: const Text('Nueva aseguradora'),
              ),
            ],
          ],
        ),
        const SizedBox(height: Insets.xl),
        FloatingCard(
          child: switch (insurers) {
            null => const BrandLoader(),
            [] => Text(
              'Todavía no hay aseguradoras.',
              style: text.bodyMedium?.copyWith(color: palette.textMuted),
            ),
            final list => Column(
              children: [
                for (final i in list)
                  ListTile(
                    key: Key('insurer-row-${i.id}'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.shield_outlined),
                    title: Text(i.name),
                    subtitle: Text(
                      [
                        'RNC ${i.rncLabel}',
                        i.billingEmail,
                        'Chofer ${i.driverPayoutLabel}',
                      ].join(' · '),
                    ),
                    trailing: InsurerStatusChip(status: i.status),
                    onTap: () => context.go(Routes.insurerFor(i.id)),
                  ),
              ],
            ),
          },
        ),
      ],
    );
  }
}

class InsurerStatusChip extends StatelessWidget {
  const InsurerStatusChip({required this.status, super.key});

  final InsurerStatus status;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final (fg, bg) = status.isActive
        ? (palette.success, palette.successTint)
        : (palette.danger, palette.dangerTint);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.md,
        vertical: Insets.xs,
      ),
      decoration: BoxDecoration(color: bg, borderRadius: Corners.brSm),
      child: Text(
        status.label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg),
      ),
    );
  }
}

/// One company: its details, its people and its prices.
class InsurerDetailScreen extends ConsumerWidget {
  const InsurerDetailScreen({required this.insurerId, super.key});

  final String insurerId;

  Future<void> _toggleStatus(
    BuildContext context,
    WidgetRef ref,
    Insurer insurer,
  ) async {
    String? reason;
    if (insurer.isActive) {
      reason = await showDialog<String>(
        context: context,
        builder: (_) => const _SuspendDialog(),
      );
      if (reason == null) return;
    }
    final result = await ref
        .read(functionsGatewayProvider)
        .updateInsurer(
          insurerId: insurer.id,
          status: insurer.isActive
              ? InsurerStatus.suspended
              : InsurerStatus.active,
          statusReason: reason,
        );
    if (!context.mounted) return;
    final (message, tone) = switch (result) {
      Ok() => (
        insurer.isActive
            ? '${insurer.name} quedó suspendida. Sus usuarios ya no pueden entrar.'
            : '${insurer.name} está activa otra vez.',
        ToastTone.success,
      ),
      Err(:final failure) => (failure.userMessage, ToastTone.error),
    };
    showToast(context, message, tone: tone);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final insurer = ref.watch(insurerProvider(insurerId));
    final isAdmin = ref.watch(currentRoleProvider).value == UserRole.admin;

    return switch (insurer) {
      AsyncData(value: null) => EmptyState(
        title: 'Aseguradora no encontrada',
        message: 'No existe una aseguradora con ese enlace.',
        icon: Icons.shield_outlined,
        actionLabel: 'Ver aseguradoras',
        onAction: () => context.go(Routes.insurers),
      ),
      AsyncData(value: final i?) => DefaultTabController(
        length: 3,
        child: ListView(
          padding: const EdgeInsets.all(Insets.xl),
          children: [
            TextButton.icon(
              onPressed: () => context.go(Routes.insurers),
              icon: const Icon(Icons.arrow_back, size: 18),
              label: const Text('Aseguradoras'),
            ),
            Row(
              children: [
                Expanded(child: Text(i.name, style: text.headlineSmall)),
                InsurerStatusChip(status: i.status),
                if (isAdmin) ...[
                  const SizedBox(width: Insets.md),
                  OutlinedButton(
                    key: const Key('edit-insurer'),
                    onPressed: () => showEditInsurerDialog(context, i),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 40),
                    ),
                    child: const Text('Editar'),
                  ),
                  const SizedBox(width: Insets.sm),
                  OutlinedButton(
                    key: const Key('toggle-insurer-status'),
                    onPressed: () => _toggleStatus(context, ref, i),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 40),
                      foregroundColor: i.isActive
                          ? palette.danger
                          : palette.success,
                    ),
                    child: Text(i.isActive ? 'Suspender' : 'Reactivar'),
                  ),
                ],
              ],
            ),
            if (!i.isActive && i.statusReason.isNotEmpty) ...[
              const SizedBox(height: Insets.sm),
              InlineNotice(
                tone: NoticeTone.error,
                icon: Icons.block,
                message: 'Suspendida: ${i.statusReason}',
              ),
            ],
            const SizedBox(height: Insets.lg),
            const TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                Tab(key: Key('tab-details'), text: 'Datos'),
                Tab(key: Key('tab-users'), text: 'Usuarios'),
                Tab(key: Key('tab-tariff'), text: 'Tarifa'),
              ],
            ),
            const SizedBox(height: Insets.lg),
            SizedBox(
              height: 720,
              child: TabBarView(
                children: [
                  SingleChildScrollView(child: _Details(insurer: i)),
                  SingleChildScrollView(
                    child: InsurerUsersPanel(insurerId: i.id, canEdit: isAdmin),
                  ),
                  SingleChildScrollView(
                    child: ZoneTariffPanel(insurerId: i.id, canEdit: isAdmin),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      AsyncError() => const EmptyState(
        title: 'No pudimos cargar la aseguradora',
        message: 'Revisa tu conexión e intenta de nuevo.',
        icon: Icons.error_outline,
      ),
      _ => const BrandLoader(),
    };
  }
}

class _Details extends StatelessWidget {
  const _Details({required this.insurer});

  final Insurer insurer;

  @override
  Widget build(BuildContext context) {
    final i = insurer;
    return FloatingCard(
      child: Column(
        children: [
          DetailRow(label: 'RNC', value: i.rncLabel),
          DetailRow(label: 'Correo de facturación', value: i.billingEmail),
          DetailRow(
            label: 'Contacto',
            value: i.contactName.isEmpty ? '—' : i.contactName,
          ),
          DetailRow(
            label: 'Correo de contacto',
            value: i.contactEmail.isEmpty ? '—' : i.contactEmail,
          ),
          DetailRow(
            label: 'Teléfono',
            value: i.contactPhone.isEmpty ? '—' : i.contactPhone,
          ),
          DetailRow(
            key: const Key('insurer-payout-row'),
            label: 'Pago al chofer',
            value:
                '${i.driverPayoutLabel}${i.driverPayoutBps == null ? ' (predeterminado)' : ''}',
          ),
        ],
      ),
    );
  }
}

class _SuspendDialog extends StatefulWidget {
  const _SuspendDialog();

  @override
  State<_SuspendDialog> createState() => _SuspendDialogState();
}

class _SuspendDialogState extends State<_SuspendDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Suspender aseguradora'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Sus usuarios dejarán de poder entrar y pedir grúas. Las grúas '
            'ya en camino terminan su servicio.',
          ),
          const SizedBox(height: Insets.md),
          TextField(
            key: const Key('suspend-reason'),
            controller: _reason,
            decoration: const InputDecoration(labelText: 'Motivo'),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancelar'),
      ),
      ElevatedButton(
        key: const Key('confirm-suspend'),
        onPressed: () => Navigator.of(context).pop(_reason.text.trim()),
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(0, 40),
          backgroundColor: context.palette.danger,
        ),
        child: const Text('Suspender'),
      ),
    ],
  );
}

/// The default price list: what every company without its own is billed.
class DefaultTariffScreen extends ConsumerWidget {
  const DefaultTariffScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final isAdmin = ref.watch(currentRoleProvider).value == UserRole.admin;
    return ListView(
      padding: const EdgeInsets.all(Insets.xl),
      children: [
        TextButton.icon(
          onPressed: () => context.go(Routes.insurers),
          icon: const Icon(Icons.arrow_back, size: 18),
          label: const Text('Aseguradoras'),
        ),
        Text('Tarifa base', style: text.headlineSmall),
        const SizedBox(height: Insets.xs),
        Text(
          'Precios por zona de kilómetros, sin ITBIS, para toda aseguradora sin '
          'precio negociado. Más allá de la última zona se cobra el precio más '
          'el extra por cada kilómetro pasado su inicio.',
          style: text.bodyMedium?.copyWith(color: palette.textMuted),
        ),
        const SizedBox(height: Insets.xl),
        ZoneTariffPanel(insurerId: null, canEdit: isAdmin),
      ],
    );
  }
}
