import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

/// The audio half of a call: take the microphone, connect, talk, hang up.
///
/// An interface rather than LiveKit directly because two things cannot open a
/// real audio session — demo mode, which has no LiveKit server, and a widget
/// test, which has no microphone — and both still need the whole call flow to
/// run. [SilentVoiceTransport] stands in for them.
abstract class VoiceTransport {
  /// Takes the microphone, asking for permission if it has to.
  ///
  /// Called *before* anybody is rung: a person who cannot talk should find out
  /// before the other phone starts ringing, not after it has been answered.
  Future<void> prepare();

  /// Joins the call's room and starts sending the prepared microphone.
  Future<void> connect({required String url, required String token});

  /// Fires when the other person is in the room and can be heard.
  Stream<void> get peerJoined;

  /// Fires when the other person leaves the room, or the connection is lost.
  Stream<void> get peerLeft;

  Future<void> setMuted({required bool muted});

  /// Loudspeaker rather than earpiece. A no-op where there is no earpiece.
  Future<void> setSpeaker({required bool on});

  bool get canSwitchSpeaker;

  /// Leaves the room and gives the microphone back.
  Future<void> disconnect();
}

/// Makes the audio side of a call — a real one by default, a silent one in
/// demo mode and in tests.
final voiceTransportFactoryProvider = Provider<VoiceTransport Function()>(
  (ref) => LiveKitVoiceTransport.new,
);

/// What stopped the audio, in words the person can act on.
enum CallAudioProblem {
  /// Permission refused, dismissed, or blocked for this site.
  permission(
    'Permite el uso del micrófono para llamar. En el navegador, toca el ícono '
    'del candado junto a la dirección y activa el micrófono.',
  ),

  /// No microphone on this device, or none the browser can see.
  noMicrophone('No encontramos un micrófono en este dispositivo.'),

  /// Allowed, but the system would not open it: another program holding it,
  /// the operating system's own privacy switch, or a device that failed.
  microphoneBusy(
    'No pudimos abrir el micrófono. Puede que otra aplicación lo esté usando '
    'o que el sistema lo tenga bloqueado.',
  ),

  /// The page is not on HTTPS or localhost, where browsers refuse microphones.
  insecurePage(
    'El navegador solo permite el micrófono en páginas seguras (https).',
  ),

  /// Could not reach the call server.
  connection('No pudimos conectar la llamada. Revisa tu conexión.'),

  /// Anything else.
  unknown('No pudimos iniciar el audio de la llamada. Intenta de nuevo.');

  const CallAudioProblem(this.message);

  final String message;

  /// Reads what went wrong from the error the platform actually threw.
  ///
  /// There is no shared type to switch on: the web hands back a browser
  /// `DOMException` whose name is only in its text, the phones a LiveKit
  /// exception wrapping a platform one. So it is read by name — which is what
  /// the old catch-all did not do, and why every failure used to be blamed on
  /// the microphone.
  static CallAudioProblem of(Object error) {
    final text = error.toString();
    bool has(String needle) => text.toLowerCase().contains(needle.toLowerCase());

    if (has('NotAllowedError') ||
        has('PermissionDenied') ||
        has('Permission denied') ||
        has('permission is not granted')) {
      return CallAudioProblem.permission;
    }
    if (has('NotFoundError') || has('device not found') || has('OverconstrainedError')) {
      return CallAudioProblem.noMicrophone;
    }
    if (has('NotReadableError') || has('Could not start audio source') || has('TrackStartError')) {
      return CallAudioProblem.microphoneBusy;
    }
    if (has('SecurityError') || has('mediaDevices') || has('getUserMedia is not')) {
      return CallAudioProblem.insecurePage;
    }
    if (error is lk.ConnectException ||
        error is lk.MediaConnectException ||
        error is TimeoutException ||
        has('websocket') ||
        has('could not connect')) {
      return CallAudioProblem.connection;
    }
    if (error is lk.TrackCreateException) return CallAudioProblem.permission;
    return CallAudioProblem.unknown;
  }
}

