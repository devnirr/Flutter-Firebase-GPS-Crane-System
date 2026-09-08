import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/value_objects.dart';
import '../brand.dart';

/// What to draw on a [SchematicMap].
@immutable
class MapMarker {
  const MapMarker({
    required this.position,
    required this.kind,
    this.heading = 0,
    this.label,
  });

  final LatLng position;
  final MapMarkerKind kind;

  /// Degrees clockwise from north. Rotates the truck glyph.
  final double heading;
  final String? label;
}

enum MapMarkerKind { pickup, dropoff, truckIdle, truckOnService, truckStale, user }

/// A drawn stand-in for a real map.
///
/// Google Maps needs a billed API key, which a fresh checkout does not have. A
/// grey rectangle in its place would misrepresent every screen it appears on,
/// so this draws a plausible Dominican street grid — arterials, secondary
/// streets, blocks, a river — at the right scale for the given centre and zoom,
/// and projects markers onto it with the same Web Mercator maths the real map
/// uses. Positions are therefore correct relative to one another, which is what
/// the screens are actually demonstrating.
///
/// It is a development and demo affordance. `GoogleMap` replaces it as soon as
/// `GOOGLE_MAPS_API_KEY` is configured.
class SchematicMap extends StatelessWidget {
  const SchematicMap({
    required this.center,
    this.zoom = 14,
    this.markers = const [],
    this.route = const [],
    this.showAttribution = true,
    super.key,
  });

  final LatLng center;
  final double zoom;
  final List<MapMarker> markers;

  /// Polyline drawn beneath the markers, e.g. pickup → dropoff.
  final List<LatLng> route;
  final bool showAttribution;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(
            painter: _SchematicMapPainter(
              center: center,
              zoom: zoom,
              markers: markers,
              route: route,
              textDirection: Directionality.of(context),
            ),
            isComplex: true,
            willChange: true,
          ),
          if (showAttribution)
            Positioned(
              left: Insets.sm,
              bottom: Insets.sm,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: BrandColors.white.withValues(alpha: 0.82),
                  borderRadius: Corners.brXs,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Insets.sm,
                    vertical: 3,
                  ),
                  child: Text(
                    'Mapa de demostración',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: BrandColors.grey600,
                          fontSize: 10,
                        ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SchematicMapPainter extends CustomPainter {
  _SchematicMapPainter({
    required this.center,
    required this.zoom,
    required this.markers,
    required this.route,
    required this.textDirection,
  });

  final LatLng center;
  final double zoom;
  final List<MapMarker> markers;
  final List<LatLng> route;
  final TextDirection textDirection;

  /// Web Mercator world size in pixels at this zoom, matching Google's 256-px
  /// tile scheme so marker separation reads at the right scale.
  double get _worldPx => 256 * math.pow(2, zoom).toDouble();

  Offset _project(LatLng p, Size size) {
    final world = _worldPx;
    double x(double lng) => (lng + 180) / 360 * world;
    double y(double lat) {
      final s = math.sin(lat * math.pi / 180).clamp(-0.9999, 0.9999);
      return (0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)) * world;
    }

    return Offset(
      size.width / 2 + (x(p.longitude) - x(center.longitude)),
      size.height / 2 + (y(p.latitude) - y(center.latitude)),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFF1EFEC));

    // A deterministic seed keeps the "city" stable across rebuilds so the map
    // does not shimmer while a marker animates.
    final seed = (center.latitude * 1000).round() ^ (center.longitude * 1000).round();
    final rng = math.Random(seed);

    _paintBlocks(canvas, size, rng);
    _paintWater(canvas, size, rng);
    _paintStreets(canvas, size, rng);
    _paintRoute(canvas, size);
    _paintMarkers(canvas, size);
  }

