import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'driver_notifications.dart';

/// Wraps an open conversation and keeps the bell honest about it.
///
/// While this is on screen, every notification belonging to [targetId] counts
/// as read — the one that announced the message being read right now, and any
/// that arrive while the chofer is still in the conversation.
class MarkThreadRead extends ConsumerStatefulWidget {
  const MarkThreadRead({
    required this.targetId,
    required this.child,
    super.key,
  });

  /// The service or the chat request this conversation belongs to.
  final String targetId;
  final Widget child;

  @override
  ConsumerState<MarkThreadRead> createState() => _MarkThreadReadState();
}

class _MarkThreadReadState extends ConsumerState<MarkThreadRead> {
  @override
  void initState() {
    super.initState();
    _clear();
  }

  /// After the frame: this runs from build and from a provider's notification,
  /// and neither is a moment to write to another provider.
  void _clear() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(driverNotificationsProvider.notifier)
          .markThreadRead(widget.targetId);
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(driverNotificationsProvider, (_, _) => _clear());
    return widget.child;
  }
}
