import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show StreamProviderFamily;

import '../domain/failures.dart';
import '../providers.dart';
import 'voice_call.dart';
import 'voice_transport.dart';

/// What the call screen is showing.
enum CallPhase {
  /// No call. The layer draws nothing.
  idle,

  /// This person rang somebody, who has not answered yet.
  outgoing,

  /// Somebody is ringing this person.
  incoming,

  /// Answered, joining the audio.
  connecting,

  /// Both on the line.
  active,

  /// Over, with a word about how. Clears itself after a moment.
  ended,
}

@immutable
class CallSession {
  const CallSession({
    this.phase = CallPhase.idle,
    this.callId,
    this.peerName = '',
    this.muted = false,
    this.speaker = false,
    this.canSwitchSpeaker = false,
    this.connectedAt,
    this.message,
  });

  final CallPhase phase;
  final String? callId;
  final String peerName;
  final bool muted;
  final bool speaker;
  final bool canSwitchSpeaker;

  /// When both were on the line, for the timer.
  final DateTime? connectedAt;

  /// How it ended, or why it could not start.
  final String? message;

  bool get isIdle => phase == CallPhase.idle;

  CallSession copyWith({
    CallPhase? phase,
    String? callId,
    String? peerName,
    bool? muted,
    bool? speaker,
    bool? canSwitchSpeaker,
    DateTime? connectedAt,
    String? message,
  }) =>
      CallSession(
        phase: phase ?? this.phase,
        callId: callId ?? this.callId,
        peerName: peerName ?? this.peerName,
        muted: muted ?? this.muted,
        speaker: speaker ?? this.speaker,
        canSwitchSpeaker: canSwitchSpeaker ?? this.canSwitchSpeaker,
        connectedAt: connectedAt ?? this.connectedAt,
        message: message ?? this.message,
      );
}

/// One call at a time, for whoever is signed in: placing one, being rung,
/// talking, and the moment after it ends.
///
/// Lives at the app root rather than on a screen, because a call has to ring
/// wherever the person happens to be — the map, the chat, their profile — and
/// keep going when they move between them.
class CallController extends Notifier<CallSession> {
  /// How long "Llamada terminada" stays up before the screen clears.
  static const endedLinger = Duration(seconds: 2);

  VoiceTransport? _transport;
  StreamSubscription<VoiceCall?>? _callWatch;
  StreamSubscription<void>? _joined;
  StreamSubscription<void>? _left;
  Timer? _ringTimeout;
  Timer? _clear;
  String? _uid;

  @override
  CallSession build() {
    _uid = ref.watch(currentUserIdProvider);
    ref.onDispose(_teardown);

    final uid = _uid;
    if (uid != null) {
      ref.listen<AsyncValue<VoiceCall?>>(
        _incomingProvider(uid),
        (_, next) => _onIncoming(next.value),
      );
    }
    return const CallSession();
  }

  // ---------------------------------------------------------------- placing

  /// Rings the other party on [serviceId]. [peerName] is shown straight away,
  /// before the server has answered.
  Future<void> call({required String serviceId, required String peerName}) async {
    if (!state.isIdle) return;
    state = CallSession(phase: CallPhase.outgoing, peerName: peerName);

    // The microphone first, and only then the other phone. The other way
    // round, a caller whose microphone was refused had already set the other
    // phone ringing — and the person who picked up got nobody.
    if (!await _takeMicrophone()) return;
    if (state.phase != CallPhase.outgoing) {
      _releaseMicrophone(); // hung up during the permission prompt
      return;
    }

    final gateway = ref.read(functionsGatewayProvider);
    final result = await gateway.startCall(serviceId);

    // Hung up while the server was still being asked. The call exists now, and
    // left alone it would ring on the other phone for the full 45 seconds.
    if (state.phase != CallPhase.outgoing) {
      if (result case Ok(:final value)) {
        unawaited(gateway.endCall(value.callId, EndCallReason.cancelled));
      }
      _releaseMicrophone();
      return;
    }

    switch (result) {
      case Err(:final failure):
        _end(failure.userMessage);
      case Ok(:final value):
        state = state.copyWith(callId: value.callId, peerName: value.peerName);
        _watchCall(value.callId);
        // Nobody answering is a missed call, not a phone ringing forever.
        _ringTimeout = Timer(VoiceCall.ringLimit, () {
          if (state.phase == CallPhase.outgoing) {
            unawaited(_finish(EndCallReason.missed, 'Sin respuesta'));
          }
        });
        // The caller waits in the room, so the audio is ready the moment the
        // other side picks up.
        await _connect(value);
    }
  }

  // --------------------------------------------------------------- answering

  void _onIncoming(VoiceCall? call) {
    if (call == null || !state.isIdle) return;
    if (call.isStale(DateTime.now().toUtc())) return;
    state = CallSession(
      phase: CallPhase.incoming,
      callId: call.id,
      peerName: call.callerName,
    );
    _watchCall(call.id);
  }

  Future<void> answer() async {
    final callId = state.callId;
    if (state.phase != CallPhase.incoming || callId == null) return;
    state = state.copyWith(phase: CallPhase.connecting);

    // Before answering on the server: a callee who cannot talk declines,
    // rather than accepting a call and leaving the caller listening to nothing.
    if (!await _takeMicrophone(declining: callId)) return;

    final result = await ref.read(functionsGatewayProvider).answerCall(callId);
    switch (result) {
      case Err(:final failure):
        _end(failure.userMessage);
      case Ok(:final value):
        await _connect(value);
    }
  }

