import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';
import '../chat/chat_list_screen.dart';
import '../notifications/client_notifications.dart';

/// The frame around every signed-in page: the four tabs, the bar that switches
/// between them, and the banner that announces what arrives.
///
/// Inicio is the map, and it keeps the two things a stranded customer needs
/// fastest — the search for grúas nearby and "PEDIR GRÚA 24/7". Servicios is
/// the history with its invoices, Chat every conversation, Perfil the account.
/// Each tab keeps its own state and scroll position, so a customer who steps
/// away to check an invoice comes back to the map exactly as they left it.
class ClientShell extends ConsumerStatefulWidget {
  const ClientShell({required this.navigationShell, super.key});

  final StatefulNavigationShell navigationShell;

  @override
  ConsumerState<ClientShell> createState() => _ClientShellState();
}

class _ClientShellState extends ConsumerState<ClientShell> {
  static const _toastDuration = Duration(seconds: 5);

  ClientNotification? _toast;
  Timer? _toastTimer;

  StatefulNavigationShell get _shell => widget.navigationShell;

  @override
  void dispose() {
    _toastTimer?.cancel();
    super.dispose();
  }

  void _showToast(ClientNotification notification) {
    _toastTimer?.cancel();
    setState(() => _toast = notification);
    _toastTimer = Timer(_toastDuration, _hideToast);
  }

  void _hideToast() {
    _toastTimer?.cancel();
    _toastTimer = null;
    if (mounted && _toast != null) setState(() => _toast = null);
  }

  /// Acts once the current notification has finished: a listener can fire
  /// while the tree is building, which is no moment to navigate or rebuild.
  void _later(VoidCallback action) {
    unawaited(
      Future.microtask(() {
        if (mounted) action();
      }),
    );
  }

  /// The banner leads where the thing it announced is. The customer has no
  /// list of notifications to land in — one tap, and they are in the
  /// conversation.
  void _open(ClientNotification notification) {
    _hideToast();
    unawaited(
      context.push(
        notification.isRequest
            ? Routes.chatRequestFor(notification.targetId)
            : Routes.chatFor(notification.targetId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<List<ClientNotification>>(clientNotificationsProvider, (
      previous,
      next,
    ) {
      if (next.isEmpty) return;
      final newest = next.first;
      if (previous != null &&
          previous.isNotEmpty &&
          previous.first.id == newest.id) {
        return;
      }
      _later(() => _showToast(newest));
    });

    final toast = _toast;

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          _shell,
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: AnimatedSwitcher(
                duration: Motion.normal,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween(
                      begin: const Offset(0, -0.4),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                child: toast == null
                    ? const SizedBox.shrink()
                    : Padding(
                        key: ValueKey(toast.id),
                        padding: const EdgeInsets.fromLTRB(
                          Insets.gutter,
                          Insets.sm,
                          Insets.gutter,
                          0,
                        ),
                        child: NotificationBanner(
                          id: toast.id,
                          title: toast.title,
                          body: toast.body,
                          leading: ClientNotificationGlyph(kind: toast.kind),
                          onClose: _hideToast,
                          onOpen: () => _open(toast),
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: _BottomBar(
        currentIndex: _shell.currentIndex,
        unread: ref.watch(clientChatAttentionProvider),
        // Tapping the tab already open takes it back to its first page.
        onSelected: (index) => _shell.goBranch(
          index,
          initialLocation: index == _shell.currentIndex,
        ),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.currentIndex,
    required this.unread,
    required this.onSelected,
  });

  final int currentIndex;
  final int unread;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return DecoratedBox(
      decoration: const BoxDecoration(
        color: BrandColors.white,
        border: Border(top: BorderSide(color: BrandColors.grey100)),
      ),
      child: NavigationBarTheme(
        data: NavigationBarThemeData(
          backgroundColor: BrandColors.white,
          surfaceTintColor: Colors.transparent,
          indicatorColor: BrandColors.redTint,
          height: 68,
          elevation: 0,
          iconTheme: WidgetStateProperty.resolveWith(
            (states) => IconThemeData(
              size: 24,
              color: states.contains(WidgetState.selected)
                  ? BrandColors.red
                  : BrandColors.grey600,
            ),
          ),
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            final selected = states.contains(WidgetState.selected);
            return text.labelMedium?.copyWith(
              color: selected ? BrandColors.red : BrandColors.grey600,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              letterSpacing: 0,
            );
          }),
        ),
        child: NavigationBar(
          selectedIndex: currentIndex,
          onDestinationSelected: onSelected,
          destinations: [
            const NavigationDestination(
              icon: Icon(Icons.map_outlined),
              selectedIcon: Icon(Icons.map),
              label: 'Inicio',
            ),
            const NavigationDestination(
              icon: Icon(Icons.receipt_long_outlined),
              selectedIcon: Icon(Icons.receipt_long),
              label: 'Servicios',
            ),
            NavigationDestination(
              icon: _Counted(
                count: unread,
                child: const Icon(Icons.chat_bubble_outline),
              ),
              selectedIcon: _Counted(
                count: unread,
                child: const Icon(Icons.chat_bubble),
              ),
              label: 'Chat',
            ),
            const NavigationDestination(
              icon: Icon(Icons.person_outline),
              selectedIcon: Icon(Icons.person),
              label: 'Perfil',
            ),
          ],
        ),
      ),
    );
  }
}

/// An icon with a red count on its corner, hidden at zero.
class _Counted extends StatelessWidget {
  const _Counted({required this.count, required this.child});

  final int count;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Badge.count(
      key: const Key('chat-badge'),
      count: count,
      isLabelVisible: count > 0,
      backgroundColor: BrandColors.red,
      textColor: BrandColors.white,
      child: child,
    );
  }
}
