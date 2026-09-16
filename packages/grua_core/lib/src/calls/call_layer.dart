import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:livekit_client/livekit_client.dart' as lk
    show VideoTrack, VideoTrackRenderer, VideoViewFit;

import '../theme/brand.dart';
import 'call_controller.dart';

/// Draws the call over the whole app while there is one, and nothing
/// otherwise.
///
/// Placed in `MaterialApp.builder`, above the navigator, so a call rings on
/// whatever screen the person is on and survives them moving between screens.
/// Being above the navigator also means there is no `Overlay` here — hence no
/// tooltips below, only semantic labels.
class CallLayer extends ConsumerWidget {
  const CallLayer({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(callControllerProvider);

    return Stack(
      children: [
        Positioned.fill(child: child),
        if (!session.isIdle)
          Positioned.fill(
            // Ringing and the moment after it ends look the same either way;
            // only a video call on its way or on the line shows pictures.
            child: session.video &&
                    (session.phase == CallPhase.outgoing ||
                        session.phase == CallPhase.connecting ||
                        session.phase == CallPhase.active)
                ? _VideoCallScreen(session: session)
                : _CallScreen(session: session),
          ),
      ],
    );
  }
}

/// A video call: the other person filling the screen, this person's own
/// picture in a corner, and the controls over the bottom.
///
/// Before the other person's picture arrives — still ringing, or they have
/// their camera off — the big picture is this person's own preview, then
/// the other person's initial.
class _VideoCallScreen extends ConsumerWidget {
  const _VideoCallScreen({required this.session});

  final CallSession session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final controller = ref.read(callControllerProvider.notifier);
    final name = session.peerName.isEmpty ? 'Videollamada' : session.peerName;
    final active = session.phase == CallPhase.active;

    return Material(
      key: const Key('call-screen'),
      color: BrandColors.ink,
      child: ValueListenableBuilder<lk.VideoTrack?>(
        valueListenable: controller.remoteVideo,
        builder: (context, remote, _) => ValueListenableBuilder<lk.VideoTrack?>(
          valueListenable: controller.localVideo,
          builder: (context, local, _) {
            final showRemote = active && remote != null;
            // Your own face fills the screen only while nobody else is on it.
            final big = showRemote ? remote : (active ? null : local);

            return Stack(
              children: [
                Positioned.fill(
                  child: big != null
                      ? lk.VideoTrackRenderer(
                          big,
                          // A new renderer when the picture changes hands, not
                          // one left drawing the old track.
                          key: ValueKey(identityHashCode(big)),
                          fit: lk.VideoViewFit.cover,
                        )
                      : Center(
                          child: _SpeakingAvatar(
                            name: name,
                            ringing: session.phase == CallPhase.outgoing,
                            controller: controller,
                          ),
                        ),
                ),
                // Keeps the white text legible over a bright picture.
                const Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color(0x99000000),
                            Color(0x00000000),
                            Color(0x00000000),
                            Color(0xB3000000),
                          ],
                          stops: [0, 0.25, 0.6, 1],
                        ),
                      ),
                    ),
                  ),
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      Insets.lg,
                      Insets.lg,
                      Insets.lg,
                      Insets.xl,
                    ),
                    child: Column(
                      children: [
                        Text(
                          name,
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.titleLarge?.copyWith(color: BrandColors.white),
                        ),
                        const SizedBox(height: Insets.xs),
                        _Status(session: session),
                        if (active && remote == null) ...[
                          const SizedBox(height: Insets.xs),
                          Text(
                            'Cámara apagada',
                            key: const Key('call-peer-camera-off'),
                            style: text.bodySmall?.copyWith(
                              color: BrandColors.white.withValues(alpha: 0.7),
                            ),
                          ),
                        ],
                        if (active) _PeerAudioNotice(controller: controller),
                        const Spacer(),
                        _VideoControls(session: session, controller: controller),
                      ],
                    ),
                  ),
                ),
                if (showRemote && local != null && session.cameraOn)
                  Positioned(
                    top: 0,
                    right: 0,
                    child: SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.all(Insets.lg),
                        child: ClipRRect(
                          borderRadius: Corners.brMd,
                          child: SizedBox(
                            key: const Key('call-self-view'),
                            width: 104,
                            height: 148,
                            child: lk.VideoTrackRenderer(
                              local,
                              fit: lk.VideoViewFit.cover,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _VideoControls extends StatelessWidget {
  const _VideoControls({required this.session, required this.controller});

  final CallSession session;
  final CallController controller;

  @override
  Widget build(BuildContext context) {
    final hangUp = _RoundButton(
      key: const Key('call-hangup'),
      icon: Icons.call_end,
      label: 'Colgar',
      color: BrandColors.red,
      size: 60,
      onTap: () => unawaited(controller.hangUp()),
    );
    if (session.phase != CallPhase.active) return Center(child: hangUp);

    // Wraps rather than squeezing: five round buttons do not fit side by side
    // on a narrow phone.
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: Insets.lg,
      runSpacing: Insets.md,
      children: [
        _MicButton(session: session, controller: controller, size: 60),
        _RoundButton(
          key: const Key('call-camera'),
          icon: session.cameraOn ? Icons.videocam : Icons.videocam_off,
          label: 'Cámara',
          color: session.cameraOn ? BrandColors.grey600 : BrandColors.white,
          iconColor: session.cameraOn ? BrandColors.white : BrandColors.ink,
          size: 60,
          onTap: () => unawaited(controller.toggleCamera()),
        ),
        if (session.cameraOn)
          _RoundButton(
            key: const Key('call-switch-camera'),
            icon: Icons.cameraswitch_outlined,
            label: 'Girar',
            color: BrandColors.grey600,
            size: 60,
            onTap: () => unawaited(controller.switchCamera()),
          ),
        if (session.canSwitchSpeaker)
          _RoundButton(
            key: const Key('call-speaker'),
            icon: session.speaker ? Icons.volume_up : Icons.volume_down,
            label: 'Altavoz',
            color: session.speaker ? BrandColors.white : BrandColors.grey600,
            iconColor: session.speaker ? BrandColors.ink : BrandColors.white,
            size: 60,
            onTap: () => unawaited(controller.toggleSpeaker()),
          ),
        hangUp,
      ],
    );
  }
}

class _CallScreen extends ConsumerWidget {
  const _CallScreen({required this.session});

  final CallSession session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final controller = ref.read(callControllerProvider.notifier);
    final name = session.peerName.isEmpty ? 'Llamada' : session.peerName;

    return Material(
      key: const Key('call-screen'),
      color: BrandColors.ink,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.xl,
            vertical: Insets.xxxl,
          ),
          child: Column(
            children: [
              const Spacer(),
              _SpeakingAvatar(
                name: name,
                ringing: _isRinging(session.phase),
                controller: controller,
              ),
              const SizedBox(height: Insets.xl),
              Text(
                name,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: text.headlineMedium?.copyWith(color: BrandColors.white),
              ),
              const SizedBox(height: Insets.sm),
              _Status(session: session),
              if (session.phase == CallPhase.active)
                _PeerAudioNotice(controller: controller),
              const Spacer(flex: 2),
              _Controls(session: session, controller: controller),
            ],
          ),
        ),
      ),
    );
  }

  static bool _isRinging(CallPhase phase) =>
      phase == CallPhase.outgoing || phase == CallPhase.incoming;
}

