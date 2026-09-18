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

    // Active first, then by name: a suspended company at the top of the list
    // is the one thing nobody is looking for.
    final sorted = insurers == null
        ? null
        : (insurers.toList()..sort((a, b) {
            if (a.isActive != b.isActive) return a.isActive ? -1 : 1;
            return a.name.toLowerCase().compareTo(b.name.toLowerCase());
          }));
    final suspended = sorted?.where((i) => !i.isActive).length ?? 0;

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
                    style: text.bodyMedium?.copyWith(color: palette.textMuted),
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
        if (sorted != null && sorted.isNotEmpty) ...[
          const SizedBox(height: Insets.md),
          Text(
            [
              if (sorted.length == 1)
                '1 empresa'
              else
                '${sorted.length} empresas',
              if (suspended == 1)
                '1 suspendida'
              else if (suspended > 1)
                '$suspended suspendidas',
            ].join(' · '),
            style: text.bodySmall?.copyWith(color: palette.textFaint),
          ),
        ],
        const SizedBox(height: Insets.xl),
        FloatingCard(
          // The rows run to the card's edge, so their dividers and their hover
          // do too; the padding that would have been here is on each row.
          padding: EdgeInsets.zero,
          child: switch (sorted) {
            null => const Padding(
              padding: EdgeInsets.all(Insets.xl),
              child: BrandLoader(),
            ),
            [] => EmptyState(
              icon: Icons.shield_outlined,
              title: 'Todavía no hay aseguradoras',
              message:
                  'Agrega la primera para poder registrarle servicios, '
                  'sus usuarios y su tarifa.',
              actionLabel: isAdmin ? 'Nueva aseguradora' : null,
              onAction: isAdmin
                  ? () async {
                      final id = await showCreateInsurerDialog(context);
                      if (id != null && context.mounted) {
                        context.go(Routes.insurerFor(id));
                      }
                    }
                  : null,
            ),
            final list => Column(
              children: [
                for (final (index, i) in list.indexed) ...[
                  if (index > 0) const Divider(height: 1),
                  _InsurerRow(insurer: i),
                ],
              ],
            ),
          },
        ),
      ],
    );
  }
}

/// One company in the list: who they are, what the chofer gets on their jobs,
/// whether they can order, and a chevron because the row opens their page.
class _InsurerRow extends StatelessWidget {
  const _InsurerRow({required this.insurer});

  final Insurer insurer;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final i = insurer;
    // A suspended company is greyed to the same degree its chip says it is.
    final tone = i.isActive ? palette.brand : palette.textFaint;

