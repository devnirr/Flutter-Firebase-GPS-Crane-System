import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'brand.dart';

/// Themes for the three products.
///
/// They share one palette and one type scale; what differs is density. The
/// phone apps are thumb-driven and generous, the admin panel is a dispatcher's
/// workstation and is deliberately tighter.
abstract final class AppTheme {
  static const String _fontFamily = 'Roboto';

  /// Client and driver apps: white surfaces, red actions, black text.
  static ThemeData phone() => _base(density: VisualDensity.standard);

  /// Admin panel: same palette, tighter rows so a dispatcher sees more at once.
  static ThemeData admin() => _base(
        density: VisualDensity.compact,
      ).copyWith(
        scaffoldBackgroundColor: BrandColors.offWhite,
      );

  static ThemeData _base({required VisualDensity density}) {
    const scheme = ColorScheme.light(
      primary: BrandColors.red,
      primaryContainer: BrandColors.redTint,
      onPrimaryContainer: BrandColors.redDeep,
      secondary: BrandColors.ink,
      onSecondary: BrandColors.white,
      secondaryContainer: BrandColors.grey100,
      onSecondaryContainer: BrandColors.ink,
      onSurface: BrandColors.ink,
      surfaceContainerLowest: BrandColors.white,
      surfaceContainerLow: BrandColors.offWhite,
      surfaceContainer: BrandColors.grey100,
      surfaceContainerHigh: BrandColors.grey100,
      surfaceContainerHighest: BrandColors.grey200,
      onSurfaceVariant: BrandColors.grey600,
      outline: BrandColors.grey200,
      outlineVariant: BrandColors.grey100,
      error: BrandColors.danger,
      errorContainer: BrandColors.dangerTint,
      onErrorContainer: BrandColors.redDeep,
    );

    final text = _textTheme(BrandColors.ink);

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: _fontFamily,
      visualDensity: density,
      scaffoldBackgroundColor: BrandColors.white,
      textTheme: text,
      splashFactory: InkSparkle.splashFactory,

      appBarTheme: AppBarTheme(
        backgroundColor: BrandColors.white,
        foregroundColor: BrandColors.ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        centerTitle: true,
        titleTextStyle: text.titleLarge,
        systemOverlayStyle: SystemUiOverlayStyle.dark,
      ),

      // The full-width red action from every mockup.
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: BrandColors.red,
          foregroundColor: BrandColors.white,
          disabledBackgroundColor: BrandColors.grey200,
          disabledForegroundColor: BrandColors.grey600,
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

      // Secondary action: white pill with a hairline, as on the tracking screen.
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: BrandColors.ink,
          backgroundColor: BrandColors.white,
          minimumSize: const Size.fromHeight(48),
          side: const BorderSide(color: BrandColors.grey200),
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
          foregroundColor: BrandColors.red,
          textStyle: const TextStyle(
            fontFamily: _fontFamily,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),

      // Inputs are flat filled fields with no visible border until focus,
      // matching the request form.
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: BrandColors.white,
        contentPadding: EdgeInsets.symmetric(
          horizontal: Insets.lg,
          vertical: Insets.lg,
        ),
        hintStyle: TextStyle(color: BrandColors.grey400, fontSize: 15),
        labelStyle: TextStyle(color: BrandColors.grey600, fontSize: 15),
        border: OutlineInputBorder(
          borderRadius: Corners.brMd,
          borderSide: BorderSide(color: BrandColors.grey200),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: Corners.brMd,
          borderSide: BorderSide(color: BrandColors.grey200),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: Corners.brMd,
          borderSide: BorderSide(color: BrandColors.red, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: Corners.brMd,
          borderSide: BorderSide(color: BrandColors.danger),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: Corners.brMd,
          borderSide: BorderSide(color: BrandColors.danger, width: 1.6),
        ),
      ),

      cardTheme: const CardThemeData(
        color: BrandColors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: Corners.brLg),
      ),

      chipTheme: ChipThemeData(
        backgroundColor: BrandColors.grey100,
        labelStyle: text.labelMedium,
        side: BorderSide.none,
        shape: const RoundedRectangleBorder(borderRadius: Corners.brSm),
        padding: const EdgeInsets.symmetric(horizontal: Insets.sm, vertical: Insets.xs),
      ),

      dividerTheme: const DividerThemeData(
        color: BrandColors.grey100,
        thickness: 1,
        space: 1,
      ),

      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: BrandColors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: Corners.sheet),
        showDragHandle: true,
        dragHandleColor: BrandColors.grey200,
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: BrandColors.white,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(borderRadius: Corners.brLg),
        titleTextStyle: text.titleLarge,
        contentTextStyle: text.bodyMedium,
      ),

      snackBarTheme: SnackBarThemeData(
        backgroundColor: BrandColors.ink,
        contentTextStyle: text.bodyMedium?.copyWith(color: BrandColors.white),
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(borderRadius: Corners.brSm),
        insetPadding: const EdgeInsets.all(Insets.lg),
      ),

      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? BrandColors.white : BrandColors.white,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? BrandColors.success : BrandColors.grey200,
        ),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),

      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: BrandColors.red,
        linearTrackColor: BrandColors.grey100,
      ),

      listTileTheme: const ListTileThemeData(
        iconColor: BrandColors.grey800,
        textColor: BrandColors.ink,
        shape: RoundedRectangleBorder(borderRadius: Corners.brSm),
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
