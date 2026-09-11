import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

/// Tells the office this chofer has the app open, for as long as they are
/// signed in and it is running.
///
/// Watched from the app root rather than a screen, so it holds on the blocked
/// screen and the service screen alike: "the chofer can be reached" does not
/// depend on which page they are looking at. It is not the online switch —
/// a chofer with no grúa, or one on a break, is still connected.
final appPresenceProvider = Provider<void>((ref) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return;

  final subscription =
      ref.watch(driverRepositoryProvider).holdAppPresence(uid).listen(
            null,
            // Rules not deployed yet, or no signal: the office sees the chofer
            // as disconnected, which is wrong but harmless. Not worth a crash.
            onError: (Object error) => debugPrint('App presence: $error'),
          );
  ref.onDispose(() => unawaited(subscription.cancel()));
});

/// Signs the chofer out, clearing their presence first.
///
/// The order matters: once the session is gone the rules refuse the write, and
/// the office would see a signed-out chofer as connected until the connection
/// itself closed.
Future<void> signOutDriver(WidgetRef ref) async {
  final uid = ref.read(currentUserIdProvider);
  if (uid != null) {
    await ref.read(driverRepositoryProvider).clearAppPresence(uid);
  }
  await ref.read(authRepositoryProvider).signOut();
}
