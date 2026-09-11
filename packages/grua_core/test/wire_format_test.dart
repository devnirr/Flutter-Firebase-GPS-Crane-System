import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';

/// The wire contract between the apps and `functions/src/lib/enums.ts`.
///
/// These are here because both halves of it broke silently: the generated
/// codecs used Dart enum names rather than the `wire` strings the backend
/// writes, and an unrecognised value threw instead of resolving to `unknown` —
/// which took a chofer's whole profile screen down over one blank field.
void main() {
  group('enums serialize as their wire value', () {
    test('a multi-word status is snake_case on the wire, not camelCase', () {
      const service = Service(
        id: 's1',
        code: 'GR-0001',
        clientId: 'c1',
        pickup: ServiceLocation(geo: LatLng(18.47, -69.9)),
      );

      expect(service.toJson()['status'], 'pending_dispatch');
      expect(
        Service.fromJson({...service.toJson(), 'status': 'in_progress'}).status,
        ServiceStatus.inProgress,
      );
    });

    test('a live position round-trips the state dispatch filters on', () {
      const live = DriverLivePosition(
        driverId: 'd1',
        lat: 18.47,
        lng: -69.9,
        state: DriverLiveState.onService,
      );

      expect(live.toJson()['state'], 'on_service');
      expect(
        DriverLivePosition.fromJson(live.toJson()).state,
        DriverLiveState.onService,
      );
    });

    test('an NCF type keeps its DGII code', () {
      expect(
        const Invoice(
          id: 'i1',
          serviceId: 's1',
          clientId: 'c1',
          ncfType: NcfType.creditoFiscal,
        ).toJson()['ncfType'],
        '01',
      );
    });
  });

  group('an unrecognised value resolves to unknown', () {
    test('a chofer with no grúa assigned still loads', () {
      // What `createDriver` writes before a grúa is assigned. This threw an
      // ArgumentError and left the driver app on "No pudimos cargar tu perfil".
      final driver = Driver.fromJson({
        'id': 'd1',
        'name': 'Wilfredo Reyes',
        'status': 'inactive',
        'truckType': '',
      });

      expect(driver.truckType, TruckType.unknown);
      expect(driver.canGoOnline, isFalse);
    });

    test('a status this build has never heard of does not crash a screen', () {
      final service = Service.fromJson({
        'id': 's1',
        'code': 'GR-0001',
        'clientId': 'c1',
        'pickup': {'geo': {'lat': 18.47, 'lng': -69.9}},
        'status': 'awaiting_alien_tow',
      });

      expect(service.status, ServiceStatus.unknown);
      expect(service.status.isTerminal, isFalse);
    });

    test('an unknown role is not staff', () {
      expect(
        AppUser.fromJson({
          'id': 'u1',
          'phone': '+18095551234',
          'role': 'superintendent',
        }).role,
        UserRole.unknown,
      );
    });
  });
}
