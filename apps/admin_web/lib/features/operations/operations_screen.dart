import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

/// The dispatcher's main screen: every truck and every open job on one map.
///
/// The list is ordered by age with `needs_manual` pinned to the top, because
/// that is the only state where the system has given up and a person has to
/// act. Everything else is progressing on its own.
class OperationsScreen extends ConsumerStatefulWidget {
  const OperationsScreen({this.selectedServiceId, super.key});

  final String? selectedServiceId;

  @override
  ConsumerState<OperationsScreen> createState() => _OperationsScreenState();
}

class _OperationsScreenState extends ConsumerState<OperationsScreen> {
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    _selectedId = widget.selectedServiceId;
  }

  @override
  void didUpdateWidget(OperationsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedServiceId != oldWidget.selectedServiceId) {
      _selectedId = widget.selectedServiceId;
    }
  }

  @override
  Widget build(BuildContext context) {
    final services = ref.watch(activeServicesProvider).value ?? const [];
    final live = ref.watch(liveDriverPositionsProvider).value ?? const [];
    final now = DateTime.now().toUtc();

    // needs_manual first, then oldest first — the dispatcher's real priority.
    final ordered = [...services]..sort((a, b) {
        final aUrgent = a.status == ServiceStatus.needsManual ? 0 : 1;
        final bUrgent = b.status == ServiceStatus.needsManual ? 0 : 1;
        if (aUrgent != bUrgent) return aUrgent.compareTo(bUrgent);
        return (a.createdAt ?? now).compareTo(b.createdAt ?? now);
      });

    final selected = ordered.where((s) => s.id == _selectedId).firstOrNull;

    return Row(
      children: [
        SizedBox(
          width: 340,
          child: _ServiceList(
            services: ordered,
            selectedId: _selectedId,
            now: now,
            onSelect: (id) => setState(() => _selectedId = id),
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: _LiveMap(services: ordered, live: live, selected: selected, now: now),
        ),
        if (selected != null) ...[
          const VerticalDivider(width: 1),
          SizedBox(
            width: 380,
            child: _ServiceDrawer(
              service: selected,
              onClose: () => setState(() => _selectedId = null),
            ),
          ),
        ],
      ],
    );
  }
}

class _ServiceList extends StatelessWidget {
  const _ServiceList({
    required this.services,
    required this.selectedId,
    required this.now,
    required this.onSelect,
  });

