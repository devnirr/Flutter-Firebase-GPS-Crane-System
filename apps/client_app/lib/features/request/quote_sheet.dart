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
    final heavy = quote.quote.heavy;

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

            // The one line the customer reads before confirming, in the words
            // the owner asked for.
            Text(
              'Distancia: ${Quote.formatKm(quote.quote.distanceKm)}km | '
              'Total estimado: ${quote.quote.totalCents.formatDOPShort}',
              key: const Key('quote-summary'),
              style: text.titleMedium,
            ),
            const SizedBox(height: Insets.sm),
            // A Wrap: a heavy job's five-figure total in display type does not
            // fit beside the time on a narrow phone.
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.end,
              spacing: Insets.sm,
              children: [
                Text(
                  quote.quote.totalCents.formatDOP,
                  style: text.displaySmall?.copyWith(color: BrandColors.red),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    quote.route.durationLabel,
                    style: text.bodyMedium?.copyWith(color: BrandColors.grey600),
                  ),
                ),
              ],
            ),
            if (heavy) ...[
              const SizedBox(height: Insets.md),
              const InlineNotice(
                key: Key('quote-heavy-notice'),
                message: heavyServiceNotice,
                icon: Icons.warning_amber_rounded,
                tone: NoticeTone.warning,
              ),
            ],

            const SizedBox(height: Insets.lg),
            const Divider(),
            for (final line in quote.quote.breakdown)
              DetailRow(label: line.label, value: line.cents.formatDOP),
            const Divider(),
            DetailRow(
              label: 'Total estimado',
              value: quote.quote.totalCents.formatDOP,
              emphasise: true,
            ),

            const SizedBox(height: Insets.lg),
            // Chosen at the curb, not here: the price can still change on the
            // way, and a card is only held once a grúa is there.
            const InlineNotice(
              key: Key('quote-payment-later'),
              icon: Icons.credit_card,
              message: 'Pagas cuando llegue el chofer: con tarjeta (Apple Pay, '
                  'Google Pay) o en efectivo.',
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
                  // A heavy request asks the operator; nobody is sent yet.
                  : Text(heavy ? 'ENVIAR SOLICITUD' : 'CONFIRMAR Y PEDIR GRÚA'),
            ),
            const SizedBox(height: Insets.sm),
            Text(
              heavy
                  ? 'El operador te confirmará el precio final antes de enviar '
                      'la grúa.'
                  : 'El precio final puede variar si hay tiempo de espera o '
                      'cambia el destino.',
              textAlign: TextAlign.center,
              style: text.bodySmall?.copyWith(color: BrandColors.grey600),
            ),
          ],
        ),
      ),
    );
  }
}