/// A real call, over LiveKit.
class LiveKitVoiceTransport implements VoiceTransport {
  lk.Room? _room;
  lk.LocalAudioTrack? _mic;
  lk.EventsListener<lk.RoomEvent>? _listener;
  final _joined = StreamController<void>.broadcast();
  final _left = StreamController<void>.broadcast();

  static const _capture = lk.AudioCaptureOptions(
    echoCancellation: true,
    noiseSuppression: true,
    autoGainControl: true,
  );

  @override
  Stream<void> get peerJoined => _joined.stream;

  @override
  Stream<void> get peerLeft => _left.stream;

  @override
  bool get canSwitchSpeaker => lk.AudioManager.instance.canSwitchSpeakerphone;

  @override
  Future<void> prepare() async {
    _mic ??= await lk.LocalAudioTrack.create(_capture);
  }

  @override
  Future<void> connect({required String url, required String token}) async {
    final room = lk.Room(
      roomOptions: const lk.RoomOptions(
        // Voice only: nothing here ever publishes video, and adaptive stream
        // and dynacast exist to save video bandwidth.
        adaptiveStream: false,
        dynacast: false,
        defaultAudioCaptureOptions: _capture,
      ),
    );
    _room = room;

    _listener = room.createListener()
      ..on<lk.ParticipantConnectedEvent>((_) => _joined.add(null))
      ..on<lk.ParticipantDisconnectedEvent>((_) => _left.add(null))
      // Lost for good — the other side will not hear anything more either.
      ..on<lk.RoomDisconnectedEvent>((_) => _left.add(null));

    await room.connect(url, token);

    final mic = _mic ?? await lk.LocalAudioTrack.create(_capture);
    _mic = mic;
    await room.localParticipant?.publishAudioTrack(mic);

    // Browsers refuse to play audio a page starts on its own. Harmless when
    // they refuse: LiveKit reports it rather than throwing.
    if (kIsWeb) await room.startAudio();

    // Already there: the caller joined first and has been waiting.
    if (room.remoteParticipants.isNotEmpty) _joined.add(null);
  }

  @override
  Future<void> setMuted({required bool muted}) async {
    final mic = _mic;
    if (mic == null) return;
    if (muted) {
      await mic.mute(stopOnMute: false);
    } else {
      await mic.unmute(stopOnMute: false);
    }
  }

  @override
  Future<void> setSpeaker({required bool on}) async {
    if (!canSwitchSpeaker) return;
    await lk.AudioManager.instance.setSpeakerOutputPreferred(on);
  }

  @override
  Future<void> disconnect() async {
    final room = _room;
    final mic = _mic;
    _room = null;
    _mic = null;
    await _listener?.dispose();
    _listener = null;
    if (room != null) {
      await room.disconnect();
      await room.dispose();
    }
    // Given back even when the call never connected — cancelled during the
    // permission prompt, refused by the server — or the browser keeps showing
    // the microphone as in use.
    if (mic != null) {
      await mic.stop();
      await mic.dispose();
    }
  }
}

/// A call with no audio, for demo mode and tests.
///
/// Reports the other person as joined as soon as it connects: the ringing and
/// answering are what the rest of the call flow is waiting on, and those come
/// from the call document, not from here.
class SilentVoiceTransport implements VoiceTransport {
  SilentVoiceTransport({this.prepareError});

  /// For tests: what [prepare] throws, standing in for a refused microphone.
  final Exception? prepareError;

  final _joined = StreamController<void>.broadcast();
  final _left = StreamController<void>.broadcast();

  bool prepared = false;
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
  Future<void> prepare() async {
    final error = prepareError;
    if (error != null) throw error;
    prepared = true;
  }

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
  Future<void> disconnect() async {
    connected = false;
    prepared = false;
  }
}
