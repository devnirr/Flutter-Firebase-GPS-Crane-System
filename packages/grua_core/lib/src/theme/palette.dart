import 'package:flutter/material.dart';

import 'brand.dart';

/// The semantic colours a screen should use, in the two skins the panel ships:
/// the white one everybody has used until now, and a dark one for night shifts
/// in the dispatch room.
///
/// Screens read these instead of [BrandColors] directly. A raw palette colour
/// is only right when it must not follow the skin — white text on the red
/// button, the driver markers over map tiles, the brand red itself.
///
/// ```dart
/// final palette = context.palette;
/// Container(color: palette.surface, child: Text('…', style: TextStyle(color: palette.textMuted)));
/// ```
@immutable
class BrandPalette extends ThemeExtension<BrandPalette> {
  const BrandPalette({
    required this.brightness,
    required this.canvas,
    required this.surface,
    required this.surfaceSubtle,
    required this.surfaceRaised,
    required this.border,
    required this.borderSubtle,
    required this.text,
    required this.textStrong,
    required this.textMuted,
    required this.textFaint,
    required this.brand,
    required this.brandTint,
    required this.brandTintStrong,
    required this.onBrand,
    required this.success,
    required this.successTint,
    required this.warning,
    required this.warningTint,
    required this.info,
    required this.infoTint,
    required this.danger,
    required this.dangerTint,
    required this.sidebar,
    required this.sidebarHover,
    required this.inverseSurface,
    required this.onInverseSurface,
    required this.shadow,
  });

  /// Which skin this is. Screens that need a different asset — a logo, a map
  /// style — branch on this rather than on [Theme.of].
  final Brightness brightness;

  /// The page behind the cards.
  final Color canvas;

  /// Cards, tables, dialogs.
  final Color surface;

  /// A quiet fill on top of [surface]: table headers, chips, empty tiles.
  final Color surfaceSubtle;

  /// Menus and dialogs, which must read as lifted off the page.
  final Color surfaceRaised;

  /// Hairlines between rows and around cards.
  final Color border;

  /// A softer hairline, for rules inside a card.
  final Color borderSubtle;

  /// Body text.
  final Color text;

  /// Field labels and table headers: a step below body text.
  final Color textStrong;

  /// Secondary text — the line under a title, a help note.
  final Color textMuted;

  /// Placeholders and disabled text.
  final Color textFaint;

  /// The call to action.
  final Color brand;

  /// Behind brand-coloured content: a selected row, a red chip.
  final Color brandTint;
  final Color brandTintStrong;

  /// What sits on [brand]. White in both skins.
  final Color onBrand;

  final Color success;
  final Color successTint;
  final Color warning;
  final Color warningTint;
  final Color info;
  final Color infoTint;
  final Color danger;
  final Color dangerTint;

  /// The panel's navigation column, which is dark in both skins.
  final Color sidebar;
  final Color sidebarHover;

  /// Snackbars and tooltips: the opposite of the page.
  final Color inverseSurface;
  final Color onInverseSurface;

  /// The colour a card's shadow is drawn in. Heavier in the dark skin, where a
  /// soft black shadow is invisible.
  final Color shadow;

  bool get isDark => brightness == Brightness.dark;

  /// Daylight: white surfaces, near-black text.
  static const BrandPalette light = BrandPalette(
    brightness: Brightness.light,
    canvas: BrandColors.offWhite,
    surface: BrandColors.white,
    surfaceSubtle: BrandColors.grey100,
    surfaceRaised: BrandColors.white,
    border: BrandColors.grey200,
    borderSubtle: BrandColors.grey100,
    text: BrandColors.ink,
    textStrong: BrandColors.grey800,
    textMuted: BrandColors.grey600,
    textFaint: BrandColors.grey400,
    brand: BrandColors.red,
    brandTint: BrandColors.redTint,
    brandTintStrong: BrandColors.redTintStrong,
    onBrand: BrandColors.white,
    success: BrandColors.success,
    successTint: BrandColors.successTint,
    warning: BrandColors.warning,
    warningTint: BrandColors.warningTint,
    info: BrandColors.info,
    infoTint: BrandColors.infoTint,
    danger: BrandColors.danger,
    dangerTint: BrandColors.dangerTint,
    sidebar: BrandColors.sidebar,
    sidebarHover: BrandColors.sidebarHover,
    inverseSurface: BrandColors.ink,
    onInverseSurface: BrandColors.white,
    shadow: Color(0x14000000),
  );

