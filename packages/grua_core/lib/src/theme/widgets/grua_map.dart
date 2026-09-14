import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmap;

import '../../domain/value_objects.dart';
import '../brand.dart';
import 'brand_widgets.dart';
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
    this.routes = const [],
    this.circles = const [],
    this.fitTo = const [],
    this.interactive = true,
    this.showAttribution = true,
    this.padding = EdgeInsets.zero,
    this.onCameraIdle,
    this.onUserMove,
    this.onMapCreated,
    this.expandable = false,
    super.key,
  }) : _expanded = false;

  /// The same map, filling the page that [expandable] opens.
  ///
  /// It pans and zooms whatever the card allowed, and leaves the card's
  /// callbacks behind: a customer looking around the full-screen map has not
  /// taken the camera of the card underneath.
  GruaMap._expanded(GruaMap card)
      : center = card.center,
        hasApiKey = card.hasApiKey,
        zoom = card.zoom,
        markers = card.markers,
        route = card.route,
        routes = card.routes,
        circles = card.circles,
        fitTo = card.fitTo,
        interactive = true,
        showAttribution = true,
        padding = EdgeInsets.zero,
        onCameraIdle = null,
        onUserMove = null,
        onMapCreated = null,
        expandable = false,
        _expanded = true;

  /// Where the camera looks. Ignored while [fitTo] has points.
  final LatLng center;

  /// Whether `GOOGLE_MAPS_API_KEY` was supplied at build time. Read from
  /// `AppConfig` by the caller so this widget stays testable.
  final bool hasApiKey;

  final double zoom;
  final List<MapMarker> markers;
  final List<LatLng> route;

  /// Further legs, each in its own colour and style, drawn under [route].
  final List<MapRoute> routes;

  /// Shaded areas under everything else, such as a search radius.
  final List<MapCircle> circles;

  /// Points the camera keeps in view — the chofer, the pickup and the
  /// destination of an offer. Refitted whenever the set changes.
  final List<LatLng> fitTo;
  final bool interactive;
  final bool showAttribution;

  /// The edges of the map hidden under other UI — a floating header, a bottom
  /// sheet. The camera centres and fits within what is left, and Google's
  /// logo moves clear of it. The schematic fallback ignores it.
  final EdgeInsets padding;

  /// Fires with the centre once the camera settles — the "move the map, not
  /// the pin" address picker depends on it.
  final ValueChanged<LatLng>? onCameraIdle;

  /// Fires when the *user* moves the camera, not us.
  ///
  /// A screen that follows something moving needs this to know when to stop:
  /// the customer has grabbed the map and the truck no longer gets to decide
  /// where it looks. Our own `animateCamera` calls are filtered out — Google
  /// reports both through the same event, and on the web it is a bounds change
  /// with no idea who caused it.
  final VoidCallback? onUserMove;
  final ValueChanged<gmap.GoogleMapController>? onMapCreated;

  /// Puts a full-screen button in the bottom-right corner, for maps that sit
  /// in a card. It takes the place of Google's own web camera control, which
  /// only pans and cannot open anything.
  final bool expandable;

  /// Whether this is the full-screen copy, which shows the button that closes
  /// it instead.
  final bool _expanded;

  @override
  State<GruaMap> createState() => _GruaMapState();
}

class _GruaMapState extends State<GruaMap> {
  final _iconCache = <MapMarkerKind, gmap.BitmapDescriptor>{};
  gmap.GoogleMapController? _controller;
  var _iconsReady = false;

  /// True from the moment we ask the camera to move until it settles again.
  /// Everything Google reports in that window is our own doing.
  var _weAreMoving = true;

  var _iconsRequested = false;

  /// The card's latest configuration, so an open full-screen map keeps moving
  /// with the truck rather than freezing where it was when it opened.
  late final _latest = ValueNotifier<GruaMap>(widget);