  Future<void> decline() =>
      _finish(EndCallReason.declined, 'Llamada rechazada');

  // ----------------------------------------------------------------- talking

  Future<void> hangUp() => _finish(
        state.phase == CallPhase.outgoing
            ? EndCallReason.cancelled
            : EndCallReason.hangup,
        state.phase == CallPhase.outgoing ? 'Llamada cancelada' : 'Llamada terminada',
      );

  Future<void> toggleMute() async {
    final muted = !state.muted;
    state = state.copyWith(muted: muted);
    await _transport?.setMuted(muted: muted);
  }

  Future<void> toggleSpeaker() async {
    final on = !state.speaker;
    state = state.copyWith(speaker: on);
    await _transport?.setSpeaker(on: on);
  }

  // ---------------------------------------------------------------- plumbing

  /// Takes the microphone for this call. False, with the screen already
  /// saying why, when it could not be had.
  ///
  /// [declining] is the call to turn down when this was an answer.
  Future<bool> _takeMicrophone({String? declining}) async {
    final transport = ref.read(voiceTransportFactoryProvider)();
    _transport = transport;
    try {
      await transport.prepare();
      return true;
    } on Object catch (error) {
      debugPrint('Call microphone refused: $error');
      final problem = CallAudioProblem.of(error);
      _end(problem.message);
      if (declining != null) {
        await ref
            .read(functionsGatewayProvider)
            .endCall(declining, EndCallReason.declined);
      }
      return false;
    }
  }

  void _releaseMicrophone() {
    final transport = _transport;
    _transport = null;
    if (transport != null) unawaited(transport.disconnect());
  }

  Future<void> _connect(CallJoin join) async {
    final transport = _transport ?? ref.read(voiceTransportFactoryProvider)();
    _transport = transport;
    state = state.copyWith(canSwitchSpeaker: transport.canSwitchSpeaker);

    _joined = transport.peerJoined.listen((_) {
      // The caller is in the room before anyone answers; being alone in it is
      // not being connected. The call document says when it was answered.
      if (state.phase == CallPhase.connecting) {
        state = state.copyWith(
          phase: CallPhase.active,
          connectedAt: DateTime.now(),
        );
      }
    });
    _left = transport.peerLeft.listen((_) {
      if (state.phase == CallPhase.active) {
        unawaited(_finish(EndCallReason.hangup, 'Llamada terminada'));
      }
    });

    try {
      await transport.connect(url: join.url, token: join.token);
    } on Object catch (error) {
      // The real error in the console, and the screen says which kind it was.
      // It used to blame the microphone for everything, a server it could not
      // reach included.
      debugPrint('Call audio failed: $error');
      await _finish(EndCallReason.hangup, CallAudioProblem.of(error).message);
    }
  }

  void _watchCall(String callId) {
    unawaited(_callWatch?.cancel());
    _callWatch = ref
        .read(callRepositoryProvider)
        .watchCall(callId)
        .listen((call) {
      if (call == null || state.callId != callId) return;

      switch (call.state) {
        case CallState.accepted:
          if (state.phase == CallPhase.outgoing) {
            _ringTimeout?.cancel();
            // The caller has been in the room all along; the answer is what
            // makes it a conversation.
            state = state.copyWith(
              phase: CallPhase.active,
              connectedAt: DateTime.now(),
            );
          }
        case CallState.declined:
          _end(state.phase == CallPhase.outgoing ? 'No contestó' : 'Llamada rechazada');
        case CallState.missed:
          _end(state.phase == CallPhase.incoming ? 'Llamada perdida' : 'Sin respuesta');
        case CallState.cancelled:
          _end('Llamada cancelada');
        case CallState.ended:
          _end('Llamada terminada');
        case CallState.ringing || CallState.unknown:
          break;
      }
    });
  }

  /// Tells the server, then winds down locally whatever it said: a hang-up the
  /// network lost must still take the call off this screen.
  Future<void> _finish(EndCallReason reason, String message) async {
    final callId = state.callId;
    if (state.isIdle || state.phase == CallPhase.ended) return;
    _end(message);
    if (callId != null) {
      await ref.read(functionsGatewayProvider).endCall(callId, reason);
    }
  }

  void _end(String message) {
    if (state.phase == CallPhase.ended || state.isIdle) return;
    _stopCall();
    state = state.copyWith(phase: CallPhase.ended, message: message);
    _clear = Timer(endedLinger, () {
      if (state.phase == CallPhase.ended) state = const CallSession();
    });
  }

  void _stopCall() {
    _ringTimeout?.cancel();
    unawaited(_callWatch?.cancel());
    unawaited(_joined?.cancel());
    unawaited(_left?.cancel());
    _callWatch = null;
    _joined = null;
    _left = null;
    final transport = _transport;
    _transport = null;
    if (transport != null) unawaited(transport.disconnect());
  }

  void _teardown() {
    _clear?.cancel();
    _stopCall();
  }
}

final StreamProviderFamily<VoiceCall?, String> _incomingProvider =
    StreamProvider.family<VoiceCall?, String>(
  (ref, uid) => ref.watch(callRepositoryProvider).watchIncomingCall(uid),
);

final callControllerProvider = NotifierProvider<CallController, CallSession>(
  CallController.new,
);
