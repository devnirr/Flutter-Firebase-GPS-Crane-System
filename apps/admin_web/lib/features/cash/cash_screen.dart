import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

/// Efectivo: what each chofer collected in cash and still holds for the
/// company, and the cortes that brought it in.
///
/// Card money lands in the company's Stripe account on its own. Cash does not:
/// the customer hands it to the chofer, the chofer marks "Cobrado en efectivo",
/// and it sits with them until the office receives it here. A corte counts
/// every such job at once and marks them, so none is ever counted twice.
class CashScreen extends ConsumerWidget {
  const CashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final drivers = ref.watch(allDriversProvider).value ?? const <Driver>[];
    final settlements = ref.watch(cashSettlementsProvider).value ?? const [];

    final holding = drivers.where((d) => d.cashOnHandCents > 0).toList()
      ..sort((a, b) => b.cashOnHandCents.compareTo(a.cashOnHandCents));
    final total = holding.fold(0, (sum, d) => sum + d.cashOnHandCents);

    return ListView(
      padding: const EdgeInsets.all(Insets.xl),
      children: [
        Text('Efectivo', style: text.headlineSmall),
        const SizedBox(height: Insets.xs),
        Text(
          'Lo que los choferes cobraron en efectivo y todavía no han entregado. '
          'Los pagos con tarjeta llegan directo a la cuenta de Stripe.',
          style: text.bodyMedium?.copyWith(color: BrandColors.grey600),
        ),
        const SizedBox(height: Insets.xl),
        Wrap(
          spacing: Insets.lg,
          runSpacing: Insets.lg,
          children: [
            _Kpi(
              label: 'Efectivo por entregar',
              value: total.formatDOP,
              accent: total > 0,
            ),
            _Kpi(label: 'Choferes con efectivo', value: '${holding.length}'),
          ],
        ),
        const SizedBox(height: Insets.xl),
        FloatingCard(
          key: const Key('cash-by-driver'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Por chofer', style: text.titleMedium),
              const SizedBox(height: Insets.md),
              if (holding.isEmpty)
                Text(
                  'Ningún chofer tiene efectivo por entregar.',
                  style: text.bodyMedium?.copyWith(color: BrandColors.grey600),
                )
              else
                for (final driver in holding) _DriverCashRow(driver: driver),
            ],
          ),
        ),
        const SizedBox(height: Insets.xl),
        FloatingCard(
          key: const Key('cash-settlements'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Cortes realizados', style: text.titleMedium),
              const SizedBox(height: Insets.md),
              if (settlements.isEmpty)
                Text(
                  'Todavía no hay cortes.',
                  style: text.bodyMedium?.copyWith(color: BrandColors.grey600),
                )
              else
                for (final corte in settlements)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.receipt_long_outlined),
                    title: Text(corte.driverName.isEmpty ? 'Chofer' : corte.driverName),
                    subtitle: Text(
                      [
                        if (corte.createdAt != null) DoTime.dateAndTime(corte.createdAt!),
                        '${corte.serviceCount} servicio${corte.serviceCount == 1 ? '' : 's'}',
                        if (corte.note.isNotEmpty) corte.note,
                      ].join(' · '),
                    ),
                    trailing: Text(corte.amountLabel, style: text.titleSmall),
                  ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DriverCashRow extends StatelessWidget {
  const _DriverCashRow({required this.driver});

  final Driver driver;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.sm),
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
                      : 'Último corte: ${DoTime.dateAndTime(driver.lastCashSettlementAt!)}',
                  style: text.bodySmall?.copyWith(color: BrandColors.grey600),
                ),
              ],
            ),
          ),
          Text(driver.cashOnHandCents.formatDOP, style: text.titleMedium),
          const SizedBox(width: Insets.lg),
          ElevatedButton(
            key: Key('settle-${driver.id}'),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => _SettleDialog(driver: driver),
            ),
            style: ElevatedButton.styleFrom(minimumSize: const Size(0, 40)),
            child: const Text('Hacer corte'),
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
    final result = await ref.read(functionsGatewayProvider).settleDriverCash(
          driverId: widget.driver.id,
          note: _note.text.trim(),
        );
    if (!mounted) return;
    switch (result) {
      case Ok(:final value):
        final messenger = ScaffoldMessenger.of(context);
        Navigator.of(context).pop();
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Corte registrado: ${value.formatDOP} de ${widget.driver.shortName}.',
            ),
          ),
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
                style: text.bodyMedium?.copyWith(color: BrandColors.grey600),
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

class _Kpi extends StatelessWidget {
  const _Kpi({required this.label, required this.value, this.accent = false});

  final String label;
  final String value;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SizedBox(
      width: 260,
      child: FloatingCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FieldLabel(label),
            const SizedBox(height: Insets.sm),
            Text(
              value,
              style: text.headlineMedium?.copyWith(
                color: accent ? BrandColors.red : BrandColors.ink,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
