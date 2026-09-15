import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

import 'card_checkout.dart';

/// "¿Cómo vas a pagar?", once the chofer is at the curb.
///
/// Card holds the quote plus headroom now and charges the final price when
/// the tow ends; cash is handed to the chofer. Either can still be changed
/// until the vehicle is loaded.
class PaymentChoiceCard extends ConsumerStatefulWidget {
  const PaymentChoiceCard({required this.service, super.key});

  final Service service;

  @override
  ConsumerState<PaymentChoiceCard> createState() => _PaymentChoiceCardState();
}

class _PaymentChoiceCardState extends ConsumerState<PaymentChoiceCard> {
  PaymentMethod? _working;
  String? _error;

  Service get service => widget.service;

  Future<void> _payByCard() async {
    if (_working != null) return;
    setState(() {
      _working = PaymentMethod.card;
      _error = null;
    });
    final gateway = ref.read(functionsGatewayProvider);

    try {
      final prepared = await gateway.preparePayment(service.id);
      final payment = prepared.valueOrNull;
      if (payment == null) {
        _fail(prepared.failureOrNull?.userMessage);
        return;
      }
      if (!payment.alreadyAuthorized) {
        if (!mounted) return;
        final outcome = await ref.read(cardCheckoutProvider)(context, payment);
        if (outcome == CheckoutOutcome.cancelled) {
          if (mounted) setState(() => _working = null);
          return;
        }
        // Straight from Stripe rather than waiting on the webhook, so the
        // chofer's "Iniciar" unlocks the moment this closes.
        await gateway.syncPayment(service.id);
      }
      if (mounted) setState(() => _working = null);
    } on CheckoutError catch (error) {
      _fail(error.message);
    }
  }

  Future<void> _payInCash() async {
    if (_working != null) return;
    setState(() {
      _working = PaymentMethod.cash;
      _error = null;
    });
    final result = await ref
        .read(functionsGatewayProvider)
        .choosePaymentMethod(serviceId: service.id, method: PaymentMethod.cash);
    if (result case Err(:final failure)) {
      _fail(failure.userMessage);
      return;
    }
    if (mounted) setState(() => _working = null);
  }

  void _fail(String? message) {
    if (!mounted) return;
    setState(() {
      _working = null;
      _error = message ?? 'No pudimos procesar el pago. Intenta de nuevo.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final payment = service.payment;

    final (IconData icon, String title, String subtitle) = switch (payment) {
      _ when payment.isHeld => (
          Icons.verified_outlined,
          'Pagarás con ${payment.cardLabel}',
          'Tarjeta aprobada. Cobraremos el total final al terminar el servicio.',
        ),
      _ when payment.isCash => (
          Icons.payments_outlined,
          'Pagarás en efectivo',
          'Entrégale ${service.totalCents.formatDOP} al chofer al terminar.',
        ),
      _ when payment.status == PaymentStatus.failed => (
          Icons.error_outline,
          'La tarjeta no pasó',
          payment.failureMessage.isEmpty
              ? 'Prueba con otra tarjeta o paga en efectivo.'
              : payment.failureMessage,
        ),
      _ => (
          Icons.credit_card,
          '¿Cómo vas a pagar?',
          'Total estimado ${service.totalCents.formatDOP}. El chofer empieza '
              'cuando elijas.',
        ),
    };

    final chosen = payment.isHeld || payment.isCash;

    return FloatingCard(
      key: const Key('payment-choice'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                icon,
                color: chosen ? BrandColors.success : BrandColors.red,
              ),
              const SizedBox(width: Insets.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: text.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: text.bodySmall?.copyWith(color: BrandColors.grey600),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: Insets.md),
            InlineNotice(tone: NoticeTone.error, message: _error!),
          ],
          const SizedBox(height: Insets.md),
          if (!chosen)
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    key: const Key('pay-card'),
                    onPressed: _working == null ? _payByCard : null,
                    icon: _spinnerOr(PaymentMethod.card, Icons.credit_card),
                    label: const Text('Pagar con Tarjeta'),
                  ),
                ),
                const SizedBox(width: Insets.md),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('pay-cash'),
                    onPressed: _working == null ? _payInCash : null,
                    icon: _spinnerOr(PaymentMethod.cash, Icons.payments_outlined),
                    label: const Text('Pagar Efectivo'),
                  ),
                ),
              ],
            )
          else
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: const Key('pay-switch'),
                onPressed: _working != null
                    ? null
                    : payment.isCash
                        ? _payByCard
                        : _payInCash,
                icon: _working == null
                    ? const SizedBox.shrink()
                    : const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                label: Text(
                  payment.isCash ? 'Cambiar a tarjeta' : 'Cambiar a efectivo',
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _spinnerOr(PaymentMethod method, IconData icon) => _working == method
      ? const SizedBox.square(
          dimension: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        )
      : Icon(icon, size: 18);
}
