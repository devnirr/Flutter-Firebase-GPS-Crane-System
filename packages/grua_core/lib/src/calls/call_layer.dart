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
                          child: _Avatar(
                            name: name,
                            ringing: session.phase == CallPhase.outgoing,
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
        _RoundButton(
          key: const Key('call-mute'),
          icon: session.muted ? Icons.mic_off : Icons.mic_none,
          label: 'Micrófono',
          color: session.muted ? BrandColors.white : BrandColors.grey600,
          iconColor: session.muted ? BrandColors.ink : BrandColors.white,
          size: 60,
          onTap: () => unawaited(controller.toggleMute()),
        ),
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
              _Avatar(name: name, ringing: _isRinging(session.phase)),
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

/// The other person's initial, pulsing while it rings.
class _Avatar extends StatefulWidget {
  const _Avatar({required this.name, required this.ringing});

  final String name;
  final bool ringing;

  @override
  State<_Avatar> createState() => _AvatarState();
}

class _AvatarState extends State<_Avatar> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_Avatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ringing != widget.ringing) _sync();
  }

  void _sync() {
    if (widget.ringing) {
      _pulse.repeat(reverse: true);
    } else {
      _pulse
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final initial = widget.name.trim().isEmpty
        ? '?'
        : widget.name.trim().characters.first.toUpperCase();

    return AnimatedBuilder(
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
  }
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
            _RoundButton(
              key: const Key('call-mute'),
              icon: session.muted ? Icons.mic_off : Icons.mic_none,
              label: session.muted ? 'Activar micrófono' : 'Silenciar',
              color: session.muted ? BrandColors.white : BrandColors.grey600,
              iconColor: session.muted ? BrandColors.ink : BrandColors.white,
              onTap: () => unawaited(controller.toggleMute()),
            ),
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
