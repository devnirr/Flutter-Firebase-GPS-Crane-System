import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../brand.dart';

/// How the hexagon mark is coloured in a given context.
enum GruaLogoVariant {
  /// Red hexagon, white "GRUAS", black "RD" band. The primary mark, used on
  /// light map backgrounds.
  primary,

  /// Solid white mark for use on red or black.
  onDark,

  /// Outlined mark with no fill — the splash treatment.
  outline,

  /// Solid black mark for print and monochrome contexts.
  mono,
}

/// The "GRUAS RD 24/7" hexagon.
///
/// Drawn rather than shipped as an asset so it stays crisp at every size, can
/// recolour per context, and does not add a raster to the bundle. [size] is the
/// width; the hexagon's height follows the flat-top ratio.
class GruaLogo extends StatelessWidget {
  const GruaLogo({
    this.size = 96,
    this.variant = GruaLogoVariant.primary,
    this.showWordmark = true,
    super.key,
  });

  final double size;
  final GruaLogoVariant variant;

  /// When false, only the hexagon badge is drawn — used for compact app bars.
  final bool showWordmark;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size * _hexRatio,
      child: CustomPaint(
        painter: _GruaLogoPainter(
          variant: variant,
          showWordmark: showWordmark,
          textDirection: Directionality.of(context),
        ),
        isComplex: true,
      ),
    );
  }

  /// Flat-top regular hexagon: height = width * sqrt(3) / 2, plus a little
  /// breathing room so the wordmark is not cramped against the edge.
  static const double _hexRatio = 1.06;
}

class _GruaLogoPainter extends CustomPainter {
  _GruaLogoPainter({
    required this.variant,
    required this.showWordmark,
    required this.textDirection,
  });

  final GruaLogoVariant variant;
  final bool showWordmark;
  final TextDirection textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    final path = _hexagonPath(size);

    switch (variant) {
      case GruaLogoVariant.primary:
        canvas.drawPath(path, Paint()..color = BrandColors.red);
      case GruaLogoVariant.onDark:
        canvas.drawPath(path, Paint()..color = BrandColors.white);
      case GruaLogoVariant.mono:
        canvas.drawPath(path, Paint()..color = BrandColors.ink);
      case GruaLogoVariant.outline:
        canvas.drawPath(
          path,
          Paint()
            ..color = BrandColors.red
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(1.5, size.width * 0.022)
            ..strokeJoin = StrokeJoin.round,
        );
    }

    if (!showWordmark) return;

    final (top, bottom) = switch (variant) {
      GruaLogoVariant.primary => (BrandColors.white, BrandColors.ink),
      GruaLogoVariant.onDark => (BrandColors.red, BrandColors.ink),
      GruaLogoVariant.mono => (BrandColors.white, BrandColors.white),
      GruaLogoVariant.outline => (BrandColors.red, BrandColors.red),
    };

    // The mark is three stacked lines: GRUAS / RD / 24/7, each on its own
    // optical baseline inside the hexagon.
    _line(canvas, size, 'GRUAS', size.width * 0.150, FontWeight.w800, top, 0.30, 1.6);
    _line(canvas, size, 'RD', size.width * 0.235, FontWeight.w900, bottom, 0.505, 0.5);
    _line(canvas, size, '24/7', size.width * 0.115, FontWeight.w700, bottom, 0.715, 1);
  }

  void _line(
    Canvas canvas,
    Size size,
    String text,
    double fontSize,
    FontWeight weight,
    Color color,
    double centerYFraction,
    double letterSpacing,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: weight,
          color: color,
          letterSpacing: letterSpacing * (size.width / 96),
          height: 1,
        ),
      ),
      textDirection: textDirection,
      textAlign: TextAlign.center,
    )..layout();

    painter.paint(
      canvas,
      Offset(
        (size.width - painter.width) / 2,
        size.height * centerYFraction - painter.height / 2,
      ),
    );
  }

  /// A pointy-top hexagon with softened corners, matching the mockup badge.
  Path _hexagonPath(Size size) {
    final w = size.width;
    final h = size.height;
    final cx = w / 2;
    final cy = h / 2;
    final r = w / 2;
    final radius = w * 0.06;

    final points = <Offset>[
      for (var i = 0; i < 6; i++)
        Offset(
          // -90° start puts a vertex at the top.
          cx + r * math.cos((math.pi / 3) * i - math.pi / 2),
          cy + (h / 2) * math.sin((math.pi / 3) * i - math.pi / 2),
        ),
    ];

    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final current = points[i];
      final next = points[(i + 1) % points.length];
      final previous = points[(i - 1 + points.length) % points.length];

      final toPrev = _shorten(current, previous, radius);
      final toNext = _shorten(current, next, radius);

      if (i == 0) {
        path.moveTo(toPrev.dx, toPrev.dy);
      } else {
        path.lineTo(toPrev.dx, toPrev.dy);
      }
      path.quadraticBezierTo(current.dx, current.dy, toNext.dx, toNext.dy);
    }
    path.close();
    return path;
  }

  Offset _shorten(Offset from, Offset toward, double by) {
    final dx = toward.dx - from.dx;
    final dy = toward.dy - from.dy;
    final length = math.sqrt(dx * dx + dy * dy);
    if (length == 0) return from;
    final t = math.min(by / length, 0.5);
    return Offset(from.dx + dx * t, from.dy + dy * t);
  }

  @override
  bool shouldRepaint(_GruaLogoPainter old) =>
      old.variant != variant ||
      old.showWordmark != showWordmark ||
      old.textDirection != textDirection;
}
