import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

import '../drivers/driver_details_dialog.dart';

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

/// Which roster the left panel is showing.
enum _Panel { services, drivers }

class _OperationsScreenState extends ConsumerState<OperationsScreen> {
  _Panel _panel = _Panel.services;
  String? _selectedId;
  String? _selectedDriverId;
  String _driverQuery = '';

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
      // Arriving from another screen with a service in hand: show that job,
      // whatever tab the dispatcher left the panel on.
      if (widget.selectedServiceId != null) {
        _panel = _Panel.services;
        _selectedDriverId = null;
      }
    }
  }

  // Only one thing is inspected at a time: a service and a chofer would fight
  // over the map's camera and over the right-hand drawer.
  void _selectService(String id) => setState(() {
        _panel = _Panel.services;
        _selectedId = id;
        _selectedDriverId = null;
      });

  void _selectDriver(String id) => setState(() {
        _panel = _Panel.drivers;
        _selectedDriverId = id;
        _selectedId = null;
      });

  @override
  Widget build(BuildContext context) {
    final services = ref.watch(activeServicesProvider).value ?? const [];
    final roster = ref.watch(allDriversProvider);
    final live = ref.watch(liveDriverPositionsProvider).value ?? const [];
    // Empty until `/presence` answers: everyone reads as disconnected for a
    // moment, which is better than the panel waiting on a second stream.
    final appOpen =
        ref.watch(connectedDriverIdsProvider).value ?? const <String>{};
    final now = DateTime.now().toUtc();

    // needs_manual first, then oldest first — the dispatcher's real priority.
    final ordered = [...services]..sort((a, b) {
        final aUrgent = a.status == ServiceStatus.needsManual ? 0 : 1;
        final bUrgent = b.status == ServiceStatus.needsManual ? 0 : 1;
        if (aUrgent != bUrgent) return aUrgent.compareTo(bUrgent);
        return (a.createdAt ?? now).compareTo(b.createdAt ?? now);
      });

    // A deleted chofer is archived, not erased; the panel is for the living.
    // Dispatchable first, then by name — the top of this list is who the
    // dispatcher can actually send.
    final drivers = (roster.value ?? const <Driver>[])
        .where((d) => !d.archived)
        .toList()
      ..sort((a, b) {
        final rank =
            _presenceRank(a, appOpen).compareTo(_presenceRank(b, appOpen));
        if (rank != 0) return rank;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

    final positions = {for (final p in live) p.driverId: p};
    final selected = ordered.where((s) => s.id == _selectedId).firstOrNull;
    final selectedDriver =
        drivers.where((d) => d.id == _selectedDriverId).firstOrNull;
    final driverPosition =
        selectedDriver == null ? null : positions[selectedDriver.id];

    return Row(
      children: [
        SizedBox(
          width: 340,
          child: ColoredBox(
            color: BrandColors.white,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _PanelTabs(
                  panel: _panel,
                  serviceCount: ordered.length,
                  driverCount: drivers.length,
                  onSelect: (panel) => setState(() => _panel = panel),
                ),
                const Divider(height: 1),
                Expanded(
                  child: switch (_panel) {
                    _Panel.services => _ServiceList(
                        services: ordered,
                        selectedId: _selectedId,
                        now: now,
                        onSelect: _selectService,
                      ),
                    _Panel.drivers => _DriverList(
                        roster: roster,
                        drivers: drivers,
                        positions: positions,
                        appOpen: appOpen,
                        selectedId: _selectedDriverId,
                        query: _driverQuery,
                        now: now,
                        onQuery: (value) =>
                            setState(() => _driverQuery = value),
                        onSelect: _selectDriver,
                        onRetry: () => ref.invalidate(allDriversProvider),
                      ),
                  },
                ),
              ],
            ),
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: _LiveMap(
            services: ordered,
            live: live,
            selected: selected,
            selectedDriver: selectedDriver,
            driverPosition: driverPosition,
            now: now,
            hasApiKey: ref.watch(hasMapsKeyProvider),
            onDriverTap: _selectDriver,
          ),
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
        ] else if (selectedDriver != null) ...[
          const VerticalDivider(width: 1),
          SizedBox(
            width: 380,
            child: _DriverDrawer(
              driver: selectedDriver,
              position: driverPosition,
              appOpen: appOpen.contains(selectedDriver.id),
              now: now,
              onClose: () => setState(() => _selectedDriverId = null),
              onOpenService: _selectService,
            ),
          ),
        ],
      ],
    );
  }
}

