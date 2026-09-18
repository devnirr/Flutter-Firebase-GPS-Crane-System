import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'brand.dart';
import 'palette.dart';

/// Themes for the three products.
///
/// They share one palette and one type scale; what differs is density. The
/// phone apps are thumb-driven and generous, the admin panel is a dispatcher's
/// workstation and is deliberately tighter.
///
/// Every colour comes from a [BrandPalette], which is carried on the theme as
/// an extension. That is what makes the panel's dark skin one call rather than
/// a second set of screens: [admin] and [adminDark] are the same builder over
/// [BrandPalette.light] and [BrandPalette.dark].
abstract final class AppTheme {
  static const String _fontFamily = 'Roboto';

  /// Client and driver apps: white surfaces, red actions, black text.
  static ThemeData phone() => _base(
        density: VisualDensity.standard,
        palette: BrandPalette.light,
      );

  /// Admin panel: same palette, tighter rows so a dispatcher sees more at once.
  static ThemeData admin() => _adminOf(BrandPalette.light);

  /// The panel at night: same layout and the same red, on near-black.
  static ThemeData adminDark() => _adminOf(BrandPalette.dark);

  /// The panel in one brightness, for a [MaterialApp] that switches skins.
  static ThemeData adminFor(Brightness brightness) =>
      brightness == Brightness.dark ? adminDark() : admin();

  static ThemeData _adminOf(BrandPalette palette) => _base(
        density: VisualDensity.compact,
        palette: palette,
      ).copyWith(scaffoldBackgroundColor: palette.canvas);

  static ThemeData _base({
    required VisualDensity density,
    required BrandPalette palette,
  }) {
    final dark = palette.isDark;
    final scheme = ColorScheme(
      brightness: palette.brightness,
      primary: palette.brand,
      onPrimary: palette.onBrand,
      primaryContainer: palette.brandTint,
      onPrimaryContainer: dark ? palette.text : BrandColors.redDeep,
      secondary: dark ? palette.text : BrandColors.ink,
      onSecondary: dark ? BrandColors.ink : BrandColors.white,
      secondaryContainer: palette.surfaceSubtle,
      onSecondaryContainer: palette.text,
      surface: palette.surface,
      onSurface: palette.text,
      surfaceContainerLowest: palette.surface,
      surfaceContainerLow: palette.canvas,
      surfaceContainer: palette.surfaceSubtle,
      surfaceContainerHigh: palette.surfaceSubtle,
      surfaceContainerHighest: palette.border,
      onSurfaceVariant: palette.textMuted,
      outline: palette.border,
      outlineVariant: palette.borderSubtle,
      error: palette.danger,
      onError: BrandColors.white,
      errorContainer: palette.dangerTint,
      onErrorContainer: dark ? palette.text : BrandColors.redDeep,
      inverseSurface: palette.inverseSurface,
      onInverseSurface: palette.onInverseSurface,
    );

    final text = _textTheme(palette.text);

    return ThemeData(
      useMaterial3: true,
      brightness: palette.brightness,
      colorScheme: scheme,
      fontFamily: _fontFamily,
      visualDensity: density,
      scaffoldBackgroundColor: palette.surface,
      canvasColor: palette.surface,
      textTheme: text,
      splashFactory: InkSparkle.splashFactory,
      extensions: [palette],

      appBarTheme: AppBarTheme(
        backgroundColor: palette.surface,
        foregroundColor: palette.text,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        centerTitle: true,
        titleTextStyle: text.titleLarge,
        systemOverlayStyle:
            dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      ),

      // The full-width red action from every mockup.
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: palette.brand,
          foregroundColor: palette.onBrand,
          disabledBackgroundColor: palette.surfaceSubtle,
          disabledForegroundColor: palette.textFaint,
          minimumSize: const Size.fromHeight(56),
          elevation: 0,
          shape: const RoundedRectangleBorder(borderRadius: Corners.brMd),
          textStyle: const TextStyle(
            fontFamily: _fontFamily,
            fontSize: 17,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.4,
          ),
        ),
      ),

