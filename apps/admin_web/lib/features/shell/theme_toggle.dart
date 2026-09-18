import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

/// The light / dark control in the top bar.
///
/// The sun or moon flips the skin — what somebody reaching for it at 2 a.m.
/// wants — and the caret beside it opens the three choices, including
/// following the machine's own setting.
class ThemeModeButton extends ConsumerWidget {
  const ThemeModeButton({this.onDark = false, super.key});

  /// True where the control sits on a dark header rather than on a surface.
  final bool onDark;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
    final mode = ref.watch(themeModeProvider);
    final showing = Theme.of(context).brightness;
    final foreground = onDark ? BrandColors.white : palette.textStrong;
    final muted = onDark
        ? BrandColors.white.withValues(alpha: 0.7)
        : palette.textFaint;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const Key('theme-toggle'),
          onPressed: () => ref.read(themeModeProvider.notifier).toggle(showing),
          tooltip: showing == Brightness.dark
              ? 'Cambiar a tema claro'
              : 'Cambiar a tema oscuro',
          iconSize: 19,
          visualDensity: VisualDensity.compact,
          icon: Icon(
            showing == Brightness.dark
                ? Icons.dark_mode_outlined
                : Icons.light_mode_outlined,
            color: foreground,
          ),
        ),
        PopupMenuButton<ThemeMode>(
          key: const Key('theme-menu'),
          tooltip: 'Tema: ${mode.spanishLabel}',
          position: PopupMenuPosition.under,
          onSelected: (chosen) =>
              ref.read(themeModeProvider.notifier).set(chosen),
          itemBuilder: (context) => [
            for (final option in ThemeMode.values)
              PopupMenuItem(
                key: Key('theme-${option.storedName}'),
                value: option,
                child: Row(
                  children: [
                    Icon(option.icon, size: 18, color: palette.textStrong),
                    const SizedBox(width: Insets.md),
                    Expanded(child: Text(option.spanishLabel)),
                    if (option == mode)
                      Icon(Icons.check, size: 16, color: palette.brand),
                  ],
                ),
              ),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Insets.sm),
            child: Icon(Icons.expand_more, size: 15, color: muted),
          ),
        ),
      ],
    );
  }
}
