import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';

/// How the panel reads an insurance company and its people.
///
/// The records are written by the server, so the danger is on the reading
/// side: a missing or unexpected field must never turn into access.
void main() {
  group('UserRole.insurer', () {
    test('reads from the wire', () {
      expect(UserRole.fromWire('insurer'), UserRole.insurer);
    });

    test('may use the panel but is not office staff', () {
      expect(UserRole.insurer.canUsePanel, isTrue);
      expect(UserRole.insurer.isStaff, isFalse);
      expect(UserRole.insurer.isInsurer, isTrue);
    });

    test('customers and choferes still cannot use the panel', () {
      expect(UserRole.client.canUsePanel, isFalse);
      expect(UserRole.driver.canUsePanel, isFalse);
      expect(UserRole.unknown.canUsePanel, isFalse);
      expect(UserRole.admin.canUsePanel, isTrue);
      expect(UserRole.ops.canUsePanel, isTrue);
    });
  });

  group('InsurerRole', () {
    test('reads both roles and tolerates anything else', () {
      expect(InsurerRole.fromWire('manager'), InsurerRole.manager);
      expect(InsurerRole.fromWire('operator'), InsurerRole.operator);
      expect(InsurerRole.fromWire('admin'), InsurerRole.unknown);
      expect(InsurerRole.fromWire(null), InsurerRole.unknown);
    });

    test('only a manager manages people', () {
      expect(InsurerRole.manager.canManageMembers, isTrue);
      expect(InsurerRole.operator.canManageMembers, isFalse);
      expect(InsurerRole.unknown.canManageMembers, isFalse);
    });
  });

  group('Insurer.fromJson', () {
    test('reads a full record', () {
      final insurer = Insurer.fromJson('ins-1', {
        'name': 'Seguros Ejemplo, S.A.',
        'rnc': '130000001',
        'contactName': 'Marta Díaz',
        'contactEmail': 'marta@ejemplo.do',
        'contactPhone': '+18095550123',
        'billingEmail': 'facturas@ejemplo.do',
        'status': 'active',
        'statusReason': '',
        'createdAt': Timestamp.fromDate(DateTime.utc(2026, 9, 16, 12)),
      });

      expect(insurer.id, 'ins-1');
      expect(insurer.name, 'Seguros Ejemplo, S.A.');
      expect(insurer.billingEmail, 'facturas@ejemplo.do');
      expect(insurer.isActive, isTrue);
      expect(insurer.rncLabel, '1-30-00000-1');
      expect(insurer.createdAt, DateTime.utc(2026, 9, 16, 12));
    });

    test('a suspended or unreadable status is not active', () {
      expect(Insurer.fromJson('a', const {'status': 'suspended'}).isActive, isFalse);
      expect(Insurer.fromJson('a', const {'status': 'paused'}).isActive, isFalse);
      expect(Insurer.fromJson('a', const {}).isActive, isFalse);
    });

    test('an empty record reads without throwing', () {
      final insurer = Insurer.fromJson('a', const {});
      expect(insurer.name, '');
      expect(insurer.rncLabel, '');
      expect(insurer.createdAt, isNull);
    });
  });

  group('InsurerMember.fromJson', () {
    test('reads a manager', () {
      final member = InsurerMember.fromJson('ins-1', 'u-1', const {
        'name': 'Ana Pérez',
        'email': 'ana@ejemplo.do',
        'insurerRole': 'manager',
        'active': true,
        'mustChangePassword': true,
      });

      expect(member.insurerId, 'ins-1');
      expect(member.uid, 'u-1');
      expect(member.role, InsurerRole.manager);
      expect(member.canManageMembers, isTrue);
      expect(member.mustChangePassword, isTrue);
    });

    test('a deactivated manager manages nobody', () {
      final member = InsurerMember.fromJson('ins-1', 'u-1', const {
        'insurerRole': 'manager',
        'active': false,
      });
      expect(member.canManageMembers, isFalse);
    });

    test('anything but an explicit true is inactive', () {
      for (final value in [null, 'true', 1, false]) {
        final member = InsurerMember.fromJson('i', 'u', {
          'insurerRole': 'manager',
          'active': value,
        });
        expect(member.active, isFalse, reason: 'active: $value');
        expect(member.canManageMembers, isFalse, reason: 'active: $value');
      }
    });
  });

  test('the collection names match the backend', () {
    // functions/src/lib/firestore.ts, and the paths in firestore.rules.
    expect(Paths.insurersCollection, 'insurers');
    expect(Paths.membersSubcollection, 'members');
  });
}
