import 'package:flutter/material.dart';
import 'package:grua_core/grua_core.dart';

/// What a toast is telling you, which decides its icon and its colour.
enum ToastTone {
  /// It happened. "Código copiado", "Factura emitida".
  success,

  /// It did not happen, and the office has to do something about it.
  error,

  /// It happened, with a caveat worth reading.
  warning,

  /// A plain acknowledgement with nothing at stake.
  info,
}

/// The panel's one way of saying something briefly.
///
/// It lands at the top middle of the window rather than in the bottom-left
/// corner where Material puts it by default. A dispatcher's eyes are on the
/// map, the queue or the dialog they just acted in — all of which are in the
/// upper half of the screen — and the default bar also runs the full width of
/// the window over whatever it covers, which reads as a system failure rather
/// than a confirmation.
///
/// It goes through [ScaffoldMessenger] rather than a hand-rolled overlay, so
/// one message replaces the last, it leaves on its own, and it is torn down
/// with the route that raised it.
void showToast(
  BuildContext context,
  String message, {
  ToastTone tone = ToastTone.success,
  Duration? duration,
}) =>
    Toaster.of(context).show(message, tone: tone, duration: duration);

/// A toast that can still be shown after an `await`.
///
/// Built from the context **before** the gap — `final toast = Toaster.of(context);`
/// — so a callable's answer can be announced without reaching for a
/// [BuildContext] that may be gone by then.
@immutable
class Toaster {
  const Toaster._(this._messenger, this._palette, this._text);

  factory Toaster.of(BuildContext context) => Toaster._(
        ScaffoldMessenger.of(context),
        context.palette,
        Theme.of(context).textTheme,
      );

  final ScaffoldMessengerState _messenger;
  final BrandPalette _palette;
  final TextTheme _text;

  void show(
    String message, {
    ToastTone tone = ToastTone.success,
    Duration? duration,
  }) {
    _messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          // The bar itself is only a carrier: it keeps its place at the bottom
          // of the window while the card below lifts itself to the top. Doing
          // it this way rather than with a margin means the position is worked
          // out on every build, so a window resized while a toast is up does
          // not leave it wedged off-screen.
          content: _TopToast(
            message: message,
            tone: tone,
            palette: _palette,
            text: _text,
          ),
          backgroundColor: Colors.transparent,
          elevation: 0,
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.zero,
          padding: EdgeInsets.zero,
          shape: const RoundedRectangleBorder(),
          // Up, because that is the way it leaves on its own.
          dismissDirection: DismissDirection.up,
          duration: duration ??
              (tone == ToastTone.error
                  ? const Duration(seconds: 5)
                  : const Duration(seconds: 3)),
        ),
      );
  }
}

/// The card itself: centred near the top of the window, whatever size the
/// window is at this frame.
class _TopToast extends StatelessWidget {
  const _TopToast({
    required this.message,
    required this.tone,
    required this.palette,
    required this.text,
  });

  final String message;
  final ToastTone tone;
  final BrandPalette palette;
  final TextTheme text;

  /// A card this size reads in one glance and never spans the window.
  static const _width = 460.0;
  static const _fromTop = 18.0;

  /// What the carrier bar itself takes up at the bottom of the window.
  static const _carrierHeight = 76.0;

  @override
  Widget build(BuildContext context) {
    final (color, icon) = switch (tone) {
      ToastTone.success => (palette.success, Icons.check_circle_outline),
      ToastTone.error => (palette.danger, Icons.error_outline),
      ToastTone.warning => (palette.warning, Icons.warning_amber_outlined),
      ToastTone.info => (palette.info, Icons.info_outline),
    };
    final window = MediaQuery.sizeOf(context);

    // The carrier sits at the bottom of the window; this is the trip up to
    // the top, worked out fresh on every build.
    return Transform.translate(
      offset: Offset(0, -(window.height - _fromTop - _carrierHeight)),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _width),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.lg,
              vertical: Insets.md,
            ),
            decoration: BoxDecoration(
              color: palette.surfaceRaised,
              borderRadius: Corners.brMd,
              border: Border.all(color: palette.border),
              boxShadow: Shadows.floating,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 20, color: color),
                const SizedBox(width: Insets.md),
                Flexible(
                  child: Text(
                    message,
                    style: text.bodyMedium?.copyWith(color: palette.text),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