      // Secondary action: a pill with a hairline, as on the tracking screen.
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: palette.text,
          backgroundColor: palette.surface,
          disabledForegroundColor: palette.textFaint,
          minimumSize: const Size.fromHeight(48),
          side: BorderSide(color: palette.border),
          shape: const RoundedRectangleBorder(borderRadius: Corners.brMd),
          textStyle: const TextStyle(
            fontFamily: _fontFamily,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: palette.brand,
          disabledForegroundColor: palette.textFaint,
          textStyle: const TextStyle(
            fontFamily: _fontFamily,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),

      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: palette.textStrong),
      ),

      iconTheme: IconThemeData(color: palette.textStrong),

      // Inputs are flat filled fields with a hairline until focus, matching the
      // request form.
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? palette.surfaceSubtle : palette.surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Insets.lg,
          vertical: Insets.lg,
        ),
        hintStyle: TextStyle(color: palette.textFaint, fontSize: 15),
        labelStyle: TextStyle(color: palette.textMuted, fontSize: 15),
        floatingLabelStyle: TextStyle(color: palette.textMuted, fontSize: 15),
        helperStyle: TextStyle(color: palette.textMuted, fontSize: 12),
        prefixIconColor: palette.textFaint,
        suffixIconColor: palette.textFaint,
        border: OutlineInputBorder(
          borderRadius: Corners.brMd,
          borderSide: BorderSide(color: palette.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: Corners.brMd,
          borderSide: BorderSide(color: palette.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: Corners.brMd,
          borderSide: BorderSide(color: palette.brand, width: 1.6),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: Corners.brMd,
          borderSide: BorderSide(color: palette.borderSubtle),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: Corners.brMd,
          borderSide: BorderSide(color: palette.danger),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: Corners.brMd,
          borderSide: BorderSide(color: palette.danger, width: 1.6),
        ),
      ),

      cardTheme: CardThemeData(
        color: palette.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: const RoundedRectangleBorder(borderRadius: Corners.brLg),
      ),

      chipTheme: ChipThemeData(
        backgroundColor: palette.surfaceSubtle,
        labelStyle: text.labelMedium,
        side: BorderSide.none,
        shape: const RoundedRectangleBorder(borderRadius: Corners.brSm),
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.sm,
          vertical: Insets.xs,
        ),
      ),

      dividerTheme: DividerThemeData(
        color: palette.borderSubtle,
        thickness: 1,
        space: 1,
      ),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: palette.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: Corners.sheet),
        showDragHandle: true,
        dragHandleColor: palette.border,
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: palette.surfaceRaised,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(borderRadius: Corners.brLg),
        titleTextStyle: text.titleLarge,
        contentTextStyle: text.bodyMedium,
      ),

      popupMenuTheme: PopupMenuThemeData(
        color: palette.surfaceRaised,
        surfaceTintColor: Colors.transparent,
        textStyle: text.bodyMedium,
        shape: const RoundedRectangleBorder(borderRadius: Corners.brSm),
      ),

      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(palette.surfaceRaised),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        ),
      ),

      dropdownMenuTheme: DropdownMenuThemeData(
        textStyle: text.bodyMedium,
        menuStyle: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(palette.surfaceRaised),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        ),
      ),

      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: palette.inverseSurface,
          borderRadius: Corners.brXs,
        ),
        textStyle: text.bodySmall?.copyWith(color: palette.onInverseSurface),
      ),

      snackBarTheme: SnackBarThemeData(
        backgroundColor: palette.inverseSurface,
        contentTextStyle:
            text.bodyMedium?.copyWith(color: palette.onInverseSurface),
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(borderRadius: Corners.brSm),
        insetPadding: const EdgeInsets.all(Insets.lg),
      ),

      switchTheme: SwitchThemeData(
        thumbColor: const WidgetStatePropertyAll(BrandColors.white),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? palette.success
              : palette.border,
        ),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: palette.brand,
        linearTrackColor: palette.surfaceSubtle,
      ),

      listTileTheme: ListTileThemeData(
        iconColor: palette.textStrong,
        textColor: palette.text,
        shape: const RoundedRectangleBorder(borderRadius: Corners.brSm),
      ),

      tabBarTheme: TabBarThemeData(
        labelColor: palette.brand,
        unselectedLabelColor: palette.textMuted,
        indicatorColor: palette.brand,
        dividerColor: palette.borderSubtle,
      ),

      datePickerTheme: DatePickerThemeData(
        backgroundColor: palette.surfaceRaised,
        surfaceTintColor: Colors.transparent,
        headerBackgroundColor: palette.brand,
        headerForegroundColor: palette.onBrand,
      ),
    );
  }

  static TextTheme _textTheme(Color color) {
    TextStyle s(double size, FontWeight weight, {double? spacing, double? height}) =>
        TextStyle(
          fontFamily: _fontFamily,
          fontSize: size,
          fontWeight: weight,
          color: color,
          letterSpacing: spacing,
          height: height,
        );

    return TextTheme(
      // Screen titles: "Esperando Grúa", "PEDIDOS DISPONIBLES".
      displaySmall: s(34, FontWeight.w900, spacing: -0.5, height: 1.05),
      headlineLarge: s(28, FontWeight.w800, spacing: -0.2, height: 1.1),
      headlineMedium: s(24, FontWeight.w800, spacing: -0.2, height: 1.15),
      headlineSmall: s(20, FontWeight.w800, height: 1.2),
      titleLarge: s(18, FontWeight.w700, height: 1.25),
      titleMedium: s(16, FontWeight.w700, height: 1.3),
      titleSmall: s(14, FontWeight.w700, height: 1.3),
      bodyLarge: s(16, FontWeight.w400, height: 1.45),
      bodyMedium: s(14, FontWeight.w400, height: 1.45),
      bodySmall: s(12, FontWeight.w400, height: 1.4),
      labelLarge: s(15, FontWeight.w700, spacing: 0.2),
      labelMedium: s(13, FontWeight.w600, spacing: 0.2),
      // Uppercase micro-labels above fields and in table headers.
      labelSmall: s(11, FontWeight.w700, spacing: 0.9),
    );
  }
}
