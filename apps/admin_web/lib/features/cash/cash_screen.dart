import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

import '../shared/page_parts.dart';
import '../shared/toast.dart';

/// Efectivo: what each chofer collected in cash and still holds for the
/// company, and the cortes that brought it in.
///
/// Every tow is paid in cash: the customer hands it to the chofer, the chofer
/// marks "Cobrado en efectivo", and it sits with them until the office receives
/// it here. A corte counts every such job at once and marks them, so none is
/// ever counted twice.
class CashScreen extends ConsumerWidget {
  const CashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final drivers = ref.watch(allDriversProvider).value ?? const <Driver>[];
    final settlements = ref.watch(cashSettlementsProvider).value ?? const [];

    final holding = drivers.where((d) => d.cashOnHandCents > 0).toList()
      ..sort((a, b) => b.cashOnHandCents.compareTo(a.cashOnHandCents));
    final total = holding.fold(0, (sum, d) => sum + d.cashOnHandCents);

    // What has already come in this month, as the counterweight to what is
    // still out: the figure the office is working towards.
    final now = DateTime.now();
    final received = settlements
        .where(
          (s) =>
              s.createdAt != null &&
              s.createdAt!.year == now.year &&
              s.createdAt!.month == now.month,
        )
        .fold(0, (sum, s) => sum + s.amountCents);

    // A project with nothing on either list gets one explanation rather than
    // two cards each saying they are empty.
    final nothingYet = holding.isEmpty && settlements.isEmpty;

    return ListView(
      padding: const EdgeInsets.all(Insets.xl),
      children: [
        Text('Efectivo', style: text.headlineSmall),
        const SizedBox(height: Insets.xs),
        Text(
          'Lo que los choferes cobraron en efectivo y todavía no han entregado.',
          style: text.bodyMedium?.copyWith(color: palette.textMuted),
        ),
        const SizedBox(height: Insets.xl),
        StatRow(
          children: [
            StatTile(
              icon: Icons.account_balance_wallet_outlined,
              label: 'Efectivo por entregar',
              value: total.formatDOP,
              color: total > 0 ? palette.brand : null,
            ),
            StatTile(
              icon: Icons.groups_outlined,
              label: 'Choferes con efectivo',
              value: '${holding.length}',
            ),
            StatTile(
              icon: Icons.task_alt_outlined,
              label: 'Recibido este mes',
              value: received.formatDOP,
              color: received > 0 ? palette.success : null,
            ),
          ],
        ),
        const SizedBox(height: Insets.xl),
        if (nothingYet)
          const FloatingCard(
            key: Key('cash-by-driver'),
            child: EmptyState(
              icon: Icons.payments_outlined,
              title: 'Nada pendiente de entregar',
              message:
                  'Cuando un chofer cobre un servicio en efectivo, '
                  'aparece aquí para hacerle el corte.',
            ),
          )
        else ...[
          _Section(
            cardKey: const Key('cash-by-driver'),
            title: 'Por chofer',
            count: holding.length,
            emptyMessage: 'Ningún chofer tiene efectivo por entregar.',
            rows: [
              for (final driver in holding) _DriverCashRow(driver: driver),
            ],
          ),
          const SizedBox(height: Insets.xl),
          _Section(
            cardKey: const Key('cash-settlements'),
            title: 'Cortes realizados',
            count: settlements.length,
            emptyMessage: 'Todavía no hay cortes.',
            rows: [
              for (final corte in settlements) _SettlementRow(corte: corte),
            ],
          ),
        ],
      ],
    );
  }
}

/// A titled card holding a list, with the count beside the title and a line
/// between rows so a long list reads as rows rather than as a block.
class _Section extends StatelessWidget {
  const _Section({
    required this.cardKey,
    required this.title,
    required this.count,
    required this.emptyMessage,
    required this.rows,
  });

  final Key cardKey;
  final String title;
  final int count;
  final String emptyMessage;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;

    return FloatingCard(
      key: cardKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(title, style: text.titleMedium),
              const SizedBox(width: Insets.sm),
              if (rows.isNotEmpty)
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
                    '$count',
                    style: text.labelMedium?.copyWith(color: palette.textMuted),
                  ),
                ),
            ],
          ),
          const SizedBox(height: Insets.sm),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Insets.lg),
              child: Row(
                children: [
                  Icon(
                    Icons.inbox_outlined,
                    size: 18,
                    color: palette.textFaint,
                  ),
                  const SizedBox(width: Insets.sm),
                  Text(
                    emptyMessage,
                    style: text.bodyMedium?.copyWith(color: palette.textMuted),
                  ),
                ],
              ),
            )
          else
            for (final (index, row) in rows.indexed) ...[
              if (index > 0) const Divider(height: 1),
              row,
            ],
        ],
      ),
    );
  }
}

/// One corte already taken in.
class _SettlementRow extends StatelessWidget {
  const _SettlementRow({required this.corte});

