import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

import 'app_presence.dart';

/// "Cerrar sesión", with a spinner while it runs.
///
/// Signing out makes two server calls before the session ends, which takes a
/// moment on a slow connection; without a spinner the button looks dead and
/// gets tapped again. The router moves on once the session is gone, so the
/// spinner simply stays until this screen is replaced.
class SignOutButton extends ConsumerStatefulWidget {
  const SignOutButton({this.outlined = false, this.enabled = true, super.key});

  /// An outlined button rather than a text one.
  final bool outlined;

  /// False while something else on the screen is still running.
  final bool enabled;

  @override
  ConsumerState<SignOutButton> createState() => _SignOutButtonState();
}

class _SignOutButtonState extends ConsumerState<SignOutButton> {
  var _busy = false;

  Future<void> _signOut() async {
    setState(() => _busy = true);
    try {
      await signOutDriver(ref);
    } on Object {
      // Still signed in: give the button back so it can be tried again.
      if (mounted) setState(() => _busy = false);
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    final onPressed = widget.enabled && !_busy ? _signOut : null;
    final child = _busy
        ? SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              color: widget.outlined ? BrandColors.ink : BrandColors.red,
            ),
          )
        : const Text('Cerrar sesión');

    return widget.outlined
        ? OutlinedButton(onPressed: onPressed, child: child)
        : TextButton(onPressed: onPressed, child: child);
  }
}