  void _paintBlocks(Canvas canvas, Size size, math.Random rng) {
    final block = Paint()..color = const Color(0xFFE7E4E0);
    const step = 78.0;
    for (var x = -step; x < size.width + step; x += step) {
      for (var y = -step; y < size.height + step; y += step) {
        if (rng.nextDouble() < 0.28) continue;
        final inset = 6 + rng.nextDouble() * 10;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x + inset, y + inset, step - inset * 2, step - inset * 2),
            const Radius.circular(2),
          ),
          block,
        );
      }
    }

    // A couple of green blocks stand in for parks.
    final park = Paint()..color = const Color(0xFFD9E5D2);
    for (var i = 0; i < 3; i++) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            rng.nextDouble() * size.width,
            rng.nextDouble() * size.height,
            50 + rng.nextDouble() * 70,
            40 + rng.nextDouble() * 60,
          ),
          const Radius.circular(6),
        ),
        park,
      );
    }
  }

  void _paintWater(Canvas canvas, Size size, math.Random rng) {
    // The Ozama runs through Santo Domingo; every Dominican map has water.
    final path = Path()..moveTo(size.width * 0.12, -20);
    var y = -20.0;
    var x = size.width * 0.12;
    while (y < size.height + 20) {
      y += 60;
      x += (rng.nextDouble() - 0.45) * 70;
      path.quadraticBezierTo(x + 24, y - 30, x, y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFFC5DCE8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 16
        ..strokeCap = StrokeCap.round,
    );
  }

  void _paintStreets(Canvas canvas, Size size, math.Random rng) {
    final secondary = Paint()
      ..color = BrandColors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4;
    final arterial = Paint()
      ..color = const Color(0xFFFBD9A0)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round;
    final highway = Paint()
      ..color = const Color(0xFFF0A868)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 13
      ..strokeCap = StrokeCap.round;

    const step = 78.0;
    for (var x = -step; x < size.width + step; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), secondary);
    }
    for (var y = -step; y < size.height + step; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), secondary);
    }

    // Two arterials and one diagonal highway — the Duarte, effectively.
    canvas
      ..drawLine(
        Offset(0, size.height * 0.34),
        Offset(size.width, size.height * 0.34),
        arterial,
      )
      ..drawLine(
        Offset(size.width * 0.62, 0),
        Offset(size.width * 0.62, size.height),
        arterial,
      )
      ..drawLine(
        Offset(-20, size.height * 0.86),
        Offset(size.width + 20, size.height * 0.12),
        highway,
      );
  }

  void _paintRoute(Canvas canvas, Size size) {
    if (route.length < 2) return;
    final path = Path();
    for (var i = 0; i < route.length; i++) {
      final point = _project(route[i], size);
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    // Casing first, so the line reads over both road and block fills.
    canvas
      ..drawPath(
        path,
        Paint()
          ..color = BrandColors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 9
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      )
      ..drawPath(
        path,
        Paint()
          ..color = BrandColors.red
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
  }

  void _paintMarkers(Canvas canvas, Size size) {
    for (final marker in markers) {
      final point = _project(marker.position, size);
      switch (marker.kind) {
        case MapMarkerKind.pickup:
          _pin(canvas, point, BrandColors.red);
        case MapMarkerKind.dropoff:
          _pin(canvas, point, BrandColors.ink);
        case MapMarkerKind.user:
          _userDot(canvas, point);
        case MapMarkerKind.truckIdle:
          _truck(canvas, point, BrandColors.driverIdle, marker.heading);
        case MapMarkerKind.truckOnService:
          _truck(canvas, point, BrandColors.driverOnService, marker.heading);
        case MapMarkerKind.truckStale:
          _truck(canvas, point, BrandColors.driverStale, marker.heading);
      }

      final label = marker.label;
      if (label != null && label.isNotEmpty) {
        _label(canvas, point, label);
      }
    }
  }

  void _pin(Canvas canvas, Offset at, Color color) {
    const r = 9.0;
    final tip = at;
    final centre = Offset(at.dx, at.dy - 20);

    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..quadraticBezierTo(centre.dx - r, centre.dy + 9, centre.dx - r, centre.dy)
      ..arcToPoint(Offset(centre.dx + r, centre.dy),
          radius: const Radius.circular(r))
      ..quadraticBezierTo(centre.dx + r, centre.dy + 9, tip.dx, tip.dy)
      ..close();

    canvas
      ..drawPath(
        path,
        Paint()
          ..color = Colors.black.withValues(alpha: 0.18)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      )
      ..drawPath(path, Paint()..color = color)
      ..drawCircle(centre, 3.4, Paint()..color = BrandColors.white);
  }

  void _userDot(Canvas canvas, Offset at) {
    canvas
      ..drawCircle(
        at,
        16,
        Paint()..color = BrandColors.red.withValues(alpha: 0.16),
      )
      ..drawCircle(at, 7, Paint()..color = BrandColors.white)
      ..drawCircle(at, 5, Paint()..color = BrandColors.red);
  }

  void _truck(Canvas canvas, Offset at, Color color, double heading) {
    canvas
      ..save()
      ..translate(at.dx, at.dy)
      ..rotate(heading * math.pi / 180);

    final body = RRect.fromRectAndRadius(
      const Rect.fromLTWH(-11, -8, 22, 16),
      const Radius.circular(4),
    );
    canvas
      ..drawRRect(
        body.shift(const Offset(0, 1)),
        Paint()
          ..color = Colors.black.withValues(alpha: 0.2)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
      )
      ..drawRRect(body, Paint()..color = color)
      ..drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(-7, -5, 8, 10),
          const Radius.circular(2),
        ),
        Paint()..color = BrandColors.white,
      )
      // Nose triangle points the way the truck is heading.
      ..drawPath(
        Path()
          ..moveTo(11, -5)
          ..lineTo(16, 0)
          ..lineTo(11, 5)
          ..close(),
        Paint()..color = color,
      )
      ..restore();
  }

  void _label(Canvas canvas, Offset at, String text) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: BrandColors.ink,
        ),
      ),
      textDirection: textDirection,
    )..layout();

    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        at.dx - painter.width / 2 - 6,
        at.dy + 8,
        painter.width + 12,
        painter.height + 6,
      ),
      const Radius.circular(4),
    );
    canvas.drawRRect(
      rect,
      Paint()..color = BrandColors.white.withValues(alpha: 0.92),
    );
    painter
      ..paint(canvas, Offset(at.dx - painter.width / 2, at.dy + 11))
      ..dispose();
  }

  @override
  bool shouldRepaint(_SchematicMapPainter old) =>
      old.center != center ||
      old.zoom != zoom ||
      old.route != route ||
      old.markers != markers;
}