/// The microphone button, lit by what the microphone is actually hearing.
///
/// A halo grows around it with this person's own voice. Somebody the other
/// side cannot hear can tell at a glance whether the phone is picking them up
/// — the microphone's own fault — or whether the trouble is further along.
class _MicButton extends StatelessWidget {
  const _MicButton({
    required this.session,
    required this.controller,
    this.size = 68,
  });

  final CallSession session;
  final CallController controller;
  final double size;

  @override
  Widget build(BuildContext context) {
    final button = _RoundButton(
      key: const Key('call-mute'),
      icon: session.muted ? Icons.mic_off : Icons.mic_none,
      label: session.muted
          ? (size < 68 ? 'Micrófono' : 'Activar micrófono')
          : (size < 68 ? 'Micrófono' : 'Silenciar'),
      color: session.muted ? BrandColors.white : BrandColors.grey600,
      iconColor: session.muted ? BrandColors.ink : BrandColors.white,
      size: size,
      onTap: () => unawaited(controller.toggleMute()),
    );

    // Nothing to show while muted: the microphone is off, and a halo would
    // say the opposite.
    if (session.muted) return button;

    return ValueListenableBuilder<double>(
      valueListenable: controller.ownAudioLevel,
      builder: (context, level, child) => TweenAnimationBuilder<double>(
        key: const Key('call-own-level'),
        tween: Tween<double>(end: level.clamp(0.0, 1.0)),
        duration: const Duration(milliseconds: 180),
        builder: (context, shown, _) => Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            Container(
              width: size + size * 0.32 * shown,
              height: size + size * 0.32 * shown,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: BrandColors.success.withValues(alpha: 0.35 * shown),
              ),
            ),
            child!,
          ],
        ),
      ),
      child: button,
    );
  }
}