  final CashSettlement corte;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.md),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: palette.successTint,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.receipt_long_outlined,
              size: 18,
              color: palette.success,
            ),
          ),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  corte.driverName.isEmpty ? 'Chofer' : corte.driverName,
                  style: text.titleSmall,
                ),
                Text(
                  [
                    if (corte.createdAt != null)
                      DoTime.dateAndTime(corte.createdAt!),
                    if (corte.serviceCount == 1)
                      '1 servicio'
                    else
                      '${corte.serviceCount} servicios',
                    if (corte.note.isNotEmpty) corte.note,
                  ].join(' · '),
                  style: text.bodySmall?.copyWith(color: palette.textMuted),
                ),
              ],
            ),
          ),
          Text(corte.amountLabel, style: text.titleSmall),
        ],
      ),
    );
  }
}

class _DriverCashRow extends StatelessWidget {
  const _DriverCashRow({required this.driver});

  final Driver driver;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.md),
      child: Row(
        children: [
          DriverAvatar.of(driver),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(driver.name, style: text.titleSmall),
                Text(
                  driver.lastCashSettlementAt == null
                      ? 'Sin cortes anteriores'
                      : 'Último corte: '
                            '${DoTime.dateAndTime(driver.lastCashSettlementAt!)}',
                  style: text.bodySmall?.copyWith(color: palette.textMuted),
                ),
              ],
            ),
          ),
          // A fixed column so the figures line up under each other rather than
          // ending wherever the name left off.
          SizedBox(
            width: 150,
            child: Text(
              driver.cashOnHandCents.formatDOP,
              textAlign: TextAlign.right,
              style: text.titleMedium,
            ),
          ),
          const SizedBox(width: Insets.lg),
          // Outlined, not filled: one of these per chofer, and a column of
          // solid red buttons reads as a page full of warnings.
          OutlinedButton.icon(
            key: Key('settle-${driver.id}'),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => _SettleDialog(driver: driver),
            ),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 40),
              padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
            ),
            icon: const Icon(Icons.point_of_sale_outlined, size: 18),
            label: const Text('Hacer corte'),
          ),
        ],
      ),
    );
  }
}

/// The jobs a corte is made of, the total, and a note — then the corte.
class _SettleDialog extends ConsumerStatefulWidget {
  const _SettleDialog({required this.driver});

  final Driver driver;

  @override
  ConsumerState<_SettleDialog> createState() => _SettleDialogState();
}

class _SettleDialogState extends ConsumerState<_SettleDialog> {
  final _note = TextEditingController();
  var _saving = false;
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _settle() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await ref
        .read(functionsGatewayProvider)
        .settleDriverCash(driverId: widget.driver.id, note: _note.text.trim());
    if (!mounted) return;
    switch (result) {
      case Ok(:final value):
        final toast = Toaster.of(context);
        Navigator.of(context).pop();
        toast.show(
          'Corte registrado: ${value.formatDOP} de ${widget.driver.shortName}.',
        );
      case Err(:final failure):
        setState(() {
          _saving = false;
          _error = failure.userMessage;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final jobs = ref.watch(uncountedCashProvider(widget.driver.id)).value;
    final total = jobs?.fold(0, (sum, s) => sum + s.payment.capturedCents) ?? 0;

    return AlertDialog(
      title: Text('Corte de ${widget.driver.shortName}'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (jobs == null)
              const SizedBox(height: 120, child: BrandLoader())
            else if (jobs.isEmpty)
              Text(
                'No hay servicios en efectivo pendientes de entregar.',
                style: text.bodyMedium?.copyWith(color: palette.textMuted),
              )
            else ...[
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final job in jobs)
                      DetailRow(
                        label: [
                          job.code,
                          if (job.payment.cashCollectedAt != null)
                            DoTime.dateAndTime(job.payment.cashCollectedAt!),
                        ].join(' · '),
                        value: job.payment.capturedCents.formatDOP,
                      ),
                  ],
                ),
              ),
              const Divider(),
              DetailRow(
                label: 'Total a recibir',
                value: total.formatDOP,
                emphasise: true,
              ),
              const SizedBox(height: Insets.md),
              TextField(
                controller: _note,
                maxLength: 300,
                decoration: const InputDecoration(
                  labelText: 'Nota (opcional)',
                  hintText: 'Ej.: Entregado en oficina, recibo #123',
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: Insets.md),
              InlineNotice(tone: NoticeTone.error, message: _error!),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          key: const Key('confirm-settle'),
          onPressed: _saving || (jobs?.isEmpty ?? true) ? null : _settle,
          style: ElevatedButton.styleFrom(minimumSize: const Size(160, 44)),
          child: _saving
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: BrandColors.white,
                  ),
                )
              : Text('Recibí ${total.formatDOP}'),
        ),
      ],
    );
  }
}
