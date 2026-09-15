import 'package:flutter/material.dart';
import 'package:flutter_stripe_web/flutter_stripe_web.dart';
import 'package:grua_core/grua_core.dart' hide PaymentMethod;

import 'card_checkout.dart';

var _initialised = false;

Future<void> _ensureStripe(AppConfig config) async {
  if (_initialised) return;
  final key = config.stripePublishableKey.trim();
  if (key.isEmpty) {
    throw const CheckoutError(
      'El pago con tarjeta no está configurado en esta app. Puedes pagar en efectivo.',
    );
  }
  // Loads Stripe.js from Stripe itself, as their terms require.
  await WebStripe.instance.initialise(publishableKey: key);
  _initialised = true;
}

/// The browser: Stripe's Payment Element, in a dialog.
Future<CheckoutOutcome> presentCardCheckout(
  BuildContext context,
  PreparedPayment payment,
  AppConfig config,
) async {
  await _ensureStripe(config);
  if (!context.mounted) return CheckoutOutcome.cancelled;

  final outcome = await showDialog<CheckoutOutcome>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _WebCheckoutDialog(payment: payment),
  );
  return outcome ?? CheckoutOutcome.cancelled;
}

class _WebCheckoutDialog extends StatefulWidget {
  const _WebCheckoutDialog({required this.payment});

  final PreparedPayment payment;

  @override
  State<_WebCheckoutDialog> createState() => _WebCheckoutDialogState();
}

class _WebCheckoutDialogState extends State<_WebCheckoutDialog> {
  var _complete = false;
  var _paying = false;
  String? _error;

  Future<void> _pay() async {
    setState(() {
      _paying = true;
      _error = null;
    });
    try {
      await WebStripe.instance.confirmPaymentElement(
        ConfirmPaymentElementOptions(
          // Only bank-redirect methods leave the page; a card answers here.
          confirmParams: ConfirmPaymentParams(return_url: Uri.base.toString()),
          redirect: PaymentConfirmationRedirect.ifRequired,
        ),
      );
      if (mounted) Navigator.of(context).pop(CheckoutOutcome.completed);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _paying = false;
        _error = _messageOf(error);
      });
    }
  }

  static String _messageOf(Object error) {
    try {
      final message = (error as dynamic).message as String?;
      if (message != null && message.isNotEmpty) return message;
    } on Object {
      // Not a Stripe error with a message; fall through.
    }
    return 'No pudimos completar el pago. Prueba con otra tarjeta.';
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final payment = widget.payment;

    return AlertDialog(
      title: const Text('Pagar con tarjeta'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (payment.testMode) ...[
                const InlineNotice(
                  tone: NoticeTone.warning,
                  icon: Icons.science_outlined,
                  message: 'Modo de prueba: usa la tarjeta 4242 4242 4242 4242.',
                ),
                const SizedBox(height: Insets.md),
              ],
              Text(
                'Retenemos ${payment.amountCents.formatDOP} en tu tarjeta. Al '
                'terminar cobramos solo el total final y liberamos el resto.',
                style: text.bodyMedium?.copyWith(color: BrandColors.grey800),
              ),
              const SizedBox(height: Insets.lg),
              PaymentElement(
                clientSecret: payment.clientSecret,
                customerSessionClientSecret: payment.customerSessionClientSecret,
                layout: PaymentElementLayout.tabs,
                onCardChanged: (details) =>
                    setState(() => _complete = details?.complete ?? false),
              ),
              if (_error != null) ...[
                const SizedBox(height: Insets.md),
                InlineNotice(tone: NoticeTone.error, message: _error!),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _paying
              ? null
              : () => Navigator.of(context).pop(CheckoutOutcome.cancelled),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          key: const Key('web-checkout-pay'),
          onPressed: _complete && !_paying ? _pay : null,
          style: ElevatedButton.styleFrom(minimumSize: const Size(140, 44)),
          child: _paying
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: BrandColors.white,
                  ),
                )
              : const Text('Confirmar tarjeta'),
        ),
      ],
    );
  }
}