/// Roster order: who can take a job right now, first.
int _presenceRank(Driver driver, Set<String> appOpen) =>
    switch (driver.presence(appOpen: appOpen.contains(driver.id))) {
      DriverPresence.online => 0,
      DriverPresence.busy => 1,
      DriverPresence.connected => 2,
      DriverPresence.offline => 3,
    };

/// The left panel's two rosters: the open jobs, and the whole fleet.
class _PanelTabs extends StatelessWidget {
  const _PanelTabs({
    required this.panel,
    required this.serviceCount,
    required this.driverCount,
    required this.onSelect,
  });

  final _Panel panel;
  final int serviceCount;
  final int driverCount;
  final ValueChanged<_Panel> onSelect;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _PanelTab(
            label: 'Servicios activos',
            count: serviceCount,
            selected: panel == _Panel.services,
            onTap: () => onSelect(_Panel.services),
          ),
        ),
        Expanded(
          child: _PanelTab(
            // Not "Choferes": that is the sidebar's roster page, and this tab
            // is the fleet as the map sees it right now.
            label: 'Flota',
            count: driverCount,
            selected: panel == _Panel.drivers,
            onTap: () => onSelect(_Panel.drivers),
          ),
        ),
      ],
    );
  }
}

class _PanelTab extends StatelessWidget {
  const _PanelTab({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Material(
      color: BrandColors.white,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected ? BrandColors.red : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(
            Insets.lg,
            Insets.lg,
            Insets.lg,
            Insets.lg - 2,
          ),
          child: Row(
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleSmall?.copyWith(
                    color: selected ? BrandColors.ink : BrandColors.grey600,
                  ),
                ),
              ),
              const SizedBox(width: Insets.sm),
              Text(
                '$count',
                style: text.labelMedium?.copyWith(color: BrandColors.grey600),
              ),
            ],
          ),
        ),
      ),
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
    if (services.isEmpty) {
      return const EmptyState(
        title: 'Todo tranquilo',
        message: 'No hay servicios activos ahora mismo.',
        icon: Icons.check_circle_outline,
        tone: EmptyStateTone.success,
      );
    }

    return ListView.separated(
      itemCount: services.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) => _ServiceRow(
        service: services[index],
        selected: services[index].id == selectedId,
        now: now,
        onTap: () => onSelect(services[index].id),
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
    required this.selectedDriver,
    required this.driverPosition,
    required this.now,
    required this.hasApiKey,
    required this.onDriverTap,
  });

  final List<Service> services;
  final List<DriverLivePosition> live;
  final Service? selected;

  /// The chofer picked from the roster, if any. Their truck is labelled and
  /// the camera goes to it.
  final Driver? selectedDriver;
  final DriverLivePosition? driverPosition;
  final DateTime now;
  final bool hasApiKey;
  final ValueChanged<String> onDriverTap;

  @override
  Widget build(BuildContext context) {
    final onlineDrivers = live.where((p) => p.isOnline).toList();
    final focus = driverPosition?.position ?? selected?.pickup.geo;

    return Stack(
      children: [
        Positioned.fill(
          child: GruaMap(
            center: focus ?? DoLocations.defaultCenter,
            hasApiKey: hasApiKey,
            zoom: focus == null ? 12.4 : 13.6,
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
                  // Keeps a truck the same marker as the fleet moves around
                  // it, so the label stays on the chofer it belongs to.
                  id: 'driver:${driver.driverId}',
                  position: driver.position,
                  heading: driver.heading,
                  label: driver.driverId == selectedDriver?.id
                      ? selectedDriver!.shortName
                      : null,
                  onTap: () => onDriverTap(driver.driverId),
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


/// The whole fleet, one row per chofer.
///
/// The roster page is where a chofer is edited; this list is for the map — who
/// is out there, who can take the next job, and where they are right now.
class _DriverList extends StatelessWidget {
  const _DriverList({
    required this.roster,
    required this.drivers,
    required this.positions,
    required this.appOpen,
    required this.selectedId,
    required this.query,
    required this.now,
    required this.onQuery,
    required this.onSelect,
    required this.onRetry,
  });

  final AsyncValue<List<Driver>> roster;
  final List<Driver> drivers;
  final Map<String, DriverLivePosition> positions;

  /// Ids of the choferes with the app open right now.
  final Set<String> appOpen;
  final String? selectedId;
  final String query;
  final DateTime now;
  final ValueChanged<String> onQuery;
  final ValueChanged<String> onSelect;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final needle = query.trim().toLowerCase();
    final filtered = drivers.where((d) {
      if (needle.isEmpty) return true;
      return d.name.toLowerCase().contains(needle) ||
          d.cedula.contains(needle) ||
          d.phone.contains(needle) ||
          d.assignedTruckPlate.toLowerCase().contains(needle);
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(Insets.md),
          child: SizedBox(
            height: 38,
            child: TextField(
              onChanged: onQuery,
              decoration: const InputDecoration(
                hintText: 'Nombre, cédula o placa',
                prefixIcon: Icon(Icons.search, size: 18),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _body(filtered)),
      ],
    );
  }

  Widget _body(List<Driver> filtered) {
    // Loading and error only take over before the first roster arrives: once
    // it has, a dropped stream should not blank the list out from under
    // whoever is reading it.
    if (!roster.hasValue) {
      if (roster.hasError) {
        final error = roster.error;
        return EmptyState(
          title: 'No se pudo cargar',
          message: error is Failure
              ? error.userMessage
              : 'La lista de choferes no está disponible ahora mismo.',
          icon: Icons.cloud_off_outlined,
          tone: EmptyStateTone.error,
          actionLabel: 'Reintentar',
          onAction: onRetry,
        );
      }
      return const BrandLoader(message: 'Cargando choferes…');
    }

    if (drivers.isEmpty) {
      return const EmptyState(
        title: 'Todavía no hay choferes',
        message: 'Crea el primero desde la página de Choferes.',
        icon: Icons.badge_outlined,
      );
    }
    if (filtered.isEmpty) {
      return const EmptyState(
        title: 'Sin resultados',
        message: 'Ningún chofer coincide con esa búsqueda.',
        icon: Icons.search_off,
      );
    }

    return ListView.separated(
      itemCount: filtered.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final driver = filtered[index];
        return _DriverRow(
          driver: driver,
          position: positions[driver.id],
          appOpen: appOpen.contains(driver.id),
          selected: driver.id == selectedId,
          now: now,
          onTap: () => onSelect(driver.id),
        );
      },
    );
  }
}

class _DriverRow extends StatelessWidget {
  const _DriverRow({
    required this.driver,
    required this.position,
    required this.appOpen,
    required this.selected,
    required this.now,
    required this.onTap,
  });

  final Driver driver;
  final DriverLivePosition? position;
  final bool appOpen;
  final bool selected;
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final (status, statusColor) = _status(driver, position, now, appOpen);

    return Material(
      color: selected ? BrandColors.redTint : BrandColors.white,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.lg,
            vertical: Insets.md,
          ),
          child: Row(
            children: [
              DriverAvatar.of(driver, appOpen: appOpen, size: 38),
              const SizedBox(width: Insets.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            driver.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.titleSmall,
                          ),
                        ),
                        // The account state only earns space when it is not
                        // the ordinary one; presence is the avatar's dot.
                        if (driver.status != DriverStatus.active)
                          _AccountPill(status: driver.status),
                      ],
                    ),
                    const SizedBox(height: Insets.xs),
                    Text(
                      driver.assignedTruckId == null
                          ? 'Sin grúa asignada'
                          : '${driver.assignedTruckPlate} · '
                              '${driver.truckType.label}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          text.bodySmall?.copyWith(color: BrandColors.grey600),
                    ),
                    const SizedBox(height: Insets.xs),
                    Row(
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: statusColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            status,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodySmall?.copyWith(color: statusColor),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One line for what this chofer is doing, in dispatch terms.
///
/// A truck whose last fix is old is not dispatchable, whatever the online
/// switch says — that is why "sin señal" outranks "disponible" here, the same
/// way the map's legend counts it separately.
(String, Color) _status(
  Driver driver,
  DriverLivePosition? position,
  DateTime now,
  bool appOpen,
) {
  if (driver.isBusy) return ('En servicio', BrandColors.driverOnService);
  if (driver.isOnline) {
    if (position == null) {
      return ('En línea · sin ubicación', BrandColors.driverStale);
    }
    if (position.isStale(now)) {
      return (
        'Sin señal · ${DoTime.relative(position.updatedAtUtc, now: now)}',
        BrandColors.driverStale,
      );
    }
    return ('Disponible', BrandColors.driverIdle);
  }
  if (appOpen) return ('Conectado, sin turno', BrandColors.grey600);
  return (
    driver.lastOnlineAt == null
        ? 'Desconectado'
        : 'Desconectado · ${DoTime.relative(driver.lastOnlineAt!, now: now)}',
    BrandColors.grey600,
  );
}

class _AccountPill extends StatelessWidget {
  const _AccountPill({required this.status});

  final DriverStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, fg, bg) = switch (status) {
      DriverStatus.active =>
        ('Activo', BrandColors.success, BrandColors.successTint),
      DriverStatus.inactive =>
        ('Inactivo', BrandColors.grey600, BrandColors.grey100),
      DriverStatus.suspended =>
        ('Suspendido', BrandColors.danger, BrandColors.dangerTint),
      DriverStatus.unknown => ('—', BrandColors.grey600, BrandColors.grey100),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Insets.sm, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: Corners.brXs),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg),
      ),
    );
  }
}

/// What the dispatcher needs about one chofer without leaving the map.
///
/// Everything that changes the account — editing, suspending, deleting — stays
/// on the Choferes page, one button away.
class _DriverDrawer extends StatelessWidget {
  const _DriverDrawer({
    required this.driver,
    required this.position,
    required this.appOpen,
    required this.now,
    required this.onClose,
    required this.onOpenService,
  });

  final Driver driver;
  final DriverLivePosition? position;
  final bool appOpen;
  final DateTime now;
  final VoidCallback onClose;
  final ValueChanged<String> onOpenService;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final (status, statusColor) = _status(driver, position, now, appOpen);
    final serviceId = driver.currentServiceId;

    return ColoredBox(
      color: BrandColors.white,
      child: ListView(
        padding: const EdgeInsets.all(Insets.lg),
        children: [
          Row(
            children: [
              DriverAvatar.of(driver, appOpen: appOpen, size: 44),
              const SizedBox(width: Insets.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(driver.name, style: text.titleLarge),
                    Text(
                      status,
                      style: text.bodySmall?.copyWith(color: statusColor),
                    ),
                  ],
                ),
              ),
              IconButton(onPressed: onClose, icon: const Icon(Icons.close)),
            ],
          ),
          const SizedBox(height: Insets.md),
          Align(
            alignment: Alignment.centerLeft,
            child: _AccountPill(status: driver.status),
          ),
          if (driver.statusReason.isNotEmpty) ...[
            const SizedBox(height: Insets.md),
            InlineNotice(
              message: driver.statusReason,
              tone: driver.status.canWork
                  ? NoticeTone.info
                  : NoticeTone.warning,
            ),
          ],
          const Divider(height: Insets.xxl),

          DetailRow(label: 'Teléfono', value: driver.phone),
          DetailRow(label: 'Cédula', value: driver.displayCedula),
          DetailRow(
            label: 'Grúa',
            value: driver.assignedTruckId == null
                ? 'Sin asignar'
                : '${driver.assignedTruckPlate} · ${driver.truckType.label}',
          ),
          DetailRow(label: 'Acepta', value: driver.acceptanceLabel),
          DetailRow(label: 'Servicios', value: '${driver.completedServices}'),
          DetailRow(
            label: 'Efectivo en mano',
            value: driver.cashOwedCents == 0
                ? '—'
                : driver.cashOwedCents.formatDOP,
            emphasise: driver.cashOwedCents > 0,
          ),
          DetailRow(
            label: 'Última señal',
            value: position == null
                ? 'Sin ubicación'
                : DoTime.relative(position!.updatedAtUtc, now: now),
          ),

          const SizedBox(height: Insets.lg),
          if (serviceId != null && serviceId.isNotEmpty)
            OutlinedButton.icon(
              onPressed: () => onOpenService(serviceId),
              icon: const Icon(Icons.assignment_outlined, size: 18),
              label: const Text('Ver servicio en curso'),
            ),
          const SizedBox(height: Insets.sm),
          TextButton.icon(
            onPressed: () =>
                unawaited(showDriverDetailsDialog(context, driver)),
            icon: const Icon(Icons.badge_outlined, size: 18),
            label: const Text('Ver ficha completa'),
          ),
        ],
      ),
    );
  }
}
