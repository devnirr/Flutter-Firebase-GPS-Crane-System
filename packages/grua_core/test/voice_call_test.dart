import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';

/// Voice calls between a customer and their chofer.
///
/// The phone button on the chofer's service screen and the customer's
/// "Llamar" used to show "Llamando a …" and nothing else. These run a whole
/// call, both sides, on the in-memory backend: the customer's side through the
/// real controller, the chofer's side straight on the backend, which is what
/// their app would do on its own phone.
///
/// `testWidgets` rather than `test` for its fake clock: a call rings for 45
/// seconds before it counts as missed, and the screen lingers after hanging up.
void main() {
  const client = 'demo-client-1';
  const pickup = ServiceLocation(
    geo: LatLng(18.4795, -69.9420),
    address: 'Gazcue',
  );

  late DemoBackend backend;
  late String driverId;
  late Service service;
  late SilentVoiceTransport transport;
  late ProviderContainer container;

  /// A tow in progress: the one window where the two may call each other.
  void setUpService({bool assign = true, Exception? micError}) {
    backend = DemoBackend(dispatchDelay: const Duration(hours: 1))..seed();
    service = backend.createService(
      clientId: client,
      pickup: pickup,
      dropoff: const ServiceLocation(geo: LatLng(18.5001, -69.8800)),
      vehicle: const ServiceVehicle(condition: VehicleCondition.noArranca),
      truckType: TruckType.gancho,
      paymentMethod: PaymentMethod.cash,
      quote: const Quote(totalCents: 250000),
      route: const ServiceRoute(distanceMeters: 8000),
    );
    driverId = backend.allDrivers
        .firstWhere(
          (d) => d.truckType == TruckType.gancho && d.status.canWork && !d.isBusy,
        )
        .id;
    if (assign) {
      expect(
        backend.assignServiceManually(serviceId: service.id, driverId: driverId),
        isNull,
      );
    }

    transport = SilentVoiceTransport(prepareError: micError);
    container = ProviderContainer(
      overrides: [
        ...demoOverrides(
          backend: backend,
          actingAs: client,
          // One the test can inspect.
          voiceTransport: () => transport,
        ),
        currentUserIdProvider.overrideWithValue(client),

      ],
    )
      // Kept alive the way the app keeps it: watched from the root.
      ..listen(callControllerProvider, (_, _) {});
  }

  CallSession session() => container.read(callControllerProvider);
  CallController controller() => container.read(callControllerProvider.notifier);
  VoiceCall onlyCall() => backend.allCalls.single;

  Future<void> settle(WidgetTester tester, [Duration by = const Duration(milliseconds: 500)]) =>
      tester.pump(by);

  /// Runs [action] while the fake clock moves: every server call in demo mode
  /// waits a moment, and awaiting one without pumping would wait forever.
  Future<void> run(WidgetTester tester, Future<void> action) async {
    await settle(tester);
    await action;
  }

  void tearDownAll() {
    container.dispose();
    backend.dispose();
  }

  group('placing a call', () {
    testWidgets('rings the chofer, connects when answered, ends for both', (tester) async {
      setUpService();

      final placing = controller().call(serviceId: service.id, peerName: 'Chofer');
      expect(session().phase, CallPhase.outgoing, reason: 'shown before the server answers');
      await settle(tester);
      await placing;

      // It rings on the chofer's side.
      expect(onlyCall().state, CallState.ringing);
      expect(onlyCall().calleeId, driverId);
      expect(session().peerName, isNotEmpty);
      // The caller waits in the room, so the audio is ready when they answer.
      expect(transport.connected, isTrue);

      // The chofer answers on their phone.
      backend.answerCall(onlyCall().id, driverId);
      await settle(tester);
      expect(session().phase, CallPhase.active);
      expect(session().connectedAt, isNotNull);

      await run(tester, controller().hangUp());
      await settle(tester);
      expect(session().phase, CallPhase.ended);
      expect(session().message, 'Llamada terminada');
      expect(onlyCall().state, CallState.ended);
      expect(transport.connected, isFalse);

      // The screen clears itself.
      await settle(tester, CallController.endedLinger);
      expect(session().isIdle, isTrue);

      tearDownAll();
    });

    testWidgets('says so when the chofer declines', (tester) async {
      setUpService();
      await run(tester, controller().call(serviceId: service.id, peerName: 'Chofer'));
      await settle(tester);

      backend.endCall(onlyCall().id, driverId, EndCallReason.declined);
      await settle(tester);

      expect(session().phase, CallPhase.ended);
      expect(session().message, 'No contestó');
      expect(transport.connected, isFalse);
      await settle(tester, CallController.endedLinger);
      tearDownAll();
    });

    testWidgets('gives up after ringing out, and records it as missed', (tester) async {
      setUpService();
      await run(tester, controller().call(serviceId: service.id, peerName: 'Chofer'));
      await settle(tester);

      await settle(tester, VoiceCall.ringLimit + const Duration(seconds: 1));

      expect(session().message, 'Sin respuesta');
      expect(onlyCall().state, CallState.missed);
      await settle(tester, CallController.endedLinger);
      tearDownAll();
    });

    testWidgets('hanging up while it rings cancels it on the other phone', (tester) async {
      setUpService();
      await run(tester, controller().call(serviceId: service.id, peerName: 'Chofer'));
      await settle(tester);

      await run(tester, controller().hangUp());
      await settle(tester);

      expect(session().message, 'Llamada cancelada');
      expect(onlyCall().state, CallState.cancelled);
      await settle(tester, CallController.endedLinger);
      tearDownAll();
    });

    testWidgets('is refused before a chofer has accepted, with a reason', (tester) async {
      setUpService(assign: false);

      await run(tester, controller().call(serviceId: service.id, peerName: 'Chofer'));
      await settle(tester);

      expect(session().phase, CallPhase.ended);
      expect(session().message, isNotEmpty);
      expect(backend.allCalls, isEmpty);
      expect(transport.connected, isFalse);
      await settle(tester, CallController.endedLinger);
      tearDownAll();
    });

    testWidgets('a second call on the same service is refused', (tester) async {
      setUpService();
      // The chofer is already ringing the customer.
      backend.startCall(service.id, driverId);
      await settle(tester);
      // The customer's screen shows it ringing; a new call must not start.
      expect(session().phase, CallPhase.incoming);

      expect(backend.startCall(service.id, client), isA<Err<CallJoin>>());
      tearDownAll();
    });
  });

  group('the microphone', () {
    // What the chofer hit: the call reached the customer's phone and rang, and
    // the chofer's own screen said the microphone could not be used. The
    // microphone was only asked for after the other phone was already ringing,
    // and any audio failure was blamed on it.

    testWidgets('refused when calling: nobody is rung', (tester) async {
      setUpService(micError: Exception('NotAllowedError: Permission denied'));

      await run(tester, controller().call(serviceId: service.id, peerName: 'Chofer'));
      await settle(tester);

      expect(backend.allCalls, isEmpty, reason: 'the other phone never rang');
      expect(session().phase, CallPhase.ended);
      expect(session().message, CallAudioProblem.permission.message);
      await settle(tester, CallController.endedLinger);
      tearDownAll();
    });

    testWidgets('refused when answering: the call is declined, not accepted', (tester) async {
      setUpService(micError: Exception('NotAllowedError: Permission denied'));
      backend.startCall(service.id, driverId);
      await settle(tester);
      expect(session().phase, CallPhase.incoming);

      await run(tester, controller().answer());
      await settle(tester);

      // The caller hears "No contestó" rather than waiting on a silent line.
      expect(onlyCall().state, CallState.declined);
      expect(session().message, CallAudioProblem.permission.message);
      await settle(tester, CallController.endedLinger);
      tearDownAll();
    });

    test('says what actually went wrong', () {
      // Web: a browser DOMException, known only by its name.
      expect(CallAudioProblem.of(Exception('NotAllowedError: Permission denied')),
          CallAudioProblem.permission);
      expect(CallAudioProblem.of(Exception('NotFoundError: Requested device not found')),
          CallAudioProblem.noMicrophone);
      expect(CallAudioProblem.of(Exception('NotReadableError: Could not start audio source')),
          CallAudioProblem.microphoneBusy);
      expect(
        CallAudioProblem.of(Exception("Cannot read properties of undefined (reading 'getUserMedia')")),
        CallAudioProblem.unknown,
      );
      // Not every failure is the microphone.
      expect(CallAudioProblem.of(Exception('websocket closed')), CallAudioProblem.connection);
      expect(CallAudioProblem.of(Exception('something odd')), CallAudioProblem.unknown);
    });
  });

  group('being called', () {
    testWidgets('rings wherever the customer is, and connects on answer', (tester) async {
      setUpService();

      backend.startCall(service.id, driverId);
      await settle(tester);

      expect(session().phase, CallPhase.incoming);
      expect(session().peerName, onlyCall().callerName);

      final answering = controller().answer();
      expect(session().phase, CallPhase.connecting);
      await settle(tester);
      await answering;

      expect(onlyCall().state, CallState.accepted);
      expect(session().phase, CallPhase.active);
      expect(transport.connected, isTrue);

      // The chofer hangs up.
      backend.endCall(onlyCall().id, driverId, EndCallReason.hangup);
      await settle(tester);

      expect(session().phase, CallPhase.ended);
      expect(session().message, 'Llamada terminada');
      expect(transport.connected, isFalse);
      await settle(tester, CallController.endedLinger);
      expect(session().isIdle, isTrue);
      tearDownAll();
    });

    testWidgets('declining tells the caller', (tester) async {
      setUpService();
      backend.startCall(service.id, driverId);
      await settle(tester);

      await run(tester, controller().decline());
      await settle(tester);

      expect(onlyCall().state, CallState.declined);
      expect(session().phase, CallPhase.ended);
      await settle(tester, CallController.endedLinger);
      tearDownAll();
    });

    testWidgets('stops ringing when the caller gives up', (tester) async {
      setUpService();
      backend.startCall(service.id, driverId);
      await settle(tester);
      expect(session().phase, CallPhase.incoming);

      backend.endCall(onlyCall().id, driverId, EndCallReason.cancelled);
      await settle(tester);

      expect(session().phase, CallPhase.ended);
      expect(session().message, 'Llamada cancelada');
      await settle(tester, CallController.endedLinger);
      tearDownAll();
    });
  });

  group('on the line', () {
    testWidgets('the other person dropping ends it for both', (tester) async {
      setUpService();
      backend.startCall(service.id, driverId);
      await settle(tester);
      await run(tester, controller().answer());
      await settle(tester);
      expect(session().phase, CallPhase.active);

      transport.simulatePeerLeft();
      await settle(tester);

      expect(session().phase, CallPhase.ended);
      expect(onlyCall().state, CallState.ended);
      await settle(tester, CallController.endedLinger);
      tearDownAll();
    });

    testWidgets('mute and speaker reach the audio', (tester) async {
      setUpService();
      backend.startCall(service.id, driverId);
      await settle(tester);
      await run(tester, controller().answer());
      await settle(tester);

      await controller().toggleMute();
      await controller().toggleSpeaker();

      expect(session().muted, isTrue);
      expect(transport.muted, isTrue);
      expect(session().speaker, isTrue);
      expect(transport.speaker, isTrue);

      await run(tester, controller().hangUp());
      await settle(tester, CallController.endedLinger + const Duration(seconds: 1));
      tearDownAll();
    });
  });

  group('the call screen', () {
    testWidgets('rings over the app, answers, and hangs up', (tester) async {
      setUpService();

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            builder: (context, child) => CallLayer(child: child!),
            home: const Scaffold(body: Text('mapa')),
          ),
        ),
      );
      expect(find.byKey(const Key('call-screen')), findsNothing);

      backend.startCall(service.id, driverId);
      await settle(tester);

      // Over whatever was on screen.
      expect(find.byKey(const Key('call-screen')), findsOneWidget);
      expect(find.text('Llamada entrante'), findsOneWidget);
      expect(find.byKey(const Key('call-answer')), findsOneWidget);
      expect(find.byKey(const Key('call-decline')), findsOneWidget);

      await tester.tap(find.byKey(const Key('call-answer')));
      await settle(tester);

      expect(find.byKey(const Key('call-hangup')), findsOneWidget);
      expect(find.byKey(const Key('call-mute')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('call-status'))).data,
        matches(RegExp(r'^\d\d:\d\d$')),
      );

      await tester.tap(find.byKey(const Key('call-hangup')));
      await settle(tester);
      expect(find.text('Llamada terminada'), findsOneWidget);

      await settle(tester, CallController.endedLinger);
      expect(find.byKey(const Key('call-screen')), findsNothing);
      expect(find.text('mapa'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      tearDownAll();
    });
  });
}