  // Not initState: the icons are drawn at the screen's pixel ratio, and
  // reading MediaQuery there throws in debug builds. The throw landed inside
  // an unawaited future, so it was silent — and no Google map ever showed a
  // single marker.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.hasApiKey && !_iconsRequested) {
      _iconsRequested = true;
      unawaited(_buildIcons());
    }
  }

  @override
  void didUpdateWidget(GruaMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expandable) {
      // After the frame: this runs mid-build, and the full-screen page
      // listening to it cannot rebuild until the build is over.
      final latest = widget;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _latest.value = latest;
      });
    }
    final controller = _controller;
    if (controller == null) return;

    if (widget.fitTo.isNotEmpty) {
      if (!_samePoints(widget.fitTo, oldWidget.fitTo)) unawaited(_fit(controller));
      return;
    }
    // Follow the subject as it moves, rather than stranding the camera where
    // the truck used to be.
    if (widget.center != oldWidget.center || oldWidget.fitTo.isNotEmpty) {
      unawaited(_moveTo(controller, widget.center));
    }
  }

  /// Slides the camera, and survives the map being torn down underneath it.
  ///
  /// Nobody awaits this: a screen closing, or a hot restart, disposes the
  /// platform view while the animation is still in flight, and the rejection
  /// then has no handler and surfaces as a bare zone error next to whatever
  /// the engine is already complaining about.
  Future<void> _moveTo(gmap.GoogleMapController controller, LatLng to) async {
    _weAreMoving = true;
    try {
      await controller.animateCamera(
        gmap.CameraUpdate.newLatLng(gmap.LatLng(to.latitude, to.longitude)),
      );
    } on Object {
      // Gone mid-animation; the next change of centre moves the new one.
    }
  }

  static bool _samePoints(List<LatLng> a, List<LatLng> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// The map's size at its last layout, for fitting the camera.
  Size _size = Size.zero;

  /// Moves the camera to frame [GruaMap.fitTo].
  ///
  /// The centre and zoom are worked out here from the map's own size, the same
  /// maths the first frame uses, rather than handed to the platform as a
  /// bounding box: `newLatLngBounds` was silently ignored on the web while the
  /// map settled, leaving a 15 km search framed at street level.
  Future<void> _fit(gmap.GoogleMapController controller) async {
    final camera = cameraFitting(widget.fitTo, _size);
    if (camera == null) return;
    _weAreMoving = true;
    try {
      await controller.animateCamera(
        gmap.CameraUpdate.newLatLngZoom(
          gmap.LatLng(camera.center.latitude, camera.center.longitude),
          camera.zoom,
        ),
      );
    } on Object {
      // A map torn down mid-animation; the next change of points refits.
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    // Dropped as well as disposed: Google delivers a last idle or two after
    // the view is gone, and a call on a disposed controller is an error
    // nobody is waiting for.
    _controller = null;
    // `_latest` is not disposed: the card can go away while its full-screen
    // page is still open (the service ended underneath it), and that page is
    // still listening. It shows the last map it had until it is closed.
    super.dispose();
  }

  void _openFullScreen() {
    _latest.value = widget;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => Scaffold(
          body: ValueListenableBuilder<GruaMap>(
            valueListenable: _latest,
            builder: (_, card, _) => GruaMap._expanded(card),
          ),
        ),
      ),
    );
  }

  /// The corner button: into full screen on a card, back out of it on the
  /// full-screen copy.
  Widget _cornerButton(BuildContext context) {
    final expanded = widget._expanded;
    return Positioned(
      right: Insets.md,
      bottom: Insets.md,
      child: SafeArea(
        child: Tooltip(
          message: expanded ? 'Salir de pantalla completa' : 'Pantalla completa',
          child: FloatingCard(
            key: Key(expanded ? 'map-exit-fullscreen' : 'map-fullscreen'),
            padding: const EdgeInsets.all(Insets.sm),
            borderRadius: Corners.brMd,
            onTap: expanded
                ? () => Navigator.of(context).maybePop()
                : _openFullScreen,
            child: Icon(
              expanded ? Icons.fullscreen_exit : Icons.fullscreen,
              color: BrandColors.ink,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _buildIcons() async {
    final ratio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 3.0;
    try {
      for (final kind in MapMarkerKind.values) {
        _iconCache[kind] = await _rasterise(kind, ratio);
      }
    } on Object catch (error) {
      // A glyph that cannot be drawn falls back to Google's default pin; a
      // map with no markers at all is the one outcome not worth having.
      debugPrint('Map marker icons unavailable: $error');
    } finally {
      if (mounted) setState(() => _iconsReady = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final map = _map();
    if (!widget.expandable && !widget._expanded) return map;
    return Stack(
      children: [
        Positioned.fill(child: map),
        _cornerButton(context),
      ],
    );
  }

  Widget _map() {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Google centres the camera inside the padding, so the fit has to be
        // worked out for the visible part only.
        _size = widget.hasApiKey
            ? widget.padding.deflateSize(constraints.biggest)
            : constraints.biggest;
        // Both maps start from the fitted camera, so the first frame already
        // frames the trip instead of snapping to it a moment later.
        final fitted = cameraFitting(widget.fitTo, _size);
        final center = fitted?.center ?? widget.center;
        final zoom = fitted?.zoom ?? widget.zoom;

        if (!widget.hasApiKey) {
          return SchematicMap(
            center: center,
            zoom: zoom,
            markers: widget.markers,
            route: widget.route,
            routes: widget.routes,
            circles: widget.circles,
            showAttribution: widget.showAttribution,
          );
        }
        return _googleMap(center, zoom);
      },
    );
  }

  Widget _googleMap(LatLng center, double zoom) {
    return gmap.GoogleMap(
      initialCameraPosition: gmap.CameraPosition(
        target: gmap.LatLng(center.latitude, center.longitude),
        zoom: zoom,
      ),
      onMapCreated: (controller) {
        _controller = controller;
        widget.onMapCreated?.call(controller);
        if (widget.fitTo.isNotEmpty) unawaited(_fit(controller));
      },
      // Any move that starts while we are not the ones moving is the user's.
      // Cleared on idle rather than when `animateCamera` returns: on the web
      // that future completes before the camera has finished travelling.
      onCameraMoveStarted: widget.onUserMove == null
          ? null
          : () {
              // Google keeps reporting for a moment after the widget is gone.
              if (!mounted || _weAreMoving) return;
              widget.onUserMove!();
            },
      onCameraIdle: () {
        if (!mounted) return;
        _weAreMoving = false;
        final report = widget.onCameraIdle;
        if (report == null) return;
        unawaited(_reportCentre(report));
      },
      markers: _iconsReady ? _markers : const {},
      polylines: _polylines,
      circles: {
        for (var i = 0; i < widget.circles.length; i++)
          gmap.Circle(
            circleId: gmap.CircleId('circle$i'),
            center: gmap.LatLng(
              widget.circles[i].center.latitude,
              widget.circles[i].center.longitude,
            ),
            radius: widget.circles[i].radiusMeters,
            fillColor: widget.circles[i].color.withValues(alpha: 0.08),
            strokeColor: widget.circles[i].color.withValues(alpha: 0.45),
            strokeWidth: 2,
          ),
      },
      padding: widget.padding,
      myLocationEnabled: false,
      myLocationButtonEnabled: false,
      zoomControlsEnabled: false,
      mapToolbarEnabled: false,
      compassEnabled: false,
      // Our full-screen button sits where Google's web camera control would.
      webCameraControlEnabled: !widget.expandable && !widget._expanded,
      // A map the user cannot pan is the right call on screens where the
      // camera is following a truck.
      scrollGesturesEnabled: widget.interactive,
      zoomGesturesEnabled: widget.interactive,
      // On the web, Google falls back to "cooperative" handling whenever it
      // judges the page scrollable: ctrl + wheel to zoom, two fingers to pan,
      // and a grey "Use ctrl + scroll" veil over the map on every wheel turn.
      // Every map here is the screen, with no page behind it to scroll, so
      // the map takes the gestures directly. Android and iOS ignore this.
      webGestureHandling: widget.interactive
          ? gmap.WebGestureHandling.greedy
          : gmap.WebGestureHandling.none,
      rotateGesturesEnabled: false,
      tiltGesturesEnabled: false,
    );
  }

  /// The centre of what is on screen, which is the only thing the pin picker
  /// wants and the one figure the camera position does not carry directly.
  Future<void> _reportCentre(ValueChanged<LatLng> report) async {
    final gmap.LatLngBounds region;
    try {
      final bounds = await _controller?.getVisibleRegion();
      if (bounds == null || !mounted) return;
      region = bounds;
    } on Object {
      // Asked of a controller that has just been disposed. There is no centre
      // to report and nothing to say about it.
      return;
    }
    report(
      LatLng(
        (region.northeast.latitude + region.southwest.latitude) / 2,
        (region.northeast.longitude + region.southwest.longitude) / 2,
      ),
    );
  }

  Set<gmap.Marker> get _markers => {
        for (var i = 0; i < widget.markers.length; i++)
          gmap.Marker(
            // Stable across rebuilds: the marker's own id, or its kind and its
            // place among markers of that kind — never a bare list index, which
            // hands one marker's info window to another.
            markerId: gmap.MarkerId(
              widget.markers[i].id ??
                  '${widget.markers[i].kind.name}-'
                      '${widget.markers.take(i).where((m) => m.kind == widget.markers[i].kind).length}',
            ),
            position: gmap.LatLng(
              widget.markers[i].position.latitude,
              widget.markers[i].position.longitude,
            ),
            icon: _iconCache[widget.markers[i].kind] ??
                gmap.BitmapDescriptor.defaultMarker,
            rotation: widget.markers[i].heading,
            anchor: widget.markers[i].kind.isPin
                // Pins point at the ground; the canvas has 4 px under the tip.
                ? const Offset(0.5, 52 / 56)
                // Truck glyphs and dots are centred on it.
                : const Offset(0.5, 0.5),
            flat: !widget.markers[i].kind.isPin,
            onTap: widget.markers[i].onTap,
            // A tappable marker's tap belongs to the caller, not to Google's
            // default of centring the camera and opening the info window.
            consumeTapEvents: widget.markers[i].onTap != null,
            // Your own position draws over everything else.
            zIndexInt: widget.markers[i].kind == MapMarkerKind.me ? 10 : 0,
            infoWindow: widget.markers[i].label == null
                ? gmap.InfoWindow.noText
                : gmap.InfoWindow(title: widget.markers[i].label),
          ),
      };

  Set<gmap.Polyline> get _polylines {
    final legs = [
      ...widget.routes,
      if (widget.route.length >= 2) MapRoute(points: widget.route),
    ];
    return {
      for (var i = 0; i < legs.length; i++)
        if (legs[i].points.length >= 2)
          gmap.Polyline(
            polylineId: gmap.PolylineId('route$i'),
            color: legs[i].color,
            width: 5,
            zIndex: i,
            patterns: legs[i].dashed
                ? [gmap.PatternItem.dash(18), gmap.PatternItem.gap(12)]
                : const [],
            points: [
              for (final point in legs[i].points)
                gmap.LatLng(point.latitude, point.longitude),
            ],
          ),
    };
  }

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
      case MapMarkerKind.customer:
        _paintPin(canvas, const Offset(22, 52), BrandColors.info);
      case MapMarkerKind.me:
        _paintMe(canvas, const Offset(22, 52));
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

  /// "You are here": a bigger red drop with a soft halo where it touches the
  /// ground, so it reads before anything else on the map.
  void _paintMe(Canvas canvas, Offset tip) {
    const r = 14.0;
    final centre = Offset(tip.dx, tip.dy - 30);
    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..quadraticBezierTo(centre.dx - r, centre.dy + 14, centre.dx - r, centre.dy)
      ..arcToPoint(Offset(centre.dx + r, centre.dy),
          radius: const Radius.circular(r))
      ..quadraticBezierTo(centre.dx + r, centre.dy + 14, tip.dx, tip.dy)
      ..close();

    canvas
      ..drawOval(
        Rect.fromCenter(center: tip, width: 22, height: 8),
        Paint()..color = BrandColors.red.withValues(alpha: 0.25),
      )
      ..drawPath(
        path,
        Paint()
          ..color = Colors.black.withValues(alpha: 0.25)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5),
      )
      ..drawPath(path, Paint()..color = BrandColors.red)
      ..drawPath(
        path,
        Paint()
          ..color = BrandColors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      )
      ..drawCircle(centre, 5.5, Paint()..color = BrandColors.white);
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
