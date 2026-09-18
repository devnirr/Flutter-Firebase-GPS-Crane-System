import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';
import 'portal_shell.dart';

/// The company's tows on the road right now — its own and nobody else's.
///
/// Each grúa is drawn where its chofer's phone last reported it, which is the
/// same feed the policyholder would watch in the customer app.
class PortalMapScreen extends ConsumerStatefulWidget {
  const PortalMapScreen({super.key});

  @override
  ConsumerState<PortalMapScreen> createState() => _PortalMapScreenState();
}

class _PortalMapScreenState extends ConsumerState<PortalMapScreen> {
  String? _selectedId;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final hasKey = ref.watch(hasMapsKeyProvider);
    final active = [
      for (final s in ref.watch(myInsurerServicesProvider).value ?? const <Service>[])
        if (s.isActive) s,
    ];
    final selected = active.where((s) => s.id == _selectedId).firstOrNull;

    final trucks = <(Service, ServiceTracking)>[
      for (final s in active)
        if (s.hasDriver)
          if (ref.watch(serviceTrackingProvider(s.id)).value case final t?
              when t.position.latitude != 0 || t.position.longitude != 0)
            (s, t),
    ];
    final truckOf = {for (final (s, t) in trucks) s.id: t};

    final frame = <LatLng>[
      if (selected != null) ...[
        selected.pickup.geo,
        if (selected.dropoff != null) selected.dropoff!.geo,
        if (truckOf[selected.id] case final t?) t.position,
      ] else ...[
        for (final s in active) s.pickup.geo,
        for (final (_, t) in trucks) t.position,
      ],
    ];

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 360,
          child: ListView(
            padding: const EdgeInsets.all(Insets.xl),
            children: [
              const PortalHeader(
                title: 'Mapa en vivo',
                subtitle: 'Tus grúas en curso. Toca una para verla en el mapa.',
              ),
              const SizedBox(height: Insets.lg),
              if (active.isEmpty)
                Text(
                  'No tienes grúas en curso ahora mismo.',
                  key: const Key('portal-map-empty'),
                  style: text.bodyMedium?.copyWith(color: palette.textMuted),
                ),
              for (final s in active)
                _ActiveCard(
                  service: s,
                  tracking: truckOf[s.id],
                  selected: s.id == _selectedId,
                  onTap: () => setState(
                    () => _selectedId = s.id == _selectedId ? null : s.id,
                  ),
                ),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: GruaMap(
            key: const Key('portal-live-map'),
            center: frame.isEmpty ? DoLocations.defaultCenter : frame.first,
            hasApiKey: hasKey,
            zoom: 12.4,
            fitTo: frame,
            route: selected == null ? const [] : selected.route.path,
            markers: [
              for (final s in active) ...[
                MapMarker(
                  id: 'pickup:${s.id}',
                  position: s.pickup.geo,
                  kind: MapMarkerKind.pickup,
                  label: s.id == _selectedId ? _claimOf(s) : null,
                  onTap: () => setState(() => _selectedId = s.id),
                ),
                if (s.dropoff != null && s.id == _selectedId)
                  MapMarker(
                    id: 'dropoff:${s.id}',
                    position: s.dropoff!.geo,
                    kind: MapMarkerKind.dropoff,
                    label: s.dropoff!.displayAddress,
                  ),
              ],
              for (final (s, t) in trucks)
                MapMarker(
                  id: 'truck:${s.id}',
                  position: t.position,
                  heading: t.heading,
                  kind: MapMarkerKind.truckOnService,
                  label: s.id == _selectedId ? s.truckPlate : null,
                  onTap: () => setState(() => _selectedId = s.id),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

String _claimOf(Service s) {
  final claim = s.insurance?.claimNumber ?? '';
  return claim.isEmpty ? s.code : claim;
}

class _ActiveCard extends StatelessWidget {
  const _ActiveCard({
    required this.service,
    required this.tracking,
    required this.selected,
    required this.onTap,
  });

  final Service service;
  final ServiceTracking? tracking;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final s = service;
    final eta = tracking != null && tracking!.etaSeconds > 0
        ? tracking!.etaLabel
        : null;

    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.md),
      child: Material(
        color: selected ? palette.brandTint : palette.surface,
        borderRadius: Corners.brMd,
        child: InkWell(
          key: Key('portal-map-card-${s.id}'),
          borderRadius: Corners.brMd,
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(Insets.md),
            decoration: BoxDecoration(
              borderRadius: Corners.brMd,
              border: Border.all(
                color: selected ? palette.brand : palette.border,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Siniestro ${_claimOf(s)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleSmall,
                      ),
                    ),
                    StatusChip(s.status, compact: true, label: s.status.officeLabel),
                  ],
                ),
                const SizedBox(height: Insets.sm),
                RouteSummary(
                  pickup: s.pickup.displayAddress,
                  dropoff: s.dropoff?.displayAddress,
                ),
                const SizedBox(height: Insets.sm),
                Text(
                  [
                    if (s.driverName.isNotEmpty) 'Chofer: ${s.driverName}',
                    if (s.truckPlate.isNotEmpty) s.truckPlate,
                    if (eta != null && s.status == ServiceStatus.inProgress)
                      'Llega al destino en $eta'
                    else if (eta != null)
                      'Llega en $eta',
                    if (!s.hasDriver) 'Buscando la grúa más cercana…',
                  ].join(' · '),
                  style: text.bodySmall?.copyWith(color: palette.textMuted),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => context.go(Routes.portalServiceFor(s.id)),
                    child: const Text('Ver detalle'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