/// "No estamos recibiendo su audio", when the other side's microphone never
/// arrives.
///
/// Silence on a call is the hardest thing to explain to somebody standing on
/// a roadside: this says whose silence it is, rather than leaving them
/// tapping the volume.
class _PeerAudioNotice extends StatelessWidget {
  const _PeerAudioNotice({required this.controller});

  final CallController controller;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: controller.peerHasAudio,
        builder: (context, arrives, _) => arrives
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.only(top: Insets.xs),
                child: Text(
                  'No estamos recibiendo su audio',
                  key: const Key('call-peer-no-audio'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: BrandColors.warning,
                      ),
                ),
              ),
      );
}

/// The avatar, rippling while the other person speaks.
///
/// Watching the level here rather than in the call screen keeps the rest of
/// the screen still: the rings repaint many times a second, and the name, the
/// timer and the buttons have no reason to rebuild with them.
class _SpeakingAvatar extends StatelessWidget {
  const _SpeakingAvatar({
    required this.name,
    required this.ringing,
    required this.controller,
  });

  final String name;
  final bool ringing;
  final CallController controller;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<double>(
        valueListenable: controller.peerAudioLevel,
        builder: (context, level, _) =>
            _Avatar(name: name, ringing: ringing, level: level),
      );
}

/// The other person's initial, pulsing while it rings.
class _Avatar extends StatefulWidget {
  const _Avatar({
    required this.name,
    required this.ringing,
    this.level = 0,
  });

  final String name;
  final bool ringing;

  /// How loudly the other person is speaking, 0 to 1. Rings ripple out of the
  /// avatar while it is above [_AvatarState._silence].
  final double level;

  @override
  State<_Avatar> createState() => _AvatarState();
}

class _AvatarState extends State<_Avatar> with TickerProviderStateMixin {
  /// Below this, somebody is not talking — a room is never silent, and rings
  /// that answer to the hum of a highway say nothing.
  static const _silence = 0.06;

  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  /// One turn of the ripple: each ring is born at the avatar's edge and fades
  /// as it travels out.
  late final AnimationController _ripple = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_Avatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ringing != widget.ringing ||
        (oldWidget.level > _silence) != (widget.level > _silence)) {
      _sync();
    }
  }

  void _sync() {
    if (widget.ringing) {
      _pulse.repeat(reverse: true);
    } else {
      _pulse
        ..stop()
        ..value = 0;
    }
    // Kept running while they speak; stopped where it started, so the next
    // word begins from the avatar's edge rather than mid-flight.
    if (widget.level > _silence) {
      if (!_ripple.isAnimating) _ripple.repeat();
    } else {
      _ripple
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    _ripple.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final initial = widget.name.trim().isEmpty
        ? '?'
        : widget.name.trim().characters.first.toUpperCase();

    final avatar = AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) => Container(
        width: 132,
        height: 132,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: BrandColors.red.withValues(alpha: 0.35 * _pulse.value),
              blurRadius: 12 + 28 * _pulse.value,
              spreadRadius: 4 + 14 * _pulse.value,
            ),
          ],
        ),
        child: child,
      ),
      child: CircleAvatar(
        backgroundColor: BrandColors.red,
        child: Text(
          initial,
          style: Theme.of(context)
              .textTheme
              .displaySmall
              ?.copyWith(color: BrandColors.white),
        ),
      ),
    );

    // The rings are drawn behind and beyond the avatar's own box, which
    // nothing here clips, so the layout does not jump when somebody speaks.
    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        // Eased rather than followed exactly: the level arrives in steps, and
        // rings that jumped with it would flicker.
        TweenAnimationBuilder<double>(
          key: const Key('call-speaking'),
          tween: Tween<double>(end: widget.level.clamp(0.0, 1.0)),
          duration: const Duration(milliseconds: 220),
          builder: (context, level, _) => AnimatedBuilder(
            animation: _ripple,
            builder: (context, _) => CustomPaint(
              size: const Size.square(132),
              painter: _SpeakingRipple(turn: _ripple.value, level: level),
            ),
          ),
        ),
        avatar,
      ],
    );
  }
}

/// Rings travelling out of the avatar while the other person talks.
///
/// Three of them, evenly spaced around one turn, so there is always one on the
/// way out. How far they reach follows the voice: a quiet reply barely lifts
/// off the avatar, a loud one throws rings wide.
class _SpeakingRipple extends CustomPainter {
  const _SpeakingRipple({required this.turn, required this.level});

  /// Where the ripple is in its loop, 0 to 1.
  final double turn;

  /// How loudly they are speaking, 0 to 1.
  final double level;

