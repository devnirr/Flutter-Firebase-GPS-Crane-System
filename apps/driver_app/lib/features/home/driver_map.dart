import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

/// The chofer's map on the home screen.
///
/// Alone, it follows the chofer, drawn as a red drop. With an [offer], it frames the
/// whole job — the truck, the customer and the destination — and draws the
/// road to the customer in red and the tow itself dashed after it, because
/// "how far is it and which way" is the decision the chofer has 25 seconds
/// to make.
///
/// With no [height] it fills its parent edge to edge, as the home screen uses
/// it; [padding] is then the part covered by the header and the sheet, and the
/// camera and the map's own controls stay inside what is left.
class DriverMap extends ConsumerStatefulWidget {
  const DriverMap({
    this.offer,
    this.height,
    this.padding = EdgeInsets.zero,
    super.key,
  });

  final Offer? offer;
  final double? height;
  final EdgeInsets padding;

  @override
  ConsumerState<DriverMap> createState() => _DriverMapState();
}

class _DriverMapState extends ConsumerState<DriverMap> {
  /// Bumped by "Centrar" to rebuild the map on a fresh camera after the chofer
  /// has panned away.
  var _epoch = 0;

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(myPositionProvider).value;
    final blocker = ref.watch(locationBlockerProvider).value;
    final offer = widget.offer;

    final pickup = offer?.pickupGeo;
    final dropoff = offer?.dropoffGeo;

    // The road to the customer, fetched at ~100 m grain so a moving truck
    // does not refetch it every few seconds.
    final toPickup = (me != null && pickup != null)
        ? ref.watch(roadRouteProvider((routeGrain(me.position), pickup))).value
        : null;
    final tow = (pickup != null && dropoff != null)
        ? ref.watch(roadRouteProvider((pickup, dropoff))).value
        : null;

    final center = me?.position ?? pickup ?? DoLocations.santoDomingo;
    final approximate = toPickup?.isApproximate ?? false;

    final inset = widget.padding;
    final fullBleed = widget.height == null;

    final map = Stack(
      fit: StackFit.expand,
      children: [
            GruaMap(
              key: ValueKey(_epoch),
              center: center,
              zoom: 15,
              hasApiKey: ref.watch(hasMapsKeyProvider),
              showAttribution: fullBleed,
              padding: inset,
              fitTo: [
                if (offer != null) ...[
                  ?me?.position,
                  ?pickup,
                  ?dropoff,
                ],
              ],
              routes: [
                if (tow != null)
                  MapRoute(points: tow.points, color: BrandColors.ink, dashed: true),
                if (toPickup != null)
                  MapRoute(points: toPickup.points, dashed: toPickup.isApproximate),
              ],
              // Red for you, blue for the customer, black for the destination.
              markers: [
                if (pickup != null)
                  MapMarker(position: pickup, kind: MapMarkerKind.customer, label: 'Cliente'),
                if (dropoff != null)
                  MapMarker(position: dropoff, kind: MapMarkerKind.dropoff, label: 'Destino'),
                if (me != null)
                  MapMarker(position: me.position, kind: MapMarkerKind.me, label: 'Tú'),
              ],
            ),
            if (approximate)
              Positioned(
                left: inset.left + Insets.md,
                top: inset.top + Insets.md,
                child: const _Badge(
                  icon: Icons.route_outlined,
                  text: 'Ruta aproximada',
                ),
              ),
            Positioned(
              right: inset.right + Insets.md,
              top: inset.top + Insets.md,
              child: Material(
                color: BrandColors.white,
                shape: const CircleBorder(),
                elevation: 2,
                child: IconButton(
                  tooltip: offer == null ? 'Centrar en mi ubicación' : 'Ver todo el servicio',
                  onPressed: () => setState(() => _epoch++),
                  icon: const Icon(Icons.my_location, size: 20),
                ),
              ),
            ),
            if (blocker != null && blocker.isBlocking)
              Positioned(
                left: inset.left + Insets.md,
                right: inset.right + Insets.md,
                bottom: inset.bottom + Insets.md,
                child: InlineNotice(
                  message: _blockerMessage(blocker),
                  icon: Icons.location_off_outlined,
                  actionLabel: blocker.actionLabel,
                  onAction: () => unawaited(_resolve(blocker)),
                ),
              ),
      ],
    );

    if (fullBleed) return map;
    return SizedBox(
      height: widget.height,
      child: ClipRRect(borderRadius: Corners.brLg, child: map),
    );
  }

  String _blockerMessage(LocationBlocker blocker) => switch (blocker) {
        LocationBlocker.notRequested ||
        LocationBlocker.denied =>
          'Permite tu ubicación para verte en el mapa y recibir servicios.',
        _ => blocker.message,
      };

  Future<void> _resolve(LocationBlocker blocker) async {
    final location = ref.read(locationServiceProvider);
    switch (blocker) {
      case LocationBlocker.serviceDisabled:
        await location.openLocationSettings();
      case LocationBlocker.deniedForever || LocationBlocker.needsAlways:
        await location.openAppSettings();
      case _:
        await location.request();
    }
    ref.invalidate(locationBlockerProvider);
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: BrandColors.white.withValues(alpha: 0.92),
        borderRadius: Corners.brSm,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Insets.sm, vertical: Insets.xs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: BrandColors.grey600),
            const SizedBox(width: Insets.xs),
            Text(
              text,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: BrandColors.grey800),
            ),
          ],
        ),
      ),
    );
  }
}
