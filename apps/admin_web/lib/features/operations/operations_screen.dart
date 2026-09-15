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
enum _Panel { requests, services, drivers }

class _OperationsScreenState extends ConsumerState<OperationsScreen> {
  // Opens on the queue: a request nobody has taken is the only thing on this
  // screen with a customer sitting on the shoulder behind it.
  _Panel _panel = _Panel.requests;
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
        // Whichever list of jobs they were reading, they stay in it. Only the
        // fleet tab has to give way, since the job is not in it.
        if (_panel == _Panel.drivers) _panel = _Panel.services;
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
    // The AsyncValue, not just its value: a query that fails — a missing
    // index, a caller without the staff claim — used to collapse to `[]` and
    // render as "Todo tranquilo", which is the most dangerous thing this
    // screen can say. A dispatcher has to be told the list is broken.
    final servicesAsync = ref.watch(activeServicesProvider);
    final services = servicesAsync.value ?? const <Service>[];
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

    // What a client has sent and no chofer has taken yet.
    final requests =
        ordered.where((s) => s.status.isAwaitingDriver).toList(growable: false);

    final positions = {for (final p in live) p.driverId: p};
    final selected = ordered.where((s) => s.id == _selectedId).firstOrNull;

    // With a request open, the map answers one question — who could take this
    // one — so it stops drawing every truck in the fleet. The filters are the
    // cascade's own, in the same order, so what the dispatcher sees is what
    // dispatch is choosing between.
    final byId = {for (final d in drivers) d.id: d};
    final eligible = selected == null || !selected.status.isAwaitingDriver
        ? null
        : <String>{
            for (final p in live)
              if (p.isOnline &&
                  !p.isStale(now) &&
                  p.state == DriverLiveState.idle &&
                  p.truckType.canServe(selected.truckTypeRequired) &&
                  (byId[p.driverId]?.status.canWork ?? false) &&
                  (byId[p.driverId]?.currentServiceId ?? '').isEmpty)
                p.driverId,
          };
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
                  requestCount: requests.length,
                  serviceCount: ordered.length,
                  driverCount: drivers.length,
                  onSelect: (panel) => setState(() => _panel = panel),
                ),
                const Divider(height: 1),
                Expanded(
                  child: switch (_panel) {
                    _Panel.requests => _RequestList(
                        stream: servicesAsync,
                        requests: requests,
                        selectedId: _selectedId,
                        now: now,
                        onSelect: _selectService,
                        onRetry: () => ref.invalidate(activeServicesProvider),
                      ),
                    _Panel.services => _ServiceList(
                        stream: servicesAsync,
                        services: ordered,
                        selectedId: _selectedId,
                        now: now,
                        onSelect: _selectService,
                        onRetry: () => ref.invalidate(activeServicesProvider),
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
            eligible: eligible,
            // On the queue tab every request draws its whole trip, so the
            // dispatcher can see where each one is going without clicking
            // through them one at a time.
            routed: _panel == _Panel.requests ? requests : const [],
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

/// The left panel's three rosters: what has just come in, what is in flight,
/// and the whole fleet.
class _PanelTabs extends StatelessWidget {
  const _PanelTabs({
    required this.panel,
    required this.requestCount,
    required this.serviceCount,
    required this.driverCount,
    required this.onSelect,
  });

  final _Panel panel;
  final int requestCount;
  final int serviceCount;
  final int driverCount;
  final ValueChanged<_Panel> onSelect;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _PanelTab(
            label: 'Solicitudes',
            count: requestCount,
            // The one count on this screen worth colouring: it is a customer
            // waiting, and it is the dispatcher's to clear.
            urgent: requestCount > 0,
            selected: panel == _Panel.requests,
            onTap: () => onSelect(_Panel.requests),
          ),
        ),
        Expanded(
          child: _PanelTab(
            label: 'Activos',
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
    this.urgent = false,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  /// Draws the count as something to act on rather than a statistic.
  final bool urgent;

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
            Insets.md,
            Insets.lg,
            Insets.md,
            Insets.lg - 2,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
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
              if (urgent)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Insets.sm,
                    vertical: 1,
                  ),
                  decoration: const BoxDecoration(
                    color: BrandColors.red,
                    borderRadius: BorderRadius.all(
                      Radius.circular(Corners.pill),
                    ),
                  ),
                  child: Text(
                    '$count',
                    style: text.labelMedium?.copyWith(
                      color: BrandColors.white,
                    ),
                  ),
                )
              else
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

/// A stream that has not arrived, or never will.
///
/// Returns null when there is something to render. Loading and error only take
/// over before the first answer: once a list has arrived, a dropped stream
/// should not blank it out from under whoever is reading it.
Widget? _streamTrouble(
  AsyncValue<Object?> stream,
  VoidCallback onRetry,
  String what,
) {
  if (stream.hasValue) return null;
  if (stream.hasError) {
    final error = stream.error;
    return EmptyState(
      title: 'No se pudo cargar',
      message: error is Failure
          ? error.userMessage
          : 'La lista de $what no está disponible ahora mismo.',
      icon: Icons.cloud_off_outlined,
      tone: EmptyStateTone.error,
      actionLabel: 'Reintentar',
      onAction: onRetry,
    );
  }
  return BrandLoader(message: 'Cargando $what…');
}

/// What customers have asked for and no chofer has taken yet.
///
/// The cascade is already working on these, so this is not a to-do list so
/// much as the dispatcher's view of the queue — with the one job the system
/// has given up on, `needs_manual`, pinned to the top by the caller's sort.
class _RequestList extends StatelessWidget {
  const _RequestList({
    required this.stream,
    required this.requests,
    required this.selectedId,
    required this.now,
    required this.onSelect,
    required this.onRetry,
  });

  final AsyncValue<List<Service>> stream;
  final List<Service> requests;
  final String? selectedId;
  final DateTime now;
  final ValueChanged<String> onSelect;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final broken = _streamTrouble(stream, onRetry, 'solicitudes');
    if (broken != null) return broken;

    if (requests.isEmpty) {
      return const EmptyState(
        title: 'Sin solicitudes',
        message: 'Cuando un cliente pida una grúa aparecerá aquí al instante.',
        icon: Icons.inbox_outlined,
        tone: EmptyStateTone.success,
      );
    }

    return ListView.separated(
      itemCount: requests.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) => _RequestRow(
        request: requests[index],
        selected: requests[index].id == selectedId,
        now: now,
        onTap: () => onSelect(requests[index].id),
      ),
    );
  }
}

/// One request: who, what is wrong with the vehicle, from where, to where, and
/// how long they have been waiting.
class _RequestRow extends StatelessWidget {
  const _RequestRow({
    required this.request,
    required this.selected,
    required this.now,
    required this.onTap,
  });

  final Service request;
  final bool selected;
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final urgent = request.status == ServiceStatus.needsManual;
    final waiting = request.createdAt == null
        ? Duration.zero
        : now.difference(request.createdAt!);

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
                      request.code,
                      style: text.titleSmall?.copyWith(
                        color: urgent ? BrandColors.danger : BrandColors.ink,
                      ),
                    ),
                  ),
                  // The office's words: a customer sees "Buscando grúa" for
                  // both `pending_dispatch` and `offered`, and the difference
                  // between "nobody has been asked" and "a chofer is deciding
                  // right now" is the whole of this screen.
                  StatusChip(
                    request.status,
                    compact: true,
                    label: request.awaitsOperator
                        ? 'Por confirmar'
                        : request.status.officeLabel,
                  ),
                ],
              ),
              const SizedBox(height: Insets.xs),
              Text(
                [
                  request.clientName,
                  // "Mack Granite" does not say it is a patana; the type does.
                  if (request.vehicle.type.isHeavy) request.vehicle.type.label,
                  request.vehicle.displayName,
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall?.copyWith(color: BrandColors.grey600),
              ),
              const SizedBox(height: Insets.sm),

              // Both ends, always. Whoever decides which truck to send needs
              // to know where the job goes as much as where it starts: a tow
              // to the next town is a different job from one across the street.
              _Endpoint(
                icon: Icons.my_location,
                color: BrandColors.red,
                label: request.pickup.displayAddress,
                note: request.pickup.reference,
              ),
              const SizedBox(height: Insets.xs),
              _Endpoint(
                icon: Icons.flag_outlined,
                color: BrandColors.ink,
                label: request.dropoff?.displayAddress ?? 'Sin destino',
                note: request.dropoff?.reference ?? '',
              ),

              const SizedBox(height: Insets.sm),
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
                  Flexible(
                    child: Text(
                      request.truckTypeRequired.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          text.bodySmall?.copyWith(color: BrandColors.grey600),
                    ),
                  ),
                ],
              ),

              // What the cascade found last time it looked. A request going
              // nowhere now says why — no grúa online, none of the right kind,
              // all of them already on a job — instead of sitting there.
              if (request.dispatch.lastReason.isNotEmpty) ...[
                const SizedBox(height: Insets.sm),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Icon(
                        Icons.search_off,
                        size: 14,
                        color: BrandColors.warning,
                      ),
                    ),
                    const SizedBox(width: Insets.sm),
                    Expanded(
                      child: Text(
                        request.dispatch.lastReason,
                        style: text.bodySmall?.copyWith(
                          color: BrandColors.grey600,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One end of a trip: an icon, the address, and the landmark under it.
class _Endpoint extends StatelessWidget {
  const _Endpoint({
    required this.icon,
    required this.color,
    required this.label,
    required this.note,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String note;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 14, color: color),
        ),
        const SizedBox(width: Insets.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall,
              ),
              if (note.isNotEmpty)
                Text(
                  note,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(
                    color: BrandColors.grey400,
                    fontSize: 11,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ServiceList extends StatelessWidget {
  const _ServiceList({
    required this.stream,
    required this.services,
    required this.selectedId,
    required this.now,
    required this.onSelect,
    required this.onRetry,
  });

  final AsyncValue<List<Service>> stream;
  final List<Service> services;
  final String? selectedId;
  final DateTime now;
  final ValueChanged<String> onSelect;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final broken = _streamTrouble(stream, onRetry, 'servicios');
    if (broken != null) return broken;

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
                  StatusChip(
                    service.status,
                    compact: true,
                    label: service.status.officeLabel,
                  ),
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
                  // Flexible: a chofer with a long name and a job that has
                  // been waiting two hours overflowed a 340-pixel panel.
                  Flexible(
                    child: Text(
                      service.hasDriver ? service.driverName : 'Sin asignar',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          text.bodySmall?.copyWith(color: BrandColors.grey600),
                    ),
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

class _LiveMap extends ConsumerWidget {
  const _LiveMap({
    required this.services,
    required this.routed,
    required this.eligible,
    required this.live,
    required this.selected,
    required this.selectedDriver,
    required this.driverPosition,
    required this.now,
    required this.hasApiKey,
    required this.onDriverTap,
  });

  final List<Service> services;

  /// The choferes who could take the selected request, or null when no
  /// request is open and the map shows the whole fleet.
  ///
  /// An empty set is not the same as null: it means the dispatcher asked and
  /// the answer is nobody, which is the most important thing this screen can
  /// say.
  final Set<String>? eligible;

  /// Services whose whole trip is drawn, not just their pickup — the queue,
  /// while the dispatcher is looking at it.
  final List<Service> routed;

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
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = eligible;
    final onlineDrivers = live
        .where((p) => p.isOnline)
        // A chofer picked from the roster stays on the map whatever else is
        // filtered: the dispatcher is looking at them on purpose.
        .where((p) =>
            filter == null ||
            filter.contains(p.driverId) ||
            p.driverId == selectedDriver?.id)
        .toList();
    final focus = driverPosition?.position ?? selected?.pickup.geo;

    // One job at a time. With a request open the map is about that request:
    // its two ends and the trucks that could take it. Every other pickup on
    // screen is a different customer's problem and only makes this one harder
    // to see.
    final shown = selected == null
        ? services
        : services.where((s) => s.id == selected!.id).toList();

    // A trip per queued request, plus the selected one wherever it came from.
    // Dashed, because none of these is a route anybody is driving yet — it is
    // the job, not a path.
    final trips = [
      if (selected == null)
        for (final service in routed)
          if (service.dropoff != null)
            MapRoute(
              points: [service.pickup.geo, service.dropoff!.geo],
              color: BrandColors.grey400,
              dashed: true,
            ),
    ];

    final selectedDropoff = selected?.dropoff?.geo;
    final storedPath = selected?.towPath ?? const <LatLng>[];
    final selectedRoad = storedPath.isNotEmpty
        ? storedPath
        : selected == null || selectedDropoff == null
            ? null
            : ref
                .watch(roadRouteProvider((selected!.pickup.geo, selectedDropoff)))
                .value
                ?.points;

    // What the camera has to hold: the whole job, and everyone who could take
    // it. A capable truck ninety kilometres away is worth seeing — that is the
    // dispatcher's answer about whether to wait or to call somebody in.
    final frame = <LatLng>[
      if (selected != null) ...[
        selected!.pickup.geo,
        if (selected!.dropoff != null) selected!.dropoff!.geo,
        for (final position in onlineDrivers)
          if (filter?.contains(position.driverId) ?? false) position.position,
      ],
    ];

    return Stack(
      children: [
        Positioned.fill(
          child: GruaMap(
            center: focus ?? DoLocations.defaultCenter,
            hasApiKey: hasApiKey,
            zoom: focus == null ? 12.4 : 13.6,
            // Framed rather than centred: a fixed zoom either cropped the
            // destination out or sat so far back the pickup was a speck.
            fitTo: frame,
            // The roads the tow will take, not a line over the mountains.
            // Falls back to the straight pair on its own when there is no
            // answer, so the job is always drawn.
            route: selectedRoad ??
                (selected?.dropoff == null
                    ? const []
                    : [selected!.pickup.geo, selected!.dropoff!.geo]),
            routes: trips,
            markers: [
              for (final service in shown) ...[
                MapMarker(
                  position: service.pickup.geo,
                  kind: MapMarkerKind.pickup,
                  label: service.id == selected?.id ? service.code : null,
                ),
                // The destination too, for anything whose trip is drawn —
                // a line to nowhere is worse than no line.
                if (service.dropoff != null &&
                    (service.id == selected?.id ||
                        (selected == null &&
                            routed.any((r) => r.id == service.id))))
                  MapMarker(
                    id: 'dropoff:${service.id}',
                    position: service.dropoff!.geo,
                    kind: MapMarkerKind.dropoff,
                    label: service.id == selected?.id
                        ? service.dropoff!.displayAddress
                        : null,
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (filter != null && selected != null) ...[
                _EligibleBanner(
                  service: selected!,
                  count: filter.length,
                ),
                const SizedBox(height: Insets.sm),
              ],
              _Legend(drivers: onlineDrivers, now: now),
            ],
          ),
        ),
      ],
    );
  }
}

/// Says what the map has been narrowed to, and to what.
///
/// Without this the fleet appears to have vanished the moment a request is
/// opened — which is exactly the kind of thing a dispatcher does not need to
/// wonder about at two in the morning.
class _EligibleBanner extends StatelessWidget {
  const _EligibleBanner({required this.service, required this.count});

  final Service service;
  final int count;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final none = count == 0;

    return FloatingCard(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.md,
        vertical: Insets.sm,
      ),
      borderRadius: Corners.brSm,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            none ? Icons.search_off : Icons.filter_alt_outlined,
            size: 16,
            color: none ? BrandColors.warning : BrandColors.grey600,
          ),
          const SizedBox(width: Insets.sm),
          Text(
            none
                ? 'Ninguna grúa de ${service.truckTypeRequired.label} libre'
                : '$count grúa${count == 1 ? '' : 's'} para '
                    '${service.truckTypeRequired.label}',
            style: text.labelMedium?.copyWith(
              color: none ? BrandColors.warning : BrandColors.ink,
            ),
          ),
          const SizedBox(width: Insets.sm),
          Text(
            service.code,
            style: text.bodySmall?.copyWith(color: BrandColors.grey600),
          ),
        ],
      ),
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
          StatusChip(
            service.status,
            label: service.awaitsOperator
                ? 'Por confirmar'
                : service.status.officeLabel,
          ),
          const SizedBox(height: Insets.lg),

          if (service.awaitsOperator)
            const InlineNotice(
              key: Key('heavy-review-notice'),
              message: 'Vehículo pesado. Llama al cliente, confirma que hay una '
                  'grúa pesada disponible y acuerda el precio final. Nadie sale '
                  'hasta que lo confirmes.',
              icon: Icons.support_agent,
              tone: NoticeTone.warning,
            )
          else if (service.status == ServiceStatus.needsManual)
            InlineNotice(
              message: service.dispatch.lastReason.isEmpty
                  ? 'La búsqueda automática no encontró chofer. Asigna uno '
                      'manualmente.'
                  : '${service.dispatch.lastReason} Asigna un chofer '
                      'manualmente.',
              tone: NoticeTone.error,
            )
          else if (service.dispatch.lastReason.isNotEmpty)
            // Still searching, but the last sweep came back empty. Saying so
            // is the difference between "wait" and "do something".
            InlineNotice(
              message: service.dispatch.lastReason,
              icon: Icons.search_off,
              tone: NoticeTone.warning,
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
          DetailRow(label: 'Tipo', value: service.vehicle.type.label),
          DetailRow(label: 'Vehículo', value: service.vehicle.displayName),
          DetailRow(label: 'Problema', value: service.vehicle.condition.label),
          if (service.vehicle.photoPaths.isNotEmpty) ...[
            const SizedBox(height: Insets.xs),
            VehiclePhotoStrip(urls: service.vehicle.photoPaths),
            const SizedBox(height: Insets.sm),
          ],
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
            label: service.awaitsOperator ? 'Total estimado' : 'Total',
            value: service.totalCents.formatDOP,
            emphasise: true,
          ),
          if (service.operatorReview?.isConfirmed ?? false)
            DetailRow(
              label: 'Estimado original',
              value: service.operatorReview!.estimatedTotalCents.formatDOP,
            ),

          const SizedBox(height: Insets.lg),
          if (service.awaitsOperator)
            _HeavyReviewPanel(service: service)
          else if (!service.hasDriver)
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

/// The operator's confirmation of a heavy job: the price agreed with the
/// customer, then the search for a heavy grúa starts.
class _HeavyReviewPanel extends ConsumerStatefulWidget {
  const _HeavyReviewPanel({required this.service});

  final Service service;

  @override
  ConsumerState<_HeavyReviewPanel> createState() => _HeavyReviewPanelState();
}

class _HeavyReviewPanelState extends ConsumerState<_HeavyReviewPanel> {
  late final TextEditingController _price = TextEditingController(
    // Starts at the estimate, in whole pesos: most often it is the price.
    text: '${(widget.service.totalCents / 100).round()}',
  );
  final TextEditingController _note = TextEditingController();
  var _sending = false;
  String? _error;

  @override
  void dispose() {
    _price.dispose();
    _note.dispose();
    super.dispose();
  }

  /// Pesos as the operator types them: `9500`, `9,500` or `9500.50`.
  int? get _cents {
    final pesos = double.tryParse(_price.text.replaceAll(',', '').trim());
    if (pesos == null || pesos < 100) return null;
    return (pesos * 100).round();
  }

  Future<void> _confirm() async {
    final cents = _cents;
    if (cents == null) {
      setState(() => _error = r'Escribe el precio en pesos, desde RD$100.');
      return;
    }
    if (_sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });

    final messenger = ScaffoldMessenger.of(context);
    final result = await ref.read(functionsGatewayProvider).confirmHeavyService(
          serviceId: widget.service.id,
          totalCents: cents,
          note: _note.text.trim(),
        );

    if (mounted) setState(() => _sending = false);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          switch (result) {
            Ok<void>() =>
              'Precio confirmado: ${cents.formatDOP}. Buscando grúa pesada.',
            Err<void>(:final failure) => failure.userMessage,
          },
        ),
        backgroundColor: result.isOk ? BrandColors.success : BrandColors.danger,
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: result.isOk ? 3 : 6),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Confirmar precio final', style: text.titleSmall),
        const SizedBox(height: Insets.sm),
        TextField(
          key: const Key('heavy-price'),
          controller: _price,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            prefixText: r'RD$ ',
            labelText: 'Precio acordado con el cliente',
            helperText: 'Lo que paga el cliente'
                '${widget.service.quote.itbisCents > 0 ? ', ITBIS incluido' : ''}.',
            errorText: _error,
          ),
          onSubmitted: (_) => _confirm(),
        ),
        const SizedBox(height: Insets.sm),
        TextField(
          controller: _note,
          maxLength: 300,
          decoration: const InputDecoration(labelText: 'Nota (opcional)'),
        ),
        const SizedBox(height: Insets.sm),
        ElevatedButton.icon(
          key: const Key('heavy-confirm'),
          onPressed: _sending ? null : _confirm,
          icon: _sending
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2.2),
                )
              : const Icon(Icons.check, size: 18),
          label: const Text('Confirmar y buscar grúa'),
        ),
      ],
    );
  }
}

