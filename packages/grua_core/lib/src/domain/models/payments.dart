import 'package:flutter/foundation.dart';

import '../../data/converters.dart';
import '../../utils/money.dart';

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
