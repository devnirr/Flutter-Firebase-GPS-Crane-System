import 'package:flutter/material.dart';

import '../brand.dart';

/// The banner that drops in over whatever is on screen when something arrives.
///
/// Shared by both apps so a message announces itself the same way on either
/// side. It carries no opinion about what it is announcing: the caller hands
/// it the words, the glyph, and what tapping it should do.
class NotificationBanner extends StatelessWidget {
  const NotificationBanner({
    required this.id,
    required this.title,
    required this.body,
    required this.leading,
    required this.onOpen,
    required this.onClose,
    super.key,
  });

  /// Distinguishes one banner from the next for the swipe-away gesture.
  final String id;
  final String title;
  final String body;
  final Widget leading;
  final VoidCallback onOpen;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Dismissible(
      key: ValueKey('toast-$id'),
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
                leading,
                const SizedBox(width: Insets.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleSmall,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        body,
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

/// The round glyph that says what a notification is about.
class NotificationGlyph extends StatelessWidget {
  const NotificationGlyph({
    required this.icon,
    required this.color,
    required this.background,
    super.key,
  });

  final IconData icon;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(color: background, shape: BoxShape.circle),
      child: Icon(icon, size: 20, color: color),
    );
  }
}
