import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';

/// The roster's green / yellow / red dot.
void main() {
  const luis = Driver(id: 'driver-1', name: 'Luis Fernández');

  test('a chofer on a job is busy, whatever the online switch says', () {
    expect(
      luis.copyWith(currentServiceId: 'svc-1', isOnline: true).presence(),
      DriverPresence.busy,
    );
    expect(
      luis.copyWith(currentServiceId: 'svc-1').presence(appOpen: true),
      DriverPresence.busy,
    );
  });

  test('online with no job is online, and an empty job id is no job', () {
    expect(luis.copyWith(isOnline: true).presence(), DriverPresence.online);
    expect(
      luis.copyWith(isOnline: true, currentServiceId: '').presence(),
      DriverPresence.online,
    );
  });

  test('the switch outranks the app merely being open', () {
    expect(
      luis.copyWith(isOnline: true).presence(appOpen: true),
      DriverPresence.online,
    );
  });

  test('app open with the switch off is connected, not offline', () {
    expect(luis.presence(appOpen: true), DriverPresence.connected);
  });

  test('app closed with the switch off is offline', () {
    expect(luis.presence(), DriverPresence.offline);
  });

  test('the dot reads green, yellow, red', () {
    expect(DriverPresence.online.color, BrandColors.success);
    // Signed in is reachable: green, like online. The label tells them apart.
    expect(DriverPresence.connected.color, BrandColors.success);
    expect(DriverPresence.offline.color, BrandColors.danger);
    expect(DriverPresence.busy.color, isNot(DriverPresence.online.color));
  });

  testWidgets('with no photo the avatar shows initials and names its state',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DriverAvatar.of(luis.copyWith(isOnline: true))),
      ),
    );

    expect(find.text('LF'), findsOneWidget);
    expect(find.bySemanticsLabel('Luis Fernández, En línea'), findsOneWidget);
  });

  testWidgets('a chofer with the app open reads as connected', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: DriverAvatar.of(luis, appOpen: true))),
    );

    expect(find.bySemanticsLabel('Luis Fernández, Conectado'), findsOneWidget);
  });
}
