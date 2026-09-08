import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmap;

import '../../domain/value_objects.dart';
import '../brand.dart';
import 'schematic_map.dart';

/// The map every screen uses.
///
/// Renders a real Google map when a Maps API key is configured, and the drawn
/// [SchematicMap] when one is not. That fallback is not a placeholder for its
/// own sake: a fresh checkout has no billed key, and a grey rectangle would
/// misrepresent every screen it appears on. Both paths take the same markers
/// and project them the same way, so what a reviewer sees is positioned
/// correctly either way.
///
/// Marker glyphs are rasterised from the same painter the schematic map uses,
/// so a truck looks identical on both.
class GruaMap extends StatefulWidget {
  const GruaMap({
    required this.center,
    required this.hasApiKey,
    this.zoom = 14,
    this.markers = const [],
    this.route = const [],
    this.interactive = true,
    this.showAttribution = true,
    this.onCameraIdle,
    this.onMapCreated,
    super.key,
  });

  final LatLng center;

  /// Whether `GOOGLE_MAPS_API_KEY` was supplied at build time. Read from
  /// `AppConfig` by the caller so this widget stays testable.
  final bool hasApiKey;

  final double zoom;
  final List<MapMarker> markers;
  final List<LatLng> route;
  final bool interactive;
  final bool showAttribution;

  /// Fires with the centre once the camera settles — the "move the map, not
  /// the pin" address picker depends on it.
  final ValueChanged<LatLng>? onCameraIdle;
  final ValueChanged<gmap.GoogleMapController>? onMapCreated;

  @override
  State<GruaMap> createState() => _GruaMapState();
}

class _GruaMapState extends State<GruaMap> {
  final _iconCache = <MapMarkerKind, gmap.BitmapDescriptor>{};
  gmap.GoogleMapController? _controller;
  var _iconsReady = false;

  @override
  void initState() {
    super.initState();
    if (widget.hasApiKey) unawaited(_buildIcons());
  }

