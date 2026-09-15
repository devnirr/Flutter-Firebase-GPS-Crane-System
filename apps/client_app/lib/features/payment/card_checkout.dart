import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

import 'card_checkout_io.dart'
    if (dart.library.js_interop) 'card_checkout_web.dart' as platform;

/// How the customer's card is held for a job: Stripe's own payment screen,
/// never a form of ours — no card number ever touches this app's code.
///
/// Android and iOS show Stripe's payment sheet (card, Google Pay, Apple Pay,
/// and the cards already saved to the customer). The browser shows Stripe's
/// Payment Element in a dialog, with the wallets the browser supports.
enum CheckoutOutcome {
  /// Stripe accepted the card. The hold may still be settling; the service
  /// document says when it is in place.
  completed,

  /// The customer closed the checkout without paying.
  cancelled,
}

/// A checkout that could not finish, in words for the customer.
class CheckoutError implements Exception {
  const CheckoutError(this.message);

  final String message;

  @override
  String toString() => message;
}

typedef CardCheckout = Future<CheckoutOutcome> Function(
  BuildContext context,
  PreparedPayment payment,
);

/// The real checkout by default; tests put a fake in its place.
final cardCheckoutProvider = Provider<CardCheckout>((ref) {
  final config = ref.watch(appConfigProvider);
  return (context, payment) =>
      platform.presentCardCheckout(context, payment, config);
});

/// The name on the customer's statement and in the checkout.
const merchantDisplayName = 'GRUAS RD 24/7 SRL';

/// The country of the Stripe account, which Apple Pay and Google Pay require.
/// Set at build time with `--dart-define=STRIPE_MERCHANT_COUNTRY=..` to the
/// country the company's Stripe account is registered in.
const merchantCountryCode =
    String.fromEnvironment('STRIPE_MERCHANT_COUNTRY', defaultValue: 'US');
