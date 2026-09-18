import 'package:flutter/foundation.dart';

import '../enums.dart';
import 'service.dart';

/// What a tow will cost an insurance company, before it is ordered: the answer
/// to `quoteInsurerService`.
///
/// Never carries the chofer's share. [signature] lets the order bill exactly
/// the distance this was priced on.
@immutable
class InsurerQuote {
  const InsurerQuote({
    required this.subtotalCents,
    required this.itbisCents,
    required this.totalCents,
    required this.distanceKm,
    required this.expiresAt,
    required this.signature,
    this.vehicleClass = VehicleClass.unknown,
    this.zoneMinKm = 0,
    this.zoneMaxKm,
    this.baseCents = 0,
    this.extraKm = 0,
    this.extraCents = 0,
    this.negotiated = false,
    this.durationSeconds = 0,
    this.polyline = '',
  });

  factory InsurerQuote.fromJson(Map<String, dynamic> json) {
    final price = Map<String, dynamic>.from(json['price'] as Map? ?? const {});
    final route = Map<String, dynamic>.from(json['route'] as Map? ?? const {});
    final priced = Map<String, dynamic>.from(json['priced'] as Map? ?? const {});
    int cents(Object? v) => (v as num? ?? 0).round();
    return InsurerQuote(
      subtotalCents: cents(price['subtotalCents']),
      itbisCents: cents(price['itbisCents']),
      totalCents: cents(price['totalCents']),
      vehicleClass: VehicleClass.fromWire(price['vehicleClass'] as String?),
      zoneMinKm: cents(price['zoneMinKm']),
      zoneMaxKm: (price['zoneMaxKm'] as num?)?.round(),
      baseCents: cents(price['baseCents']),
      extraKm: (price['extraKm'] as num? ?? 0).toDouble(),
      extraCents: cents(price['extraCents']),
      negotiated: price['tariff'] == 'insurer',
      distanceKm: (priced['distanceKm'] as num? ?? 0).toDouble(),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        cents(priced['expiresAtMs']),
        isUtc: true,
      ),
      signature: priced['signature'] as String? ?? '',
      durationSeconds: cents(route['durationSeconds']),
      polyline: route['polyline'] as String? ?? '',
    );
  }

  final int subtotalCents;
  final int itbisCents;
  final int totalCents;
  final VehicleClass vehicleClass;
  final int zoneMinKm;
  final int? zoneMaxKm;
  final int baseCents;
  final double extraKm;
  final int extraCents;

  /// Priced on the company's own table rather than the base one.
  final bool negotiated;

  /// The road distance the price was worked out on.
  final double distanceKm;
  final DateTime expiresAt;
  final String signature;
  final int durationSeconds;
  final String polyline;

  /// `0–10 km`, or `+50 km`.
  String get zoneLabel =>
      zoneMaxKm == null ? '+$zoneMinKm km' : '$zoneMinKm–$zoneMaxKm km';

  bool isExpiredAt(DateTime now) => !now.isBefore(expiresAt);

  /// What the order sends back so the server bills this distance.
  Map<String, Object?> get priced => {
        'distanceKm': distanceKm,
        'expiresAtMs': expiresAt.millisecondsSinceEpoch,
        'signature': signature,
      };
}

/// A tow an insurance company is ordering: the form in the portal.
@immutable
class InsurerServiceRequest {
  const InsurerServiceRequest({
    required this.claimNumber,
    required this.pickup,
    required this.dropoff,
    required this.vehicleType,
    this.policyNumber = '',
    this.insuredName = '',
    this.insuredPhone = '',
    this.plate = '',
    this.make = '',
    this.model = '',
    this.color = '',
    this.notes = '',
  });

  final String claimNumber;
  final ServiceLocation pickup;
  final ServiceLocation dropoff;
  final VehicleType vehicleType;
  final String policyNumber;
  final String insuredName;
  final String insuredPhone;
  final String plate;
  final String make;
  final String model;
  final String color;
  final String notes;

  Map<String, Object?> toJson({InsurerQuote? priced}) => {
        'pickup': pickup.toJson(),
        'dropoff': dropoff.toJson(),
        'vehicle': {
          'type': vehicleType.wire,
          'plate': plate.trim(),
          'make': make.trim(),
          'model': model.trim(),
          'color': color.trim(),
        },
        'insurance': {
          'claimNumber': claimNumber.trim(),
          'policyNumber': policyNumber.trim(),
          'insuredName': insuredName.trim(),
          'insuredPhone': insuredPhone.trim(),
        },
        'notes': notes.trim(),
        if (priced != null) 'priced': priced.priced,
      };
}

/// The tow the server made.
@immutable
class CreatedInsurerService {
  const CreatedInsurerService({
    required this.serviceId,
    required this.code,
    this.totalCents = 0,
  });

  final String serviceId;
  final String code;
  final int totalCents;
}