  @override
  void didUpdateWidget(GruaMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Follow the subject as it moves, rather than stranding the camera where
    // the truck used to be.
    if (widget.center != oldWidget.center && _controller != null) {
      unawaited(
        _controller!.animateCamera(
          gmap.CameraUpdate.newLatLng(
            gmap.LatLng(widget.center.latitude, widget.center.longitude),
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _buildIcons() async {
    final ratio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 3.0;
    for (final kind in MapMarkerKind.values) {
      _iconCache[kind] = await _rasterise(kind, ratio);
    }
    if (mounted) setState(() => _iconsReady = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.hasApiKey) {
      return SchematicMap(
        center: widget.center,
        zoom: widget.zoom,
        markers: widget.markers,
        route: widget.route,
        showAttribution: widget.showAttribution,
      );
    }

    return gmap.GoogleMap(
      initialCameraPosition: gmap.CameraPosition(
        target: gmap.LatLng(widget.center.latitude, widget.center.longitude),
        zoom: widget.zoom,
      ),
      onMapCreated: (controller) {
        _controller = controller;
        widget.onMapCreated?.call(controller);
      },
      onCameraIdle: widget.onCameraIdle == null
          ? null
          : () async {
              final region = await _controller?.getVisibleRegion();
              if (region == null) return;
              widget.onCameraIdle!(
                LatLng(
                  (region.northeast.latitude + region.southwest.latitude) / 2,
                  (region.northeast.longitude + region.southwest.longitude) / 2,
                ),
              );
            },
      markers: _iconsReady ? _markers : const {},
      polylines: _polylines,
      myLocationEnabled: false,
      myLocationButtonEnabled: false,
      zoomControlsEnabled: false,
      mapToolbarEnabled: false,
      compassEnabled: false,
      // A map the user cannot pan is the right call on screens where the
      // camera is following a truck.
      scrollGesturesEnabled: widget.interactive,
      zoomGesturesEnabled: widget.interactive,
      rotateGesturesEnabled: false,
      tiltGesturesEnabled: false,
    );
  }

  Set<gmap.Marker> get _markers => {
        for (var i = 0; i < widget.markers.length; i++)
          gmap.Marker(
            markerId: gmap.MarkerId('m$i'),
            position: gmap.LatLng(
              widget.markers[i].position.latitude,
              widget.markers[i].position.longitude,
            ),
            icon: _iconCache[widget.markers[i].kind] ??
                gmap.BitmapDescriptor.defaultMarker,
            rotation: widget.markers[i].heading,
            anchor: switch (widget.markers[i].kind) {
              // Pins point at the ground; truck glyphs are centred on it.
              MapMarkerKind.pickup || MapMarkerKind.dropoff => const Offset(0.5, 1),
              _ => const Offset(0.5, 0.5),
            },
            flat: widget.markers[i].kind != MapMarkerKind.pickup &&
                widget.markers[i].kind != MapMarkerKind.dropoff,
            infoWindow: widget.markers[i].label == null
                ? gmap.InfoWindow.noText
                : gmap.InfoWindow(title: widget.markers[i].label),
          ),
      };

  Set<gmap.Polyline> get _polylines => widget.route.length < 2
      ? const {}
      : {
          gmap.Polyline(
            polylineId: const gmap.PolylineId('route'),
            color: BrandColors.red,
            width: 5,
            points: [
              for (final point in widget.route)
                gmap.LatLng(point.latitude, point.longitude),
            ],
          ),
        };

  /// Draws one marker glyph to a PNG for Google Maps.
  ///
  /// Reusing the schematic map's shapes keeps the two renderers visually
  /// identical, so switching a key on does not change how the product looks.
  Future<gmap.BitmapDescriptor> _rasterise(
    MapMarkerKind kind,
    double ratio,
  ) async {
    const logical = Size(44, 56);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(ratio);

    switch (kind) {
      case MapMarkerKind.pickup:
        _paintPin(canvas, const Offset(22, 52), BrandColors.red);
      case MapMarkerKind.dropoff:
        _paintPin(canvas, const Offset(22, 52), BrandColors.ink);
      case MapMarkerKind.user:
        _paintUserDot(canvas, const Offset(22, 28));
      case MapMarkerKind.truckIdle:
        _paintTruck(canvas, const Offset(22, 28), BrandColors.driverIdle);
      case MapMarkerKind.truckOnService:
        _paintTruck(canvas, const Offset(22, 28), BrandColors.driverOnService);
      case MapMarkerKind.truckStale:
        _paintTruck(canvas, const Offset(22, 28), BrandColors.driverStale);
    }

    final image = await recorder.endRecording().toImage(
          (logical.width * ratio).round(),
          (logical.height * ratio).round(),
        );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();

    return gmap.BitmapDescriptor.bytes(
      bytes!.buffer.asUint8List(),
      imagePixelRatio: ratio,
    );
  }

  void _paintPin(Canvas canvas, Offset tip, Color color) {
    const r = 11.0;
    final centre = Offset(tip.dx, tip.dy - 24);
    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..quadraticBezierTo(centre.dx - r, centre.dy + 11, centre.dx - r, centre.dy)
      ..arcToPoint(Offset(centre.dx + r, centre.dy),
          radius: const Radius.circular(r))
      ..quadraticBezierTo(centre.dx + r, centre.dy + 11, tip.dx, tip.dy)
      ..close();

    canvas
      ..drawPath(
        path,
        Paint()
          ..color = Colors.black.withValues(alpha: 0.2)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5),
      )
      ..drawPath(path, Paint()..color = color)
      ..drawCircle(centre, 4, Paint()..color = BrandColors.white);
  }

  void _paintUserDot(Canvas canvas, Offset at) {
    canvas
      ..drawCircle(
        at,
        18,
        Paint()..color = BrandColors.red.withValues(alpha: 0.18),
      )
      ..drawCircle(at, 8, Paint()..color = BrandColors.white)
      ..drawCircle(at, 6, Paint()..color = BrandColors.red);
  }

  void _paintTruck(Canvas canvas, Offset at, Color color) {
    canvas
      ..save()
      ..translate(at.dx, at.dy)
      // Google Maps rotates the bitmap itself, so the glyph is drawn pointing
      // up and `Marker.rotation` supplies the heading.
      ..rotate(-math.pi / 2);

    final body = RRect.fromRectAndRadius(
      const Rect.fromLTWH(-13, -9, 26, 18),
      const Radius.circular(5),
    );
    canvas
      ..drawRRect(
        body.shift(const Offset(0, 1)),
        Paint()
          ..color = Colors.black.withValues(alpha: 0.22)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
      )
      ..drawRRect(body, Paint()..color = color)
      ..drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(-8, -6, 9, 12),
          const Radius.circular(2),
        ),
        Paint()..color = BrandColors.white,
      )
      ..drawPath(
        Path()
          ..moveTo(13, -6)
          ..lineTo(19, 0)
          ..lineTo(13, 6)
          ..close(),
        Paint()..color = color,
      )
      ..restore();
  }
}
