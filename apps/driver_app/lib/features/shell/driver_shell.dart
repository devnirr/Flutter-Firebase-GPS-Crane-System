import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';
import '../home/location_publisher.dart';
import '../home/offer_card.dart';
import '../notifications/driver_notifications.dart';
import '../notifications/notification_widgets.dart';
import '../orders/orders_screen.dart';

/// The frame around every signed-in page: the tabs, the bar that switches
/// between them, and the banner that announces what arrives.
///
/// Inicio is the map and the online switch, Pedidos the open work, Chat the
/// conversation with the customer, Perfil the account. Each tab keeps its own
/// state and scroll position while another is on screen, so a chofer who
/// glances at a message comes back to the map exactly as they left it.
///
/// Two things are allowed to take the chofer off whatever tab they chose,
/// because both are work the chofer cannot afford to miss: an offer, which
/// lapses in 25 seconds, and a job starting, which belongs on the service
/// screen. Anything else that arrives — open work, a customer's message —
/// drops in as a banner and waits under the bell.
class DriverShell extends ConsumerStatefulWidget {
  const DriverShell({required this.navigationShell, super.key});

  final StatefulNavigationShell navigationShell;

  @override
  ConsumerState<DriverShell> createState() => _DriverShellState();
}

class _DriverShellState extends ConsumerState<DriverShell> {
  static const int _inicio = 0;
  static const _toastDuration = Duration(seconds: 5);

  DriverNotification? _toast;
  Timer? _toastTimer;

  StatefulNavigationShell get _shell => widget.navigationShell;

  @override
  void dispose() {
    _toastTimer?.cancel();
    super.dispose();
  }

  void _showToast(DriverNotification notification) {
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

  @override
  Widget build(BuildContext context) {
    ref
      // Watched here rather than on a screen: position publishing follows the
      // chofer's online state, and must not stop because they opened a tab.
      ..watch(locationPublisherProvider)
      ..listen<Offer?>(openOfferProvider, (previous, next) {
        if (next == null || next.serviceId == previous?.serviceId) return;
        if (_shell.currentIndex != _inicio) {
          _later(() => _shell.goBranch(_inicio));
        }
      })
      ..listen<String?>(
        activeDriverServiceProvider.select((service) => service.value?.id),
        (previous, next) {
          if (next == null || next == previous) return;
          // Accepting from Pedidos, or the office assigning a job, lands on
          // the service screen wherever the chofer was.
          _later(() => context.go(Routes.activeService));
        },
      )
      ..listen<List<DriverNotification>>(driverNotificationsProvider, (
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
        // An offer needs no banner: it takes over Inicio on its own.
        if (newest.kind == DriverNotificationKind.offer) return;
        _later(() => _showToast(newest));
      });

    final online = ref.watch(
      currentDriverProvider.select((driver) => driver.value?.isOnline ?? false),
    );
    final orders = online ? ref.watch(availableOrdersProvider).length : 0;
    final activeId = ref.watch(
      activeDriverServiceProvider.select((s) => s.value?.id),
    );
    final unread = activeId == null
        ? 0
        : ref.watch(unreadMessageCountProvider(activeId));
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
                          Insets.lg,
                          Insets.sm,
                          Insets.lg,
                          0,
                        ),
                        child: NotificationToast(
                          notification: toast,
                          onClose: _hideToast,
                          onOpen: () {
                            _hideToast();
                            unawaited(context.push(Routes.notifications));
                          },
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: _BottomBar(
        currentIndex: _shell.currentIndex,
        orders: orders,
        unread: unread,
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
    required this.orders,
    required this.unread,
    required this.onSelected,
  });

  final int currentIndex;
  final int orders;
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
            NavigationDestination(
              icon: _Counted(
                count: orders,
                badgeKey: const Key('orders-badge'),
                child: const Icon(Icons.receipt_long_outlined),
              ),
              selectedIcon: _Counted(
                count: orders,
                badgeKey: const Key('orders-badge'),
                child: const Icon(Icons.receipt_long),
              ),
              label: 'Pedidos',
            ),
            NavigationDestination(
              icon: _Counted(
                count: unread,
                badgeKey: const Key('chat-badge'),
                child: const Icon(Icons.chat_bubble_outline),
              ),
              selectedIcon: _Counted(
                count: unread,
                badgeKey: const Key('chat-badge'),
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
  const _Counted({
    required this.count,
    required this.badgeKey,
    required this.child,
  });

  final int count;
  final Key badgeKey;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Badge.count(
      key: badgeKey,
      count: count,
      isLabelVisible: count > 0,
      backgroundColor: BrandColors.red,
      textColor: BrandColors.white,
      child: child,
    );
  }
}
