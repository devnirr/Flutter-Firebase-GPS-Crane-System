import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';

/// The customer's home.
///
/// A live map fills the screen, the mark sits at the top, a short menu of the
/// four things anyone comes here to do sits over it, and the request button
/// owns the bottom. One decision per screen: somebody opening this app has just
/// broken down, and the fastest path to a grúa is the only thing that matters.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider).value;
    final live = ref.watch(liveDriverPositionsProvider).value ?? const [];

    // Nearby trucks are shown as reassurance, not as something to pick from:
    // dispatch chooses the chofer, and letting a customer aim at one would be
    // a promise the cascade cannot keep.
    final nearby = live
        .where((p) => p.isOnline && p.state == DriverLiveState.idle)
        .take(6)
        .toList();

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: SchematicMap(
              center: DoLocations.defaultCenter,
              zoom: 13.4,
              markers: [
                const MapMarker(
                  position: DoLocations.defaultCenter,
                  kind: MapMarkerKind.user,
                ),
                for (final position in nearby)
                  MapMarker(
                    position: position.position,
                    kind: MapMarkerKind.truckIdle,
                    heading: position.heading,
                  ),
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: Insets.gutter,
                  ),
                  child: _QuickMenu(
                    availableTrucks: nearby.length,
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
    required this.availableTrucks,
    required this.onHistory,
    required this.onProfile,
  });

  final int availableTrucks;
  final VoidCallback onHistory;
  final VoidCallback onProfile;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return FloatingCard(
      padding: const EdgeInsets.symmetric(vertical: Insets.sm),
      child: Column(
        children: [
          _MenuRow(
            icon: Icons.local_shipping_outlined,
            label: 'Grúas cerca de ti',
            trailing: Text(
              availableTrucks == 0
                  ? 'Buscando…'
                  : '$availableTrucks disponible${availableTrucks == 1 ? '' : 's'}',
              style: text.labelMedium?.copyWith(
                color: availableTrucks == 0
                    ? BrandColors.grey600
                    : BrandColors.success,
              ),
            ),
          ),
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
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: Icon(icon, color: BrandColors.grey800),
      title: Text(label, style: Theme.of(context).textTheme.titleSmall),
      trailing: trailing ??
          (onTap == null
              ? null
              : const Icon(Icons.chevron_right, color: BrandColors.grey400)),
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
