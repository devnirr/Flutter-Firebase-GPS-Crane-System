import 'package:flutter/material.dart';
import 'package:grua_core/grua_core.dart';

/// What the customer owes and how they hand it over, once the chofer is at
/// the curb.
///
/// There is nothing to choose: every tow is paid in cash to the chofer when it
/// ends. The card is here so the amount is on screen before the vehicle is
/// loaded, rather than being a surprise at the destination.
class PaymentChoiceCard extends StatelessWidget {
  const PaymentChoiceCard({required this.service, super.key});

  final Service service;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final paid = service.payment.isPaid;

    return FloatingCard(
      key: const Key('payment-choice'),
      child: Row(
        children: [
          Icon(
            paid ? Icons.verified_outlined : Icons.payments_outlined,
            color: paid ? BrandColors.success : BrandColors.red,
          ),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  paid ? 'Pagado' : 'Pagarás en efectivo',
                  style: text.titleSmall,
                ),
                const SizedBox(height: 2),
                Text(
                  paid
                      ? service.payment.status.label
                      : 'Entrégale ${service.totalCents.formatDOP} al chofer '
                          'al terminar.',
                  style: text.bodySmall?.copyWith(color: BrandColors.grey600),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