/// Manual assignment, ordered by the same score the dispatcher uses.
class _AssignPanel extends ConsumerStatefulWidget {
  const _AssignPanel({required this.service});

  final Service service;

  @override
  ConsumerState<_AssignPanel> createState() => _AssignPanelState();
}

class _AssignPanelState extends ConsumerState<_AssignPanel> {
  /// The chofer an assignment is in flight for, if any. One at a time: a
  /// dispatcher double-clicking through a list must not send two.
  String? _sending;

  Future<void> _assign(Driver driver) async {
    if (_sending != null) return;
    setState(() => _sending = driver.id);

    // Taken before the call: a successful assignment moves the service out of
    // the queue and this panel goes with it, and the refusal is exactly what
    // the dispatcher needs when it does not.
    final messenger = ScaffoldMessenger.of(context);

    final result = await ref.read(functionsGatewayProvider).assignServiceManually(
          serviceId: widget.service.id,
          driverId: driver.id,
        );

    if (mounted) setState(() => _sending = null);

    messenger.showSnackBar(
      SnackBar(
        content: Text(
          switch (result) {
            Ok<void>() => '${driver.shortName} va en camino.',
            Err<void>(:final failure) => failure.userMessage,
          },
        ),
        backgroundColor: result.isOk ? BrandColors.success : BrandColors.danger,
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: result.isOk ? 3 : 6),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    final drivers = ref.watch(allDriversProvider).value ?? const [];
    final live = ref.watch(liveDriverPositionsProvider).value ?? const [];
    final now = DateTime.now().toUtc();
    final text = Theme.of(context).textTheme;

    final positions = {for (final p in live) p.driverId: p};

    // The same rule the cascade uses, and the same one the map filters by: a
    // plataforma can do a gancho job. Exact-match here hid the very truck
    // dispatch would have chosen.
    final candidates = drivers
        .where((d) =>
            d.status.canWork &&
            d.isOnline &&
            !d.isBusy &&
            d.truckType.canServe(service.truckTypeRequired) &&
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
                'acepta ${driver.acceptanceLabel} · ${driver.assignedTruckPlate}'
                // Say so when it is not the truck the job asked for.
                '${driver.truckType == service.truckTypeRequired ? '' : ' · ${driver.truckType.label}'}',
                style: text.bodySmall,
              ),
              trailing: _sending == driver.id
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.2),
                    )
                  : TextButton(
                      // Every row is disabled while one is in flight, so a
                      // second chofer cannot be sent to the same job.
                      onPressed: _sending == null ? () => _assign(driver) : null,
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
    final broken = _streamTrouble(roster, onRetry, 'choferes');
    if (broken != null) return broken;

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