  /// Night shift: the same layout on near-black, with the status colours
  /// lightened so they still read on it, and their tints turned into deep
  /// washes instead of pastels.
  static const BrandPalette dark = BrandPalette(
    brightness: Brightness.dark,
    canvas: Color(0xFF101012),
    surface: Color(0xFF17171A),
    surfaceSubtle: Color(0xFF212126),
    surfaceRaised: Color(0xFF1E1E22),
    border: Color(0xFF34343B),
    borderSubtle: Color(0xFF26262C),
    text: Color(0xFFF4F2F1),
    textStrong: Color(0xFFDFDBDA),
    textMuted: Color(0xFFA8A2A1),
    textFaint: Color(0xFF7C7674),
    brand: BrandColors.redBright,
    brandTint: Color(0xFF3A1416),
    brandTintStrong: Color(0xFF55191D),
    onBrand: BrandColors.white,
    success: Color(0xFF4CC182),
    successTint: Color(0xFF12301F),
    warning: Color(0xFFE0A63A),
    warningTint: Color(0xFF362810),
    info: Color(0xFF5AA7E8),
    infoTint: Color(0xFF122839),
    danger: Color(0xFFF2705F),
    dangerTint: Color(0xFF3B1714),
    sidebar: Color(0xFF0B0B0D),
    sidebarHover: Color(0xFF1F1F24),
    inverseSurface: Color(0xFFEFEDEC),
    onInverseSurface: BrandColors.ink,
    shadow: Color(0x66000000),
  );

  /// The palette of the enclosing theme, or the light one if a widget is built
  /// without a Grúas theme (a bare test harness, a Material default).
  static BrandPalette of(BuildContext context) =>
      Theme.of(context).extension<BrandPalette>() ??
      (Theme.of(context).brightness == Brightness.dark ? dark : light);

  @override
  BrandPalette copyWith({
    Brightness? brightness,
    Color? canvas,
    Color? surface,
    Color? surfaceSubtle,
    Color? surfaceRaised,
    Color? border,
    Color? borderSubtle,
    Color? text,
    Color? textStrong,
    Color? textMuted,
    Color? textFaint,
    Color? brand,
    Color? brandTint,
    Color? brandTintStrong,
    Color? onBrand,
    Color? success,
    Color? successTint,
    Color? warning,
    Color? warningTint,
    Color? info,
    Color? infoTint,
    Color? danger,
    Color? dangerTint,
    Color? sidebar,
    Color? sidebarHover,
    Color? inverseSurface,
    Color? onInverseSurface,
    Color? shadow,
  }) =>
      BrandPalette(
        brightness: brightness ?? this.brightness,
        canvas: canvas ?? this.canvas,
        surface: surface ?? this.surface,
        surfaceSubtle: surfaceSubtle ?? this.surfaceSubtle,
        surfaceRaised: surfaceRaised ?? this.surfaceRaised,
        border: border ?? this.border,
        borderSubtle: borderSubtle ?? this.borderSubtle,
        text: text ?? this.text,
        textStrong: textStrong ?? this.textStrong,
        textMuted: textMuted ?? this.textMuted,
        textFaint: textFaint ?? this.textFaint,
        brand: brand ?? this.brand,
        brandTint: brandTint ?? this.brandTint,
        brandTintStrong: brandTintStrong ?? this.brandTintStrong,
        onBrand: onBrand ?? this.onBrand,
        success: success ?? this.success,
        successTint: successTint ?? this.successTint,
        warning: warning ?? this.warning,
        warningTint: warningTint ?? this.warningTint,
        info: info ?? this.info,
        infoTint: infoTint ?? this.infoTint,
        danger: danger ?? this.danger,
        dangerTint: dangerTint ?? this.dangerTint,
        sidebar: sidebar ?? this.sidebar,
        sidebarHover: sidebarHover ?? this.sidebarHover,
        inverseSurface: inverseSurface ?? this.inverseSurface,
        onInverseSurface: onInverseSurface ?? this.onInverseSurface,
        shadow: shadow ?? this.shadow,
      );

  @override
  BrandPalette lerp(covariant BrandPalette? other, double t) {
    if (other == null) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return BrandPalette(
      brightness: t < 0.5 ? brightness : other.brightness,
      canvas: c(canvas, other.canvas),
      surface: c(surface, other.surface),
      surfaceSubtle: c(surfaceSubtle, other.surfaceSubtle),
      surfaceRaised: c(surfaceRaised, other.surfaceRaised),
      border: c(border, other.border),
      borderSubtle: c(borderSubtle, other.borderSubtle),
      text: c(text, other.text),
      textStrong: c(textStrong, other.textStrong),
      textMuted: c(textMuted, other.textMuted),
      textFaint: c(textFaint, other.textFaint),
      brand: c(brand, other.brand),
      brandTint: c(brandTint, other.brandTint),
      brandTintStrong: c(brandTintStrong, other.brandTintStrong),
      onBrand: c(onBrand, other.onBrand),
      success: c(success, other.success),
      successTint: c(successTint, other.successTint),
      warning: c(warning, other.warning),
      warningTint: c(warningTint, other.warningTint),
      info: c(info, other.info),
      infoTint: c(infoTint, other.infoTint),
      danger: c(danger, other.danger),
      dangerTint: c(dangerTint, other.dangerTint),
      sidebar: c(sidebar, other.sidebar),
      sidebarHover: c(sidebarHover, other.sidebarHover),
      inverseSurface: c(inverseSurface, other.inverseSurface),
      onInverseSurface: c(onInverseSurface, other.onInverseSurface),
      shadow: c(shadow, other.shadow),
    );
  }
}

/// `context.palette` — the shorthand every screen uses.
extension BrandPaletteContext on BuildContext {
  BrandPalette get palette => BrandPalette.of(this);
}