  final List<Service> services;
  final String? selectedId;
  final DateTime now;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return ColoredBox(
      color: BrandColors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(Insets.lg),
            child: Row(
              children: [
                Expanded(
                  child: Text('Servicios activos', style: text.titleMedium),
                ),
                Text(
                  '${services.length}',
                  style: text.labelMedium?.copyWith(color: BrandColors.grey600),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: services.isEmpty
                ? const EmptyState(
                    title: 'Todo tranquilo',
                    message: 'No hay servicios activos ahora mismo.',
                    icon: Icons.check_circle_outline,
                    tone: EmptyStateTone.success,
                  )
                : ListView.separated(
                    itemCount: services.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) => _ServiceRow(
                      service: services[index],
                      selected: services[index].id == selectedId,
                      now: now,
                      onTap: () => onSelect(services[index].id),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ServiceRow extends StatelessWidget {
  const _ServiceRow({
    required this.service,
    required this.selected,
    required this.now,
    required this.onTap,
  });

  final Service service;
  final bool selected;
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final urgent = service.status == ServiceStatus.needsManual;
    final waiting = service.createdAt == null
        ? Duration.zero
        : now.difference(service.createdAt!);

    return Material(
      color: selected
          ? BrandColors.redTint
          : urgent
              ? BrandColors.dangerTint
              : BrandColors.white,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.lg,
            vertical: Insets.md,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      service.code,
                      style: text.titleSmall?.copyWith(
                        color: urgent ? BrandColors.danger : BrandColors.ink,
                      ),
                    ),
                  ),
                  StatusChip(service.status, compact: true),
                ],
              ),
              const SizedBox(height: Insets.xs),
              Text(
                service.pickup.displayAddress,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall?.copyWith(color: BrandColors.grey600),
              ),
              const SizedBox(height: Insets.xs),
              Row(
                children: [
                  Icon(
                    Icons.schedule,
                    size: 13,
                    color: urgent ? BrandColors.danger : BrandColors.grey400,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'esperando ${DoTime.stopwatch(waiting)}',
                    style: text.bodySmall?.copyWith(
                      color: urgent ? BrandColors.danger : BrandColors.grey600,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    service.hasDriver ? service.driverName : 'Sin asignar',
                    style: text.bodySmall?.copyWith(color: BrandColors.grey600),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LiveMap extends StatelessWidget {
  const _LiveMap({
    required this.services,
    required this.live,
    required this.selected,
    required this.now,
  });

  final List<Service> services;
  final List<DriverLivePosition> live;
  final Service? selected;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final onlineDrivers = live.where((p) => p.isOnline).toList();

    return Stack(
      children: [
        Positioned.fill(
          child: SchematicMap(
            center: selected?.pickup.geo ?? DoLocations.defaultCenter,
            zoom: selected == null ? 12.4 : 13.6,
            route: selected?.dropoff == null
                ? const []
                : [selected!.pickup.geo, selected!.dropoff!.geo],
            markers: [
              for (final service in services) ...[
                MapMarker(
                  position: service.pickup.geo,
                  kind: MapMarkerKind.pickup,
                  label: service.id == selected?.id ? service.code : null,
                ),
                if (service.dropoff != null && service.id == selected?.id)
                  MapMarker(
                    position: service.dropoff!.geo,
                    kind: MapMarkerKind.dropoff,
                  ),
              ],
              for (final driver in onlineDrivers)
                MapMarker(
                  position: driver.position,
                  heading: driver.heading,
                  kind: driver.isStale(now)
                      ? MapMarkerKind.truckStale
                      : driver.state == DriverLiveState.onService
                          ? MapMarkerKind.truckOnService
                          : MapMarkerKind.truckIdle,
                ),
            ],
          ),
        ),
        Positioned(
          top: Insets.lg,
          right: Insets.lg,
          child: _Legend(drivers: onlineDrivers, now: now),
        ),
      ],
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.drivers, required this.now});

  final List<DriverLivePosition> drivers;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final idle = drivers
        .where((d) => d.state == DriverLiveState.idle && !d.isStale(now))
        .length;
    final busy = drivers.where((d) => d.state == DriverLiveState.onService).length;
    final stale = drivers.where((d) => d.isStale(now)).length;

    return FloatingCard(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.lg,
        vertical: Insets.md,
      ),
      borderRadius: Corners.brSm,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const FieldLabel('Flota en línea'),
          const SizedBox(height: Insets.sm),
          _LegendRow(color: BrandColors.driverIdle, label: 'Disponibles', count: idle),
          _LegendRow(
            color: BrandColors.driverOnService,
            label: 'En servicio',
            count: busy,
          ),
          // A truck whose last fix is old is not dispatchable, whatever the
          // online flag says — surfacing it separately keeps the dispatcher
          // from counting on a phone that lost signal.
          _LegendRow(
            color: BrandColors.driverStale,
            label: 'Sin señal',
            count: stale,
          ),
        ],
      ),
    );
  }
}

class _LegendRow extends StatelessWidget {
  const _LegendRow({
    required this.color,
    required this.label,
    required this.count,
  });

  final Color color;
  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: Insets.sm),
          SizedBox(
            width: 96,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Text(
            '$count',
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(fontFeatures: const []),
          ),
        ],
      ),
    );
  }
}

/// Detail and actions for one service.
class _ServiceDrawer extends ConsumerWidget {
  const _ServiceDrawer({required this.service, required this.onClose});

  final Service service;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final events = ref.watch(serviceEventsProvider(service.id)).value ?? const [];

