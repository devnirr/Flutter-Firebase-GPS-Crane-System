import 'package:flutter/material.dart';

/// The Grúas RD 24/7 palette, taken from the approved mockups.
///
/// The identity is two colours doing all the work — a saturated highway red and
/// a warm near-black — on white. Red means "act": the request button, the
/// active-service chrome, the driver's ringing screen. It is never used for
/// passive surface, which is why status colours below are deliberately pulled
/// away from it.
abstract final class BrandColors {
  /// Primary red, from the "PEDIR GRÚA 24/7" button and the hexagon mark.
  static const Color red = Color(0xFFE01F26);
  static const Color redDark = Color(0xFFB3151B);
  static const Color redDeep = Color(0xFF7A0E13);
  static const Color redBright = Color(0xFFF3242C);

  /// Tint used behind red content on white (chips, selected rows).
  static const Color redTint = Color(0xFFFDECEC);
  static const Color redTintStrong = Color(0xFFF9D2D3);

  /// Warm near-black from the logo's lower half and the driver login button.
  static const Color ink = Color(0xFF14100F);
  static const Color inkSoft = Color(0xFF241E1D);

  /// Admin panel sidebar.
  static const Color sidebar = Color(0xFF1B1B1D);
  static const Color sidebarHover = Color(0xFF2A2A2D);

  static const Color white = Color(0xFFFFFFFF);
  static const Color offWhite = Color(0xFFF7F6F6);
  static const Color grey100 = Color(0xFFEFEDED);
  static const Color grey200 = Color(0xFFDDDADA);
  static const Color grey400 = Color(0xFF9E9897);
  static const Color grey600 = Color(0xFF6B6564);
  static const Color grey800 = Color(0xFF3A3534);

  /// Semantic status colours. Kept away from brand red so a red button never
  /// reads as an error and an error never reads as a call to action.
  static const Color success = Color(0xFF1E8E4E);
  static const Color successTint = Color(0xFFE4F3EA);
  static const Color warning = Color(0xFFC9871B);
  static const Color warningTint = Color(0xFFFBF0DC);
  static const Color info = Color(0xFF1E6BB8);
  static const Color infoTint = Color(0xFFE3EFF9);
  static const Color danger = Color(0xFFC0392B);
  static const Color dangerTint = Color(0xFFFAE7E4);

  /// Live-map marker colours, matching the admin legend.
  static const Color driverIdle = success;
  static const Color driverOnService = Color(0xFFE08A00);
  static const Color driverStale = grey400;

  /// The double tick on a message the other side has read. Light on purpose:
  /// it always sits on the red bubble of something you sent.
  static const Color readTick = Color(0xFF8AD5FF);
}

/// The 4-pt spacing scale. Use these instead of loose numbers so the three
/// products stay visually consistent.
abstract final class Insets {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;
  static const double huge = 48;

  /// Standard screen gutter on phones.
  static const double gutter = 20;
}

/// Corner radii. The mockups use generously rounded cards over the map and
/// slightly tighter radii on inputs and buttons.
abstract final class Corners {
  static const double xs = 6;
  static const double sm = 10;
  static const double md = 14;
  static const double lg = 20;
  static const double xl = 28;
  static const double pill = 999;

  static const BorderRadius brXs = BorderRadius.all(Radius.circular(xs));
  static const BorderRadius brSm = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius brMd = BorderRadius.all(Radius.circular(md));
  static const BorderRadius brLg = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius brXl = BorderRadius.all(Radius.circular(xl));

  /// Sheets that rise from the bottom over a map.
  static const BorderRadius sheet = BorderRadius.vertical(top: Radius.circular(xl));
}

/// Elevation presets. Cards floating over a map need a real shadow to separate
/// from the map tiles; flat lists do not.
abstract final class Shadows {
  static const List<BoxShadow> card = [
    BoxShadow(color: Color(0x14000000), blurRadius: 12, offset: Offset(0, 4)),
  ];

  static const List<BoxShadow> floating = [
    BoxShadow(color: Color(0x24000000), blurRadius: 24, offset: Offset(0, 8)),
    BoxShadow(color: Color(0x0F000000), blurRadius: 4, offset: Offset(0, 1)),
  ];

  static const List<BoxShadow> sheet = [
    BoxShadow(color: Color(0x1F000000), blurRadius: 28, offset: Offset(0, -6)),
  ];
}

/// Motion durations, kept short — this is a product people use in an emergency.
abstract final class Motion {
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration normal = Duration(milliseconds: 250);
  static const Duration slow = Duration(milliseconds: 400);

  /// How long a driver marker takes to glide between two GPS fixes.
  static const Duration markerGlide = Duration(milliseconds: 900);
}