  static const _rings = 3;

  @override
  void paint(Canvas canvas, Size size) {
    if (level <= 0) return;
    final centre = size.center(Offset.zero);
    final start = size.width / 2;
    // Reach: half the avatar again at a whisper, twice over at full voice.
    final reach = start * (0.18 + 0.55 * level);

    for (var i = 0; i < _rings; i++) {
      final progress = (turn + i / _rings) % 1;
      final radius = start + reach * progress;
      // Born at full strength, gone by the time it stops travelling.
      final fade = (1 - progress) * (1 - progress);
      canvas.drawCircle(
        centre,
        radius,
        Paint()
          ..color = BrandColors.red.withValues(alpha: 0.45 * fade * level)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 + 2 * level,
      );
    }
  }

  @override
  bool shouldRepaint(_SpeakingRipple old) =>
      old.turn != turn || old.level != level;
}

/// "Llamando…", "Llamada entrante", the running time, or how it ended.
class _Status extends StatefulWidget {
  const _Status({required this.session});

  final CallSession session;

  @override
  State<_Status> createState() => _StatusState();
}

class _StatusState extends State<_Status> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_Status oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session.phase != widget.session.phase) _sync();
  }

  void _sync() {
    _tick?.cancel();
    _tick = null;
    if (widget.session.phase == CallPhase.active) {
      // Repaints the timer; the time itself comes from `connectedAt`.
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final label = switch (session.phase) {
      CallPhase.outgoing => 'Llamando…',
      CallPhase.incoming =>
        session.video ? 'Videollamada entrante' : 'Llamada entrante',
      CallPhase.connecting => 'Conectando…',
      CallPhase.active => _elapsed(session.connectedAt),
      CallPhase.ended => session.message ?? 'Llamada terminada',
      CallPhase.idle => '',
    };

    return Text(
      label,
      key: const Key('call-status'),
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: session.phase == CallPhase.ended
                ? BrandColors.grey200
                : BrandColors.white.withValues(alpha: 0.8),
          ),
    );
  }

  static String _elapsed(DateTime? since) {
    if (since == null) return '00:00';
    final seconds = DateTime.now().difference(since).inSeconds.clamp(0, 86400);
    final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
    final rest = (seconds % 60).toString().padLeft(2, '0');
    return '$minutes:$rest';
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.session, required this.controller});

  final CallSession session;
  final CallController controller;

  @override
  Widget build(BuildContext context) {
    return switch (session.phase) {
      CallPhase.incoming => Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _RoundButton(
              key: const Key('call-decline'),
              icon: Icons.call_end,
              label: 'Rechazar',
              color: BrandColors.red,
              onTap: () => unawaited(controller.decline()),
            ),
            _RoundButton(
              key: const Key('call-answer'),
              icon: session.video ? Icons.videocam : Icons.call,
              label: 'Contestar',
              color: BrandColors.success,
              onTap: () => unawaited(controller.answer()),
            ),
          ],
        ),
      CallPhase.active => Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _MicButton(session: session, controller: controller),
            if (session.canSwitchSpeaker)
              _RoundButton(
                key: const Key('call-speaker'),
                icon: session.speaker ? Icons.volume_up : Icons.volume_down,
                label: 'Altavoz',
                color: session.speaker ? BrandColors.white : BrandColors.grey600,
                iconColor: session.speaker ? BrandColors.ink : BrandColors.white,
                onTap: () => unawaited(controller.toggleSpeaker()),
              ),
            _RoundButton(
              key: const Key('call-hangup'),
              icon: Icons.call_end,
              label: 'Colgar',
              color: BrandColors.red,
              onTap: () => unawaited(controller.hangUp()),
            ),
          ],
        ),
      CallPhase.outgoing || CallPhase.connecting => Center(
          child: _RoundButton(
            key: const Key('call-hangup'),
            icon: Icons.call_end,
            label: 'Colgar',
            color: BrandColors.red,
            onTap: () => unawaited(controller.hangUp()),
          ),
        ),
      // Nothing to press: the message is the whole screen for a moment.
      CallPhase.ended || CallPhase.idle => const SizedBox(height: 96),
    };
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.iconColor = BrandColors.white,
    this.size = 68,
    super.key,
  });

  final IconData icon;
  final String label;
  final Color color;
  final Color iconColor;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: color,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: SizedBox(
                width: size,
                height: size,
                child: Icon(icon, color: iconColor, size: size * 0.44),
              ),
            ),
          ),
          const SizedBox(height: Insets.sm),
          Text(
            label,
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(color: BrandColors.white),
          ),
        ],
      ),
    );
  }
}
