import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';
import 'truck_search.dart';
import 'truck_search_widgets.dart';

/// The customer's home.
///
/// A live map fills the screen, the mark sits at the top, a short menu of the
/// four things anyone comes here to do sits over it, and the request button
/// owns the bottom. One decision per screen: somebody opening this app has just
/// broken down, and the fastest path to a grúa is the only thing that matters.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  /// Bumped by the locate button to rebuild the map on a fresh camera after
  /// the customer has panned away.
  var _epoch = 0;

  Future<void> _resolveLocation(LocationBlocker blocker) async {
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

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider).value;

    // The customer where their phone says they are — the red drop, as on the
    // chofer's map. Until the first fix the map shows the default centre with
    // nobody on it, rather than a pin pretending to be them.
    final me = ref.watch(myPositionProvider).value;
    final blocker = ref.watch(locationBlockerProvider).value;

    // "Grúas cerca de ti". The trucks are reassurance, not something to pick
    // from: dispatch chooses the chofer, and letting a customer aim at one
    // would be a promise the cascade cannot keep.
    final search = ref.watch(truckSearchProvider);
    final radiusKm = ref.watch(truckSearchSettingsProvider).radiusKm;
    final area = search.center == null
        ? null
        : MapCircle(center: search.center!, radiusMeters: radiusKm * 1000);

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: GruaMap(
              key: ValueKey(_epoch),
              center: me?.position ?? DoLocations.defaultCenter,
              hasApiKey: ref.watch(hasMapsKeyProvider),
              zoom: me == null ? 13.4 : 15,
              // The camera frames the area searched, so every truck found is
              // on screen however wide the radius.
              circles: [?area],
              fitTo: area?.extremes ?? const [],
              markers: [
                for (final truck in search.results)
                  MapMarker(
                    position: truck.position,
                    kind: MapMarkerKind.truckIdle,
                    heading: truck.heading,
                    onTap: () => unawaited(showNearbyTruckSheet(context, truck)),
                  ),
                if (me != null)
                  MapMarker(position: me.position, kind: MapMarkerKind.me, label: 'Tú'),
              ],
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                _TopBar(
                  greeting: user == null
                      ? 'Hola'
                      : 'Hola, ${user.shortName}',
                  onProfile: () => context.push(Routes.profile),
                ),
                const SizedBox(height: Insets.sm),
                const GruaLogo(size: 120),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Insets.gutter,
                    0,
                    Insets.gutter,
                    Insets.md,
                  ),
                  child: blocker != null && blocker.isBlocking
                      ? InlineNotice(
                          message: switch (blocker) {
                            LocationBlocker.notRequested ||
                            LocationBlocker.denied =>
                              'Permite tu ubicación para verte en el mapa.',
                            _ => blocker.message,
                          },
                          icon: Icons.location_off_outlined,
                          actionLabel: blocker.actionLabel,
                          onAction: () => _resolveLocation(blocker),
                        )
                      : Align(
                          alignment: Alignment.centerRight,
                          child: Material(
                            color: BrandColors.white,
                            shape: const CircleBorder(),
                            elevation: 2,
                            child: IconButton(
                              tooltip: 'Centrar en mi ubicación',
                              onPressed: me == null
                                  ? null
                                  : () => setState(() => _epoch++),
                              icon: const Icon(Icons.my_location, size: 20),
                            ),
                          ),
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Insets.gutter,
                  ),
                  child: _QuickMenu(
                    onHistory: () => context.push(Routes.history),
                    onProfile: () => context.push(Routes.profile),
                  ),
                ),
                const SizedBox(height: Insets.lg),
                _RequestBar(onRequest: () => context.push(Routes.request)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.greeting, required this.onProfile});

  final String greeting;
  final VoidCallback onProfile;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.gutter,
        Insets.md,
        Insets.gutter,
        0,
      ),
      child: Row(
        children: [
          Expanded(
            child: FloatingCard(
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.lg,
                vertical: Insets.md,
              ),
              borderRadius: Corners.brMd,
              child: Row(
                children: [
                  const Icon(Icons.location_on, size: 18, color: BrandColors.red),
                  const SizedBox(width: Insets.sm),
                  Expanded(
                    child: Text(
                      greeting,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: Insets.md),
          FloatingCard(
            padding: const EdgeInsets.all(Insets.md),
            borderRadius: Corners.brMd,
            onTap: onProfile,
            child: const Icon(Icons.person_outline, color: BrandColors.ink),
          ),
        ],
      ),
    );
  }
}

/// The four-item list from the mockup, over the map.
class _QuickMenu extends StatelessWidget {
  const _QuickMenu({
    required this.onHistory,
    required this.onProfile,
  });

  final VoidCallback onHistory;
  final VoidCallback onProfile;

  @override
  Widget build(BuildContext context) {
    return FloatingCard(
      padding: const EdgeInsets.symmetric(vertical: Insets.sm),
      child: Column(
        children: [
          const NearbyTrucksRow(),
          const Divider(indent: Insets.huge, endIndent: Insets.lg),
          _MenuRow(
            icon: Icons.receipt_long_outlined,
            label: 'Mis servicios y facturas',
            onTap: onHistory,
          ),
          const Divider(indent: Insets.huge, endIndent: Insets.lg),
          _MenuRow(
            icon: Icons.credit_card_outlined,
            label: 'Métodos de pago',
            onTap: onProfile,
          ),
          const Divider(indent: Insets.huge, endIndent: Insets.lg),
          _MenuRow(
            icon: Icons.support_agent_outlined,
            label: 'Soporte 24/7',
            onTap: onProfile,
          ),
        ],
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.label,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: Icon(icon, color: BrandColors.grey800),
      title: Text(label, style: Theme.of(context).textTheme.titleSmall),
      trailing: onTap == null
          ? null
          : const Icon(Icons.chevron_right, color: BrandColors.grey400),
      dense: true,
    );
  }
}

class _RequestBar extends StatelessWidget {
  const _RequestBar({required this.onRequest});

  final VoidCallback onRequest;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.gutter,
        0,
        Insets.gutter,
        Insets.lg,
      ),
      child: ElevatedButton.icon(
        onPressed: onRequest,
        style: ElevatedButton.styleFrom(
          minimumSize: const Size.fromHeight(62),
          shape: const RoundedRectangleBorder(borderRadius: Corners.brLg),
        ),
        icon: const Icon(Icons.local_shipping, size: 22),
        label: const Text('PEDIR GRÚA 24/7'),
      ),
    );
  }
}
