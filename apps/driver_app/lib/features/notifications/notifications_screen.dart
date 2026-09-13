import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';
import '../home/offer_card.dart';
import 'driver_notifications.dart';
import 'notification_widgets.dart';

/// Everything that arrived this session, newest first.
///
/// Opening the page clears the bell, the way a chofer expects a pile of
/// notifications to behave once looked at; what was new keeps its highlight
/// until they leave, so they can still tell which ones those were. Each entry
/// leads to the thing it announced.
class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() =>
      _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  late final Set<String> _newAtOpen;

  @override
  void initState() {
    super.initState();
    _newAtOpen = {
      for (final n in ref.read(driverNotificationsProvider))
        if (!n.read) n.id,
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(driverNotificationsProvider.notifier).markAllRead();
    });
  }

  void _open(DriverNotification notification) {
    ref.read(driverNotificationsProvider.notifier).markRead(notification.id);

    switch (notification.kind) {
      case DriverNotificationKind.offer:
        // An offer is short-lived; one that has gone would lead to a
        // map with nothing on it, so say so instead.
        final open = ref.read(openOfferProvider);
        if (open?.serviceId != notification.targetId) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Esta solicitud ya no está disponible.'),
            ),
          );
          return;
        }
        context.go(Routes.home);
      case DriverNotificationKind.order:
        context.go(Routes.orders);
      case DriverNotificationKind.chat:
        unawaited(context.push(Routes.chatFor(notification.targetId)));
      case DriverNotificationKind.chatRequest ||
          DriverNotificationKind.requestMessage:
        unawaited(context.push(Routes.chatRequestFor(notification.targetId)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final notifications = ref.watch(driverNotificationsProvider);

    return Scaffold(
      backgroundColor: BrandColors.offWhite,
      appBar: AppBar(title: const Text('Notificaciones')),
      body: notifications.isEmpty
          ? const EmptyState(
              title: 'Sin notificaciones',
              message:
                  'Aquí verás las solicitudes nuevas y los mensajes de '
                  'tus clientes.',
              icon: Icons.notifications_none,
            )
          : ListView.separated(
              padding: const EdgeInsets.all(Insets.lg),
              itemCount: notifications.length,
              separatorBuilder: (_, _) => const SizedBox(height: Insets.sm),
              itemBuilder: (context, index) {
                final notification = notifications[index];
                return _NotificationTile(
                  notification: notification,
                  highlighted:
                      !notification.read ||
                      _newAtOpen.contains(notification.id),
                  onTap: () => _open(notification),
                );
              },
            ),
    );
  }
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({
    required this.notification,
    required this.highlighted,
    required this.onTap,
  });

  final DriverNotification notification;
  final bool highlighted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return FloatingCard(
      onTap: onTap,
      padding: const EdgeInsets.all(Insets.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          NotificationKindIcon(kind: notification.kind),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        notification.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleSmall?.copyWith(
                          fontWeight: highlighted ? FontWeight.w700 : null,
                        ),
                      ),
                    ),
                    const SizedBox(width: Insets.sm),
                    Text(
                      DoTime.relative(notification.at),
                      style: text.bodySmall?.copyWith(
                        color: BrandColors.grey400,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  notification.body,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(
                    color: highlighted ? BrandColors.ink : BrandColors.grey600,
                  ),
                ),
              ],
            ),
          ),
          if (highlighted) ...[
            const SizedBox(width: Insets.sm),
            Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.only(top: Insets.xs),
              decoration: const BoxDecoration(
                color: BrandColors.red,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
