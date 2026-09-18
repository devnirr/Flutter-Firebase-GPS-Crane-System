import 'package:flutter/foundation.dart';

import '../../data/converters.dart';
import '../enums.dart';

/// An insurance company that orders tows for its policyholders and is billed
/// for them monthly, at `insurers/{id}`.
///
/// Written only by the insurer callables, so this has no `toJson`.
@immutable
class Insurer {
  const Insurer({
    required this.id,
    required this.name,
    this.rnc = '',
    this.contactName = '',
    this.contactEmail = '',
    this.contactPhone = '',
    this.billingEmail = '',
    this.status = InsurerStatus.unknown,
    this.statusReason = '',
    this.driverPayoutBps,
    this.createdAt,
    this.updatedAt,
  });

  factory Insurer.fromJson(String id, Map<String, dynamic> json) => Insurer(
        id: id,
        name: json['name'] as String? ?? '',
        rnc: json['rnc'] as String? ?? '',
        contactName: json['contactName'] as String? ?? '',
        contactEmail: json['contactEmail'] as String? ?? '',
        contactPhone: json['contactPhone'] as String? ?? '',
        billingEmail: json['billingEmail'] as String? ?? '',
        status: InsurerStatus.fromWire(json['status'] as String?),
        statusReason: json['statusReason'] as String? ?? '',
        driverPayoutBps: (json['driverPayoutBps'] as num?)?.round(),
        createdAt: const NullableTimestampConverter().fromJson(json['createdAt']),
        updatedAt: const NullableTimestampConverter().fromJson(json['updatedAt']),
      );

  final String id;
  final String name;

  /// Nine digits, no dashes. See [rncLabel] for display.
  final String rnc;
  final String contactName;
  final String contactEmail;
  final String contactPhone;

  /// Where the monthly invoice goes.
  final String billingEmail;
  final InsurerStatus status;

  /// Why the office suspended the company. Empty while it is active.
  final String statusReason;

  /// The chofer's share of this company's tows, in basis points. `null` for
  /// the default 70%.
  final int? driverPayoutBps;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isActive => status.isActive;

  /// The share actually paid: the company's own, or the default.
  int get effectiveDriverPayoutBps => driverPayoutBps ?? 7000;

  /// `70%`, or `65.5%`.
  String get driverPayoutLabel {
    final bps = effectiveDriverPayoutBps;
    return bps % 100 == 0 ? '${bps ~/ 100}%' : '${(bps / 100).toStringAsFixed(1)}%';
  }

  /// The RNC as the DGII prints it: `1-30-00000-1`.
  String get rncLabel => rnc.length == 9
      ? '${rnc.substring(0, 1)}-${rnc.substring(1, 3)}-'
          '${rnc.substring(3, 8)}-${rnc.substring(8)}'
      : rnc;
}

/// A person who works for an insurance company, at
/// `insurers/{insurerId}/members/{uid}`.
///
/// This record, not the sign-in token, decides whether the person may still
/// act and with which role.
@immutable
class InsurerMember {
  const InsurerMember({
    required this.insurerId,
    required this.uid,
    required this.name,
    this.email = '',
    this.phone = '',
    this.role = InsurerRole.unknown,
    this.active = false,
    this.mustChangePassword = false,
    this.createdBy = '',
    this.createdAt,
  });

  factory InsurerMember.fromJson(
    String insurerId,
    String uid,
    Map<String, dynamic> json,
  ) =>
      InsurerMember(
        insurerId: insurerId,
        uid: uid,
        name: json['name'] as String? ?? '',
        email: json['email'] as String? ?? '',
        phone: json['phone'] as String? ?? '',
        role: InsurerRole.fromWire(json['insurerRole'] as String?),
        // Anything but an explicit true is not allowed in: a record with the
        // field missing is a record nobody finished writing.
        active: json['active'] == true,
        mustChangePassword: json['mustChangePassword'] == true,
        createdBy: json['createdBy'] as String? ?? '',
        createdAt: const NullableTimestampConverter().fromJson(json['createdAt']),
      );

  final String insurerId;
  final String uid;
  final String name;
  final String email;
  final String phone;
  final InsurerRole role;
  final bool active;

  /// Set on an account opened with a first password somebody else chose.
  final bool mustChangePassword;
  final String createdBy;
  final DateTime? createdAt;

  bool get canManageMembers => active && role.canManageMembers;
}

/// What the office types about an insurance company.
@immutable
class InsurerDetails {
  const InsurerDetails({
    required this.name,
    required this.rnc,
    required this.billingEmail,
    this.contactName = '',
    this.contactEmail = '',
    this.contactPhone = '',
  });

  factory InsurerDetails.of(Insurer insurer) => InsurerDetails(
        name: insurer.name,
        rnc: insurer.rnc,
        billingEmail: insurer.billingEmail,
        contactName: insurer.contactName,
        contactEmail: insurer.contactEmail,
        contactPhone: insurer.contactPhone,
      );

  final String name;
  final String rnc;
  final String billingEmail;
  final String contactName;
  final String contactEmail;
  final String contactPhone;

  Map<String, Object?> toJson() => {
        'name': name.trim(),
        'rnc': rnc.trim(),
        'billingEmail': billingEmail.trim(),
        'contactName': contactName.trim(),
        'contactEmail': contactEmail.trim(),
        'contactPhone': contactPhone.trim(),
      };
}

/// A person just added to an insurance company, with the first password the
/// office hands them. Shown once.
@immutable
class NewInsurerUser {
  const NewInsurerUser({required this.uid, required this.temporaryPassword});

  final String uid;
  final String temporaryPassword;
}
