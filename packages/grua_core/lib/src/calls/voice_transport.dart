import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

/// The audio half of a call: connect, talk, hang up.
///
/// An interface rather than LiveKit directly because two things cannot open a
/// real audio session — demo mode, which has no LiveKit server, and a widget
/// test, which has no microphone — and both still need the whole call flow to
/// run. [SilentVoiceTransport] stands in for them.
abstract class VoiceTransport {
  /// Joins the call's room with the microphone on.
  Future<void> connect({required String url, required String token});

  /// Fires when the other person is in the room and can be heard.
  Stream<void> get peerJoined;

  /// Fires when the other person leaves the room, or the connection is lost.
  Stream<void> get peerLeft;

  Future<void> setMuted({required bool muted});

  /// Loudspeaker rather than earpiece. A no-op where there is no earpiece.
  Future<void> setSpeaker({required bool on});

  bool get canSwitchSpeaker;

  Future<void> disconnect();
}

/// A real call, over LiveKit.
class LiveKitVoiceTransport implements VoiceTransport {
  lk.Room? _room;
  lk.EventsListener<lk.RoomEvent>? _listener;
  final _joined = StreamController<void>.broadcast();
  final _left = StreamController<void>.broadcast();

  @override
  Stream<void> get peerJoined => _joined.stream;

  @override
  Stream<void> get peerLeft => _left.stream;

  @override
  bool get canSwitchSpeaker => lk.AudioManager.instance.canSwitchSpeakerphone;

  @override
  Future<void> connect({required String url, required String token}) async {
    final room = lk.Room(
      roomOptions: const lk.RoomOptions(
        // Voice only: nothing here ever publishes video, and adaptive stream
        // and dynacast exist to save video bandwidth.
        adaptiveStream: false,
        dynacast: false,
        defaultAudioCaptureOptions: lk.AudioCaptureOptions(
          echoCancellation: true,
          noiseSuppression: true,
          autoGainControl: true,
        ),
      ),
    );
    _room = room;

    _listener = room.createListener()
      ..on<lk.ParticipantConnectedEvent>((_) => _joined.add(null))
      ..on<lk.ParticipantDisconnectedEvent>((_) => _left.add(null))
      // Lost for good — the other side will not hear anything more either.
      ..on<lk.RoomDisconnectedEvent>((_) => _left.add(null));

    await room.connect(url, token);
    await room.localParticipant?.setMicrophoneEnabled(true);

    // Browsers refuse to play audio a page starts on its own. Called right
    // after the tap that placed or answered the call, which is the gesture
    // that allows it.
    if (kIsWeb) await room.startAudio();

    // Already there: the caller joined first and has been waiting.
    if (room.remoteParticipants.isNotEmpty) _joined.add(null);
  }

  @override
  Future<void> setMuted({required bool muted}) async {
    await _room?.localParticipant?.setMicrophoneEnabled(!muted);
  }

  @override
  Future<void> setSpeaker({required bool on}) async {
    if (!canSwitchSpeaker) return;
    await lk.AudioManager.instance.setSpeakerOutputPreferred(on);
  }

  @override
  Future<void> disconnect() async {
    final room = _room;
    _room = null;
    await _listener?.dispose();
    _listener = null;
    if (room != null) {
      await room.disconnect();
      await room.dispose();
    }
  }
}

/// A call with no audio, for demo mode and tests.
///
/// Reports the other person as joined as soon as it connects: the ringing and
/// answering are what the rest of the call flow is waiting on, and those come
/// from the call document, not from here.
class SilentVoiceTransport implements VoiceTransport {
  final _joined = StreamController<void>.broadcast();
  final _left = StreamController<void>.broadcast();

  bool connected = false;
  bool muted = false;
  bool speaker = false;

  @override
  Stream<void> get peerJoined => _joined.stream;

  @override
  Stream<void> get peerLeft => _left.stream;

  @override
  bool get canSwitchSpeaker => true;

  @override
  Future<void> connect({required String url, required String token}) async {
    connected = true;
    scheduleMicrotask(() => _joined.add(null));
  }

  /// For tests: the other person drops.
  void simulatePeerLeft() => _left.add(null);

  @override
  Future<void> setMuted({required bool muted}) async => this.muted = muted;

  @override
  Future<void> setSpeaker({required bool on}) async => speaker = on;

  @override
  Future<void> disconnect() async => connected = false;
}
