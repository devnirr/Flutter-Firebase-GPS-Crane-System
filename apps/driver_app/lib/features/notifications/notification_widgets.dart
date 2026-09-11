import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';
import 'driver_notifications.dart';

/// The bell, with the unread count on its corner. Opens the notification page.
///
/// Two looks: a white card floating over the map beside the Inicio header, and
/// a plain white icon on the service screen's red header.
class NotificationBell extends ConsumerWidget {
  const NotificationBell({this.onDark = false, super.key});

  final bool onDark;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(unreadNotificationCountProvider);

    final icon = Badge.count(
      key: const Key('notifications-badge'),
      count: unread,
      isLabelVisible: unread > 0,
      backgroundColor: onDark ? BrandColors.white : BrandColors.red,
      textColor: onDark ? BrandColors.red : BrandColors.white,
      child: Icon(
        unread > 0
            ? Icons.notifications_active_outlined
            : Icons.notifications_none,
        color: onDark ? BrandColors.white : BrandColors.ink,
      ),
    );

    void open() => context.push(Routes.notifications);

    if (onDark) {
      return IconButton(
        key: const Key('notifications-button'),
        tooltip: 'Notificaciones',
        onPressed: open,
        icon: icon,
      );
    }
    return Tooltip(
      message: 'Notificaciones',
      child: SizedBox.square(
        dimension: 56,
        child: FloatingCard(
          key: const Key('notifications-button'),
          padding: EdgeInsets.zero,
          borderRadius: Corners.brMd,
          onTap: open,
          child: Center(child: icon),
        ),
      ),
    );
  }
}

/// The banner that drops in over any tab when something arrives.
class NotificationToast extends StatelessWidget {
  const NotificationToast({
    required this.notification,
    required this.onOpen,
    required this.onClose,
    super.key,
  });

  final DriverNotification notification;
  final VoidCallback onOpen;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Dismissible(
      key: ValueKey('toast-${notification.id}'),
      direction: DismissDirection.up,
      onDismissed: (_) => onClose(),
      child: Material(
        key: const Key('notification-toast'),
        color: BrandColors.white,
        elevation: 8,
        shadowColor: Colors.black38,
        borderRadius: Corners.brMd,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              Insets.md,
              Insets.md,
              Insets.xs,
              Insets.md,
            ),
            child: Row(
              children: [
                NotificationKindIcon(kind: notification.kind),
                const SizedBox(width: Insets.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        notification.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleSmall,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        notification.body,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(
                          color: BrandColors.grey600,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Cerrar',
                  onPressed: onClose,
                  icon: const Icon(
                    Icons.close,
                    size: 20,
                    color: BrandColors.grey400,
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

/// The round icon that says what a notification is about.
class NotificationKindIcon extends StatelessWidget {
  const NotificationKindIcon({required this.kind, super.key});

  final DriverNotificationKind kind;

  @override
  Widget build(BuildContext context) {
    final (icon, color, background) = switch (kind) {
      DriverNotificationKind.offer => (
        Icons.local_shipping,
        BrandColors.red,
        BrandColors.redTint,
      ),
      DriverNotificationKind.order => (
        Icons.receipt_long,
        BrandColors.warning,
        BrandColors.warningTint,
      ),
      DriverNotificationKind.chat => (
        Icons.chat_bubble,
        BrandColors.info,
        BrandColors.infoTint,
      ),
    };

    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(color: background, shape: BoxShape.circle),
      child: Icon(icon, size: 20, color: color),
    );
  }
}
