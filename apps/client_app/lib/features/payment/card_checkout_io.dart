import 'package:flutter/widgets.dart';
import 'package:flutter_stripe/flutter_stripe.dart' as stripe;
import 'package:grua_core/grua_core.dart';

import 'card_checkout.dart';

var _initialised = false;

/// Stripe is set up the first time somebody pays, not at launch: a missing
/// key then fails one checkout with a message, rather than the whole app.
Future<void> _ensureStripe(AppConfig config) async {
  if (_initialised) return;
  final key = config.stripePublishableKey.trim();
  if (key.isEmpty) {
    throw const CheckoutError(
      'El pago con tarjeta no está configurado en esta app. Puedes pagar en efectivo.',
    );
  }
  stripe.Stripe.publishableKey = key;
  stripe.Stripe.merchantIdentifier = 'merchant.com.gruasrd247';
  stripe.Stripe.urlScheme = 'gruasrd';
  await stripe.Stripe.instance.applySettings();
  _initialised = true;
}

/// Android and iOS: Stripe's payment sheet.
Future<CheckoutOutcome> presentCardCheckout(
  BuildContext context,
  PreparedPayment payment,
  AppConfig config,
) async {
  await _ensureStripe(config);

  try {
    await stripe.Stripe.instance.initPaymentSheet(
      paymentSheetParameters: stripe.SetupPaymentSheetParameters(
        paymentIntentClientSecret: payment.clientSecret,
        customerId: payment.customerId.isEmpty ? null : payment.customerId,
        customerSessionClientSecret: payment.customerSessionClientSecret,
        merchantDisplayName: merchantDisplayName,
        returnURL: 'gruasrd://stripe-redirect',
        applePay: const stripe.PaymentSheetApplePay(
          merchantCountryCode: merchantCountryCode,
        ),
        googlePay: stripe.PaymentSheetGooglePay(
          merchantCountryCode: merchantCountryCode,
          currencyCode: 'DOP',
          testEnv: payment.testMode,
        ),
        appearance: const stripe.PaymentSheetAppearance(
          colors: stripe.PaymentSheetAppearanceColors(primary: BrandColors.red),
        ),
      ),
    );
    await stripe.Stripe.instance.presentPaymentSheet();
    return CheckoutOutcome.completed;
  } on stripe.StripeException catch (error) {
    if (error.error.code == stripe.FailureCode.Canceled) {
      return CheckoutOutcome.cancelled;
    }
    throw CheckoutError(
      error.error.localizedMessage ??
          error.error.message ??
          'No pudimos completar el pago. Prueba con otra tarjeta.',
    );
  }
}
