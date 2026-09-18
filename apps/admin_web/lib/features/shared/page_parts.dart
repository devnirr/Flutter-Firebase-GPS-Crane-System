import 'package:flutter/material.dart';
import 'package:grua_core/grua_core.dart';

/// Pieces the panel's pages share, so Efectivo, Facturación and the
/// aseguradora pages read as one product rather than three.

/// The way back to the page this one was opened from, at the left of the
/// page's title.
///
/// A line of its own above the title pushed the heading down and read as a
/// stray link; beside it, it reads as what it is — the way out of this page.
class PageBackButton extends StatelessWidget {
  const PageBackButton({
    required this.onPressed,
    required this.tooltip,
    super.key,
  });

  final VoidCallback onPressed;

  /// Says where it goes, since the arrow alone does not.
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      icon: const Icon(Icons.arrow_back, size: 20),
      style: IconButton.styleFrom(
        foregroundColor: palette.text,
        backgroundColor: palette.surface,
        side: BorderSide(color: palette.border),
        minimumSize: const Size(40, 40),
      ),
    );
  }
}

/// The figures across the top of a page: one line when they fit, otherwise a
/// balanced grid — six tiles in room for four become three and three, not
/// four and a straggling two.
///
/// Every tile in a line is as tall as the tallest and as wide as the others,
/// and the grid spans the full width, so its edges line up with the cards
/// below it whatever the window.
class StatRow extends StatelessWidget {
  const StatRow({required this.children, super.key});

  final List<Widget> children;

  /// Below this per tile, a figure like "RD$ 1,234,567.00" stops fitting.
  static const _minTileWidth = 250.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final fit =
          ((constraints.maxWidth + Insets.lg) / (_minTileWidth + Insets.lg))
              .floor()
              .clamp(1, children.length);
      final lines = (children.length / fit).ceil();
      final perLine = (children.length / lines).ceil();

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var line = 0; line < lines; line++) ...[
            if (line > 0) const SizedBox(height: Insets.lg),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var column = 0; column < perLine; column++) ...[
                    if (column > 0) const SizedBox(width: Insets.lg),
                    Expanded(
                      // An empty slot on a short last line keeps its tiles
                      // the same width as the ones above them.
                      child: line * perLine + column < children.length
                          ? children[line * perLine + column]
                          : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      );
    },
  );
}

/// One figure: an icon in a tinted circle, what it counts, the number in the
/// colour that says how to read it, and an optional line under it.
class StatTile extends StatelessWidget {
  const StatTile({
    required this.icon,
    required this.label,
    required this.value,
    this.detail = '',
    this.color,
    super.key,
  });

  final IconData icon;
  final String label;
  final String value;
  final String detail;

  /// Null for a plain figure. A colour both tints the icon and colours the
  /// number, so the tile reads as one thing rather than two.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final tone = color ?? palette.textMuted;

    return FloatingCard(
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: tone.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 21, color: tone),
          ),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // One line, always: a label that wrapped made its tile taller
                // than the ones beside it.
                Text(
                  label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.labelSmall?.copyWith(color: palette.textMuted),
                ),
                const SizedBox(height: Insets.xxs),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.headlineSmall?.copyWith(
                    color: color ?? palette.text,
                  ),
                ),
                if (detail.isNotEmpty)
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(color: palette.textMuted),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A titled card whose rows run edge to edge with a line between them.
///
/// Rows pad themselves, so their dividers and their hover reach the card's
/// edges instead of stopping short inside its padding.
class ListCard extends StatelessWidget {
  const ListCard({
    required this.children,
    this.title,
    this.trailing,
    super.key,
  });

  final String? title;

  /// Beside the title: a count, a button.
  final Widget? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return FloatingCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Insets.lg,
                Insets.lg,
                Insets.lg,
                Insets.sm,
              ),
              child: Row(
                children: [
                  Expanded(child: Text(title!, style: text.titleMedium)),
                  ?trailing,
                ],
              ),
            ),
            const Divider(height: 1),
          ],
          for (final (index, child) in children.indexed) ...[
            if (index > 0) const Divider(height: 1),
            child,
          ],
        ],
      ),
    );
  }
}
