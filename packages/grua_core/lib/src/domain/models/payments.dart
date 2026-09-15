import 'package:flutter/foundation.dart';

import '../../data/converters.dart';
import '../../utils/money.dart';

/// What the checkout needs to hold the customer's card for a job, from
/// `preparePayment`.
@immutable
class PreparedPayment {
  const PreparedPayment({
    this.alreadyAuthorized = false,
    this.clientSecret = '',
    this.customerId = '',
    this.customerSessionClientSecret,
    this.amountCents = 0,
    this.quoteCents = 0,
    this.testMode = false,
  });

  factory PreparedPayment.fromJson(Map<String, dynamic> json) => PreparedPayment(
        alreadyAuthorized: json['alreadyAuthorized'] == true,
        clientSecret: json['clientSecret'] as String? ?? '',
        customerId: json['customerId'] as String? ?? '',
        customerSessionClientSecret: json['customerSessionClientSecret'] as String?,
        amountCents: (json['amountCents'] as num? ?? 0).round(),
        quoteCents: (json['quoteCents'] as num? ?? 0).round(),
        testMode: json['testMode'] == true,
      );

  /// The card is already held — the customer paid a moment ago on another
  /// screen. Nothing to show.
  final bool alreadyAuthorized;

  /// The PaymentIntent's secret. Only good for confirming this one intent.
  final String clientSecret;
  final String customerId;

  /// Lets the checkout list the customer's saved cards. Null shows none.
  final String? customerSessionClientSecret;

  /// What is held: the quote plus headroom for waiting. The final price is
  /// charged from it when the job ends.
  final int amountCents;
  final int quoteCents;

  /// Stripe test keys: no real money moves, and the screen says so.
  final bool testMode;
}

/// A corte: cash a chofer handed to the office, at `cashSettlements/{id}`.
@immutable
class CashSettlement {
  const CashSettlement({
    required this.id,
    required this.driverId,
    this.driverName = '',
    this.amountCents = 0,
    this.serviceCount = 0,
    this.note = '',
    this.settledBy = '',
    this.createdAt,
  });

  factory CashSettlement.fromJson(String id, Map<String, dynamic> json) =>
      CashSettlement(
        id: id,
        driverId: json['driverId'] as String? ?? '',
        driverName: json['driverName'] as String? ?? '',
        amountCents: (json['amountCents'] as num? ?? 0).round(),
        serviceCount: (json['serviceCount'] as num? ?? 0).round(),
        note: json['note'] as String? ?? '',
        settledBy: json['settledBy'] as String? ?? '',
        createdAt: const NullableTimestampConverter().fromJson(json['createdAt']),
      );

  final String id;
  final String driverId;
  final String driverName;
  final int amountCents;
  final int serviceCount;
  final String note;

  /// The staff member who received the cash.
  final String settledBy;
  final DateTime? createdAt;

  String get amountLabel => amountCents.formatDOP;
}