    return InkWell(
      key: Key('insurer-row-${i.id}'),
      onTap: () => context.go(Routes.insurerFor(i.id)),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.lg,
          vertical: Insets.md,
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: tone.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.shield_outlined, size: 20, color: tone),
            ),
            const SizedBox(width: Insets.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(i.name, style: text.titleSmall),
                  const SizedBox(height: 1),
                  Text(
                    'RNC ${i.rncLabel} · ${i.billingEmail}',
                    style: text.bodySmall?.copyWith(color: palette.textMuted),
                  ),
                ],
              ),
            ),
            // What the chofer takes home on this company's jobs: the number
            // the office actually compares companies by.
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.sm,
                vertical: 2,
              ),
              decoration: BoxDecoration(
                color: palette.surfaceSubtle,
                borderRadius: Corners.brSm,
              ),
              child: Text(
                'Chofer ${i.driverPayoutLabel}',
                style: text.labelMedium?.copyWith(color: palette.textMuted),
              ),
            ),
            const SizedBox(width: Insets.md),
            // A fixed slot: "Suspendida" is wider than "Activa", and without
            // it every chip in the column shifts by the difference.
            SizedBox(
              width: 96,
              child: Align(
                alignment: Alignment.centerRight,
                child: InsurerStatusChip(status: i.status),
              ),
            ),
            const SizedBox(width: Insets.sm),
            Icon(Icons.chevron_right, size: 20, color: palette.textFaint),
          ],
        ),
      ),
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
        // A column rather than a list: the tabs then take the rest of the
        // window instead of a fixed 720 px, which left a short tab floating
        // over dead space and a long one scrolling the whole page.
        child: Padding(
          padding: const EdgeInsets.all(Insets.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => context.go(Routes.insurers),
                  style: TextButton.styleFrom(
                    // The theme's buttons fill their width, which centred this
                    // one over the page like a heading.
                    minimumSize: Size.zero,
                    padding: const EdgeInsets.symmetric(
                      horizontal: Insets.sm,
                      vertical: Insets.xs,
                    ),
                    foregroundColor: palette.textMuted,
                  ),
                  icon: const Icon(Icons.arrow_back, size: 18),
                  label: const Text('Aseguradoras'),
                ),
              ),
              const SizedBox(height: Insets.sm),
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: (i.isActive ? palette.brand : palette.textFaint)
                          .withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.shield_outlined,
                      size: 22,
                      color: i.isActive ? palette.brand : palette.textFaint,
                    ),
                  ),
                  const SizedBox(width: Insets.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(i.name, style: text.headlineSmall),
                        Text(
                          'RNC ${i.rncLabel} · Chofer ${i.driverPayoutLabel}',
                          style: text.bodySmall?.copyWith(
                            color: palette.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  InsurerStatusChip(status: i.status),
                  if (isAdmin) ...[
                    const SizedBox(width: Insets.md),
                    OutlinedButton.icon(
                      key: const Key('edit-insurer'),
                      onPressed: () => showEditInsurerDialog(context, i),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 40),
                      ),
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: const Text('Editar'),
                    ),
                    const SizedBox(width: Insets.sm),
                    OutlinedButton.icon(
                      key: const Key('toggle-insurer-status'),
                      onPressed: () => _toggleStatus(context, ref, i),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 40),
                        foregroundColor: i.isActive
                            ? palette.danger
                            : palette.success,
                      ),
                      icon: Icon(
                        i.isActive ? Icons.block : Icons.check_circle_outline,
                        size: 18,
                      ),
                      label: Text(i.isActive ? 'Suspender' : 'Reactivar'),
                    ),
                  ],
                ],
              ),
              if (!i.isActive && i.statusReason.isNotEmpty) ...[
                const SizedBox(height: Insets.md),
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
              Expanded(
                child: TabBarView(
                  children: [
                    SingleChildScrollView(child: _Details(insurer: i)),
                    SingleChildScrollView(
                      child: InsurerUsersPanel(
                        insurerId: i.id,
                        canEdit: isAdmin,
                      ),
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

  /// Under this the two cards side by side are narrower than the emails in
  /// them.
  static const _stackUnder = 900.0;

  @override
  Widget build(BuildContext context) {
    final i = insurer;

    final company = _InfoCard(
      icon: Icons.business_outlined,
      title: 'Empresa',
      fields: [
        (label: 'RNC', value: i.rncLabel, note: null),
        (label: 'Correo de facturación', value: i.billingEmail, note: null),
        (
          label: 'Pago al chofer',
          value: i.driverPayoutLabel,
          // Said once, under the figure, rather than in brackets beside it.
          note: i.driverPayoutBps == null
              ? 'Usa el porcentaje predeterminado.'
              : 'Negociado con esta empresa.',
        ),
      ],
    );

    final contact = _InfoCard(
      icon: Icons.person_outline,
      title: 'Contacto',
      fields: [
        (label: 'Nombre', value: i.contactName, note: null),
        (label: 'Correo', value: i.contactEmail, note: null),
        (
          label: 'Teléfono',
          value: DoValidators.phoneLabel(i.contactPhone),
          note: null,
        ),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < _stackUnder) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              company,
              const SizedBox(height: Insets.lg),
              contact,
            ],
          );
        }
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: company),
              const SizedBox(width: Insets.lg),
              Expanded(child: contact),
            ],
          ),
        );
      },
    );
  }
}

/// A group of stored values under one heading.
///
/// Label over value rather than label and value at opposite edges: at this
/// width a row put a hand's width of nothing between the two, and the eye had
/// to travel it for every line.
class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.icon,
    required this.title,
    required this.fields,
  });

  final IconData icon;
  final String title;
  final List<({String label, String value, String? note})> fields;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;

    return FloatingCard(
      padding: const EdgeInsets.all(Insets.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: palette.textMuted),
              const SizedBox(width: Insets.sm),
              Text(title, style: text.titleMedium),
            ],
          ),
          const SizedBox(height: Insets.lg),
          for (final (index, field) in fields.indexed) ...[
            if (index > 0) const SizedBox(height: Insets.lg),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FieldLabel(field.label),
                const SizedBox(height: Insets.xxs),
                Text(
                  field.value.trim().isEmpty ? '—' : field.value,
                  style: text.bodyLarge?.copyWith(
                    color: field.value.trim().isEmpty
                        ? palette.textFaint
                        : palette.text,
                  ),
                ),
                if (field.note != null) ...[
                  const SizedBox(height: Insets.xxs),
                  Text(
                    field.note!,
                    style: text.bodySmall?.copyWith(color: palette.textMuted),
                  ),
                ],
              ],
            ),
          ],
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
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => context.go(Routes.insurers),
            style: TextButton.styleFrom(
              // The theme's buttons fill their width, which centred this one
              // over the page like a heading.
              minimumSize: Size.zero,
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.sm,
                vertical: Insets.xs,
              ),
              foregroundColor: palette.textMuted,
            ),
            icon: const Icon(Icons.arrow_back, size: 18),
            label: const Text('Aseguradoras'),
          ),
        ),
        const SizedBox(height: Insets.sm),
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
