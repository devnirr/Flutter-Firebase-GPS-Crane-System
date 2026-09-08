import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

import 'request_controller.dart';

/// The price, before the customer commits.
///
/// Every line of the breakdown is shown, including the surcharges, because the
/// alternative is a customer discovering a nocturno charge on the invoice after
/// the tow. The button is disabled the moment the quote goes stale.
class QuoteSheet extends ConsumerStatefulWidget {
  const QuoteSheet({super.key});

  @override
  ConsumerState<QuoteSheet> createState() => _QuoteSheetState();
}

class _QuoteSheetState extends ConsumerState<QuoteSheet> {
  Future<void> _confirm() async {
    final serviceId =
        await ref.read(requestControllerProvider.notifier).submit();
    if (!mounted) return;
    if (serviceId != null) Navigator.of(context).pop(serviceId);
  }

  @override
  Widget build(BuildContext context) {
    final draft = ref.watch(requestControllerProvider);
    final quote = draft.quote;
    final text = Theme.of(context).textTheme;

    if (quote == null) {
      return const BottomActionSheet(
        child: SizedBox(height: 160, child: BrandLoader(message: 'Calculando…')),
      );
    }

    final stale = quote.isStale(DateTime.now().toUtc());

    return BottomActionSheet(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text('Precio estimado', style: text.headlineSmall)),
                Chip(
                  label: Text(quote.truckType.label),
                  backgroundColor: BrandColors.redTint,
                  labelStyle: text.labelMedium?.copyWith(
                    color: BrandColors.redDeep,
                  ),
                ),
              ],
            ),
            const SizedBox(height: Insets.lg),

            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  quote.quote.totalCents.formatDOP,
                  style: text.displaySmall?.copyWith(color: BrandColors.red),
                ),
                const SizedBox(width: Insets.sm),
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    '${quote.route.distanceLabel} · ${quote.route.durationLabel}',
                    style: text.bodyMedium?.copyWith(color: BrandColors.grey600),
                  ),
                ),
              ],
            ),

            const SizedBox(height: Insets.lg),
            const Divider(),
            for (final line in quote.quote.breakdown)
              DetailRow(label: line.label, value: line.cents.formatDOP),
            const Divider(),
            DetailRow(
              label: 'Total',
              value: quote.quote.totalCents.formatDOP,
              emphasise: true,
            ),

            const SizedBox(height: Insets.lg),
            const FieldLabel('Forma de pago'),
            const SizedBox(height: Insets.sm),
            _PaymentPicker(
              selected: draft.paymentMethod,
              onChanged: ref
                  .read(requestControllerProvider.notifier)
                  .setPaymentMethod,
            ),

            if (stale) ...[
              const SizedBox(height: Insets.lg),
              InlineNotice(
                message: 'Este precio venció. Vamos a calcularlo de nuevo.',
                actionLabel: 'Recalcular',
                onAction: () => ref
                    .read(requestControllerProvider.notifier)
                    .requestQuote(),
              ),
            ],

            if (draft.failure != null) ...[
              const SizedBox(height: Insets.lg),
              InlineNotice(
                message: draft.failure!.userMessage,
                tone: NoticeTone.error,
              ),
            ],

            const SizedBox(height: Insets.xl),
            ElevatedButton(
              onPressed: (stale || draft.submitting) ? null : _confirm,
              child: draft.submitting
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: BrandColors.white,
                      ),
                    )
                  : const Text('CONFIRMAR Y PEDIR GRÚA'),
            ),
            const SizedBox(height: Insets.sm),
            Text(
              'El precio final puede variar si hay tiempo de espera o cambia '
              'el destino.',
              textAlign: TextAlign.center,
              style: text.bodySmall?.copyWith(color: BrandColors.grey600),
            ),
          ],
        ),
      ),
    );
  }
}

class _PaymentPicker extends StatelessWidget {
  const _PaymentPicker({required this.selected, required this.onChanged});

  final PaymentMethod selected;
  final ValueChanged<PaymentMethod> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _PaymentTile(
            icon: Icons.payments_outlined,
            label: 'Efectivo',
            selected: selected == PaymentMethod.cash,
            onTap: () => onChanged(PaymentMethod.cash),
          ),
        ),
        const SizedBox(width: Insets.md),
        Expanded(
          child: _PaymentTile(
            icon: Icons.credit_card,
            label: 'Tarjeta',
            selected: selected == PaymentMethod.card,
            onTap: () => onChanged(PaymentMethod.card),
          ),
        ),
      ],
    );
  }
}

class _PaymentTile extends StatelessWidget {
  const _PaymentTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: Corners.brMd,
      child: AnimatedContainer(
        duration: Motion.fast,
        padding: const EdgeInsets.symmetric(vertical: Insets.lg),
        decoration: BoxDecoration(
          color: selected ? BrandColors.redTint : BrandColors.grey100,
          borderRadius: Corners.brMd,
          border: Border.all(
            color: selected ? BrandColors.red : Colors.transparent,
            width: 1.4,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 20,
              color: selected ? BrandColors.red : BrandColors.grey800,
            ),
            const SizedBox(width: Insets.sm),
            Text(
              label,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: selected ? BrandColors.redDeep : BrandColors.grey800,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