    return ColoredBox(
      color: BrandColors.white,
      child: ListView(
        padding: const EdgeInsets.all(Insets.lg),
        children: [
          Row(
            children: [
              Expanded(child: Text(service.code, style: text.titleLarge)),
              IconButton(onPressed: onClose, icon: const Icon(Icons.close)),
            ],
          ),
          StatusChip(service.status),
          const SizedBox(height: Insets.lg),

          if (service.status == ServiceStatus.needsManual)
            const InlineNotice(
              message: 'La búsqueda automática no encontró chofer. Asigna uno '
                  'manualmente.',
              tone: NoticeTone.error,
            ),

          const SizedBox(height: Insets.lg),
          RouteSummary(
            pickup: service.pickup.displayAddress,
            pickupReference: service.pickup.reference,
            dropoff: service.dropoff?.displayAddress,
          ),
          const Divider(height: Insets.xxl),

          DetailRow(label: 'Cliente', value: service.clientName),
          DetailRow(label: 'Teléfono', value: service.clientPhone),
          DetailRow(label: 'Vehículo', value: service.vehicle.displayName),
          DetailRow(label: 'Problema', value: service.vehicle.condition.label),
          DetailRow(label: 'Grúa', value: service.truckTypeRequired.label),
          if (service.hasDriver)
            DetailRow(label: 'Chofer', value: service.driverName),
          DetailRow(
            label: 'Asignación',
            value: service.assignmentMode.label,
          ),
          DetailRow(
            label: 'Pago',
            value: '${service.payment.method.label} · '
                '${service.payment.status.label}',
          ),
          DetailRow(
            label: 'Total',
            value: service.totalCents.formatDOP,
            emphasise: true,
          ),

          const SizedBox(height: Insets.lg),
          if (!service.hasDriver)
            _AssignPanel(service: service)
          else
            OutlinedButton.icon(
              onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Llamando a ${service.driverName}…')),
              ),
              icon: const Icon(Icons.call, size: 18),
              label: const Text('Contactar chofer'),
            ),

          if (events.isNotEmpty) ...[
            const Divider(height: Insets.xxl),
            Text('Historial', style: text.titleSmall),
            const SizedBox(height: Insets.sm),
            for (final event in events)
              Padding(
                padding: const EdgeInsets.only(bottom: Insets.sm),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 5),
                      child: Icon(Icons.circle, size: 7, color: BrandColors.red),
                    ),
                    const SizedBox(width: Insets.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(event.description, style: text.bodySmall),
                          if (event.at != null)
                            Text(
                              DoTime.time(event.at!),
                              style: text.bodySmall?.copyWith(
                                color: BrandColors.grey400,
                                fontSize: 11,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// Manual assignment, ordered by the same score the dispatcher uses.
class _AssignPanel extends ConsumerWidget {
  const _AssignPanel({required this.service});

  final Service service;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final drivers = ref.watch(allDriversProvider).value ?? const [];
    final live = ref.watch(liveDriverPositionsProvider).value ?? const [];
    final now = DateTime.now().toUtc();
    final text = Theme.of(context).textTheme;

    final positions = {for (final p in live) p.driverId: p};

    final candidates = drivers
        .where((d) =>
            d.status.canWork &&
            d.isOnline &&
            !d.isBusy &&
            d.truckType == service.truckTypeRequired &&
            positions[d.id] != null &&
            !positions[d.id]!.isStale(now))
        .toList()
      ..sort((a, b) {
        final da = positions[a.id]!.position.distanceTo(service.pickup.geo);
        final db = positions[b.id]!.position.distanceTo(service.pickup.geo);
        return da.compareTo(db);
      });

    if (candidates.isEmpty) {
      return const InlineNotice(
        message: 'No hay choferes disponibles con el tipo de grúa requerido.',
        tone: NoticeTone.warning,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Asignar manualmente', style: text.titleSmall),
        const SizedBox(height: Insets.sm),
        for (final driver in candidates.take(5))
          Card(
            margin: const EdgeInsets.only(bottom: Insets.sm),
            color: BrandColors.offWhite,
            child: ListTile(
              dense: true,
              title: Text(driver.shortName, style: text.titleSmall),
              subtitle: Text(
                '${positions[driver.id]!.position.distanceKmTo(service.pickup.geo).toStringAsFixed(1)} km · '
                'acepta ${driver.acceptanceLabel} · ${driver.assignedTruckPlate}',
                style: text.bodySmall,
              ),
              trailing: TextButton(
                onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Asignando a ${driver.shortName}…'),
                  ),
                ),
                child: const Text('Asignar'),
              ),
            ),
          ),
      ],
    );
  }
}
