import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../router.dart';
import '../notifications/notification_widgets.dart';

/// The job in progress.
///
/// One primary action at a time — Llegué, then Iniciar servicio, then
/// Finalizar, then Cobrar — because a chofer holding a phone next to a
/// flatbed should never have to decide which of four buttons applies.
///
/// Every one of those actions is a server call with a guard behind it. The
/// screen shows the outcome, it does not decide it: "Llegué" from two
/// kilometres away is refused by `markArrived`, and the refusal tells the
/// chofer how far off they are rather than just failing.
class ActiveServiceScreen extends ConsumerStatefulWidget {
  const ActiveServiceScreen({super.key});

  @override
  ConsumerState<ActiveServiceScreen> createState() =>
      _ActiveServiceScreenState();
}

class _ActiveServiceScreenState extends ConsumerState<ActiveServiceScreen> {
  var _busy = false;

  Future<void> _run(Future<Result<void>> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    final result = await action();
    if (!mounted) return;
    setState(() => _busy = false);

    if (result case Err(:final failure)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(failure.userMessage),
          backgroundColor: BrandColors.danger,
        ),
      );
    }
  }

  /// The chofer's own position: the phone's GPS first, then the last position
  /// the server mirrored (which is all the demo has), then the pickup itself
  /// so the range guards still have something to judge.
  LatLng _currentPosition(Service service) {
    final mine = ref.read(myPositionProvider).value?.position;
    if (mine != null) return mine;
    final tracking = ref.read(serviceTrackingProvider(service.id)).value;
    return tracking?.position ?? service.pickup.geo;
  }

  Future<void> _advance(Service service) async {
    final gateway = ref.read(functionsGatewayProvider);

    switch (service.status) {
      case ServiceStatus.accepted:
        await _run(() => gateway.markArrived(
              serviceId: service.id,
              position: _currentPosition(service),
            ));
      case ServiceStatus.arrived:
        await _run(() => gateway.startService(
              serviceId: service.id,
              photoPaths: const ['demo-pickup-1', 'demo-pickup-2'],
            ));
      case ServiceStatus.inProgress:
        await _confirmFinish(service);
      case ServiceStatus.completed:
        await _collectCash(service);
      case _:
        break;
    }
  }

  Future<void> _confirmFinish(Service service) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('¿Finalizar el servicio?'),
        content: const Text(
          'Confirma que ya entregaste el vehículo en el destino.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Todavía no'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sí, finalizar'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _run(() => ref.read(functionsGatewayProvider).completeService(
          serviceId: service.id,
          position: _currentPosition(service),
          photoPaths: const ['demo-dropoff-1'],
        ));
  }

  Future<void> _collectCash(Service service) async {
    if (service.payment.isCard) {
      await _run(() => ref.read(functionsGatewayProvider).confirmCashCollected(
            serviceId: service.id,
            amountCents: service.totalCents,
          ));
      return;
    }

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _CashSheet(amountCents: service.totalCents),
    );
    if (confirmed != true || !mounted) return;

    await _run(() => ref.read(functionsGatewayProvider).confirmCashCollected(
          serviceId: service.id,
          amountCents: service.totalCents,
        ));
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(activeDriverServiceProvider).value;
    if (service == null) return const Scaffold(body: BrandLoader());

    final tracking = ref.watch(serviceTrackingProvider(service.id)).value;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: BrandColors.redDeep,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
              child: Row(
                children: [
                  const GruaLogo(size: 62),
                  const SizedBox(width: Insets.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'EN SERVICIO',
                          style: text.titleMedium?.copyWith(
                            color: BrandColors.white,
                            letterSpacing: 1.2,
                          ),
                        ),
                        Text(
                          service.code,
                          style: text.bodySmall
                              ?.copyWith(color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                  StatusChip(service.status, compact: true),
                  // During a job is when the customer writes, so the bell
                  // comes along onto this screen.
                  const NotificationBell(onDark: true),
                ],
              ),
            ),
            const SizedBox(height: Insets.md),
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: const BoxDecoration(
                  color: BrandColors.offWhite,
                  borderRadius: Corners.sheet,
                ),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                    Insets.lg,
                    Insets.xl,
                    Insets.lg,
                    Insets.lg,
                  ),
                  children: [
                    _ServiceMap(service: service, tracking: tracking),
                    const SizedBox(height: Insets.lg),
                    _ClientCard(service: service),
                    const SizedBox(height: Insets.lg),
                    _JobCard(service: service),
                    if (service.status == ServiceStatus.arrived) ...[
                      const SizedBox(height: Insets.lg),
                      _WaitingCard(service: service),
                    ],
                    const SizedBox(height: Insets.xl),
                    _PrimaryAction(
                      service: service,
                      busy: _busy,
                      onPressed: () => _advance(service),
                    ),
                    const SizedBox(height: Insets.md),
                    _CancelButton(service: service, busy: _busy, onRun: _run),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The job on a map: where the chofer is, and the road to where they are
/// going next.
///
/// Before "Llegué" the next stop is the customer, and the tow is drawn dashed
/// after it; once the vehicle is loaded the next stop is the destination.
/// "Abrir en Google Maps" hands the same stop to real turn-by-turn navigation,
/// which is what a chofer actually drives by.
class _ServiceMap extends ConsumerWidget {
  const _ServiceMap({required this.service, required this.tracking});

  final Service service;
  final ServiceTracking? tracking;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mine = ref.watch(myPositionProvider).value;
    final me = mine?.position ?? tracking?.position;

    final pickup = service.pickup.geo;
    final dropoff = service.dropoff?.geo;
    final goingToPickup = service.status == ServiceStatus.accepted;
    final next = goingToPickup ? pickup : (dropoff ?? pickup);

    final toNext = me == null
        ? null
        : ref.watch(roadRouteProvider((routeGrain(me), next))).value;
    final tow = goingToPickup && dropoff != null
        ? ref.watch(roadRouteProvider((pickup, dropoff))).value
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 280,
          child: ClipRRect(
            borderRadius: Corners.brLg,
            child: GruaMap(
              center: me ?? next,
              hasApiKey: ref.watch(hasMapsKeyProvider),
              zoom: 14,
              showAttribution: false,
              fitTo: [
                ?me,
                next,
                if (goingToPickup) ?dropoff,
              ],
              routes: [
                if (tow != null)
                  MapRoute(points: tow.points, color: BrandColors.ink, dashed: true),
                if (toNext != null)
                  MapRoute(points: toNext.points, dashed: toNext.isApproximate),
                // Without a position yet, the plain trip still reads.
                if (me == null && dropoff != null)
                  MapRoute(points: [pickup, dropoff], color: BrandColors.ink, dashed: true),
              ],
              // Red for you, blue for the customer, black for the destination.
              markers: [
                MapMarker(position: pickup, kind: MapMarkerKind.customer, label: 'Cliente'),
                if (dropoff != null)
                  MapMarker(position: dropoff, kind: MapMarkerKind.dropoff, label: 'Destino'),
                if (me != null)
                  MapMarker(position: me, kind: MapMarkerKind.me, label: 'Tú'),
              ],
            ),
          ),
        ),
        const SizedBox(height: Insets.sm),
        Row(
          children: [
            Expanded(
              child: Text(
                toNext == null
                    ? (goingToPickup ? 'Hacia el cliente' : 'Hacia el destino')
                    : '${goingToPickup ? 'Al cliente' : 'Al destino'}: '
                        '${toNext.distanceLabel} · ${toNext.durationLabel}'
                        '${toNext.isApproximate ? ' (aprox.)' : ''}',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: BrandColors.grey800),
              ),
            ),
            TextButton.icon(
              onPressed: () => unawaited(_navigate(context, next)),
              icon: const Icon(Icons.navigation_outlined, size: 18),
              label: const Text('Abrir en Google Maps'),
            ),
          ],
        ),
      ],
    );
  }

  /// Turn-by-turn to [to] in Google Maps: the app on a phone, the site on the
  /// web. The universal URL works for both.
  Future<void> _navigate(BuildContext context, LatLng to) async {
    final url = Uri.https('www.google.com', '/maps/dir/', {
      'api': '1',
      'destination': '${to.latitude},${to.longitude}',
      'travelmode': 'driving',
    });
    final messenger = ScaffoldMessenger.of(context);
    final opened = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!opened) {
      messenger.showSnackBar(
        const SnackBar(content: Text('No se pudo abrir Google Maps.')),
      );
    }
  }
}

class _ClientCard extends ConsumerWidget {
  const _ClientCard({required this.service});

  final Service service;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final unread = ref.watch(unreadMessageCountProvider(service.id));

    return FloatingCard(
      child: Row(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: BrandColors.redTint,
            child: Text(
              service.clientName.isEmpty ? '?' : service.clientName[0],
              style: text.titleMedium?.copyWith(color: BrandColors.red),
            ),
          ),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(service.clientName, style: text.titleSmall),
                Text(
                  service.clientPhone,
                  style: text.bodySmall?.copyWith(color: BrandColors.grey600),
                ),
              ],
            ),
          ),
          if (service.canChat)
            IconButton.filledTonal(
              key: const Key('client-chat'),
              tooltip: 'Chat con el cliente',
              onPressed: () => context.push(Routes.chatFor(service.id)),
              icon: Badge.count(
                count: unread,
                isLabelVisible: unread > 0,
                backgroundColor: BrandColors.red,
                textColor: BrandColors.white,
                child: const Icon(Icons.chat_bubble_outline, size: 20),
              ),
            ),
          if (service.canCall)
            IconButton.filledTonal(
              onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Llamando a ${service.clientPhone}…')),
              ),
              icon: const Icon(Icons.call, size: 20),
            ),
        ],
      ),
    );
  }
}

class _JobCard extends StatelessWidget {
  const _JobCard({required this.service});

  final Service service;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return FloatingCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(service.vehicle.displayName, style: text.titleSmall),
          Text(
            service.vehicle.condition.label,
            style: text.bodySmall?.copyWith(color: BrandColors.grey600),
          ),
          const Divider(height: Insets.xxl),
          RouteSummary(
            pickup: service.pickup.displayAddress,
            pickupReference: service.pickup.reference,
            dropoff: service.dropoff?.displayAddress,
          ),
          const Divider(height: Insets.xxl),
          Row(
            children: [
              Icon(
                service.payment.isCash
                    ? Icons.payments_outlined
                    : Icons.credit_card,
                size: 18,
                color: BrandColors.grey600,
              ),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Text(
                  service.payment.isCash
                      ? 'Cobrar en efectivo'
                      : 'Pagado con ${service.payment.cardLabel}',
                  style: text.bodyMedium,
                ),
              ),
              Text(service.totalCents.formatDOP, style: text.titleMedium),
            ],
          ),
        ],
      ),
    );
  }
}

/// Live waiting clock, with what it will cost the customer.
class _WaitingCard extends ConsumerWidget {
  const _WaitingCard({required this.service});

  final Service service;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pricing = ref.watch(pricingConfigProvider).value;
    final arrivedAt = service.timeline.arrivedAt;
    if (arrivedAt == null || pricing == null) return const SizedBox.shrink();

    return StreamBuilder<void>(
      stream: Stream<void>.periodic(const Duration(seconds: 1)),
      builder: (context, _) {
        final elapsed = DateTime.now().toUtc().difference(arrivedAt);
        final free = Duration(minutes: pricing.freeWaitingMinutes);
        final over = elapsed - free;
        final chargeable = over.isNegative ? 0 : over.inMinutes;

        return InlineNotice(
          icon: Icons.timer_outlined,
          tone: chargeable > 0 ? NoticeTone.warning : NoticeTone.info,
          message: chargeable > 0
              ? 'Espera ${DoTime.stopwatch(elapsed)} · se cobrarán '
                  '${(chargeable * pricing.perWaitingMinuteCents).formatDOP}'
              : 'Espera ${DoTime.stopwatch(elapsed)} · '
                  '${pricing.freeWaitingMinutes} min sin cargo',
        );
      },
    );
  }
}

/// One button, whose label and colour follow the state machine.
class _PrimaryAction extends StatelessWidget {
  const _PrimaryAction({
    required this.service,
    required this.busy,
    required this.onPressed,
  });

  final Service service;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (service.status) {
      ServiceStatus.accepted => ('LLEGUÉ', BrandColors.red),
      ServiceStatus.arrived => ('INICIAR SERVICIO', BrandColors.red),
      ServiceStatus.inProgress => ('FINALIZAR SERVICIO', BrandColors.ink),
      ServiceStatus.completed => (
          service.payment.isCash ? 'COBRAR' : 'CERRAR SERVICIO',
          BrandColors.success,
        ),
      _ => ('ESPERANDO…', BrandColors.grey400),
    };

    final enabled = !busy &&
        const {
          ServiceStatus.accepted,
          ServiceStatus.arrived,
          ServiceStatus.inProgress,
          ServiceStatus.completed,
        }.contains(service.status);

    return ElevatedButton(
      onPressed: enabled ? onPressed : null,
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        minimumSize: const Size.fromHeight(62),
        shape: const RoundedRectangleBorder(borderRadius: Corners.brLg),
      ),
      child: busy
          ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                color: BrandColors.white,
              ),
            )
          : Text(label),
    );
  }
}

class _CancelButton extends ConsumerWidget {
  const _CancelButton({
    required this.service,
    required this.busy,
    required this.onRun,
  });

  final Service service;
  final bool busy;
  final Future<void> Function(Future<Result<void>> Function()) onRun;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Once the vehicle is loaded, dropping the job is an operations problem,
    // not a button.
    if (service.status == ServiceStatus.inProgress ||
        service.status == ServiceStatus.completed) {
      return const SizedBox.shrink();
    }

    return TextButton(
      onPressed: busy
          ? null
          : () async {
              final reason = await showModalBottomSheet<DriverCancelReason>(
                context: context,
                backgroundColor: Colors.transparent,
                builder: (_) => const _ReasonSheet(),
              );
              if (reason == null) return;
              await onRun(
                () => ref.read(functionsGatewayProvider).cancelByDriver(
                      serviceId: service.id,
                      reason: reason,
                    ),
              );
            },
      style: TextButton.styleFrom(foregroundColor: BrandColors.danger),
      child: const Text('No puedo hacer este servicio'),
    );
  }
}

/// Fixed reasons only — these feed the admin's abuse flags, and free text
/// cannot be counted.
class _ReasonSheet extends StatelessWidget {
  const _ReasonSheet();

  @override
  Widget build(BuildContext context) {
    const reasons = [
      DriverCancelReason.vehicleBreakdown,
      DriverCancelReason.wrongTruckType,
      DriverCancelReason.clientNotPresent,
      DriverCancelReason.clientRefused,
      DriverCancelReason.inaccessibleLocation,
      DriverCancelReason.unsafeLocation,
      DriverCancelReason.emergency,
    ];

    return BottomActionSheet(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '¿Por qué no puedes hacerlo?',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: Insets.md),
          for (final reason in reasons)
            ListTile(
              title: Text(reason.label),
              onTap: () => Navigator.of(context).pop(reason),
              trailing: const Icon(Icons.chevron_right,
                  color: BrandColors.grey400),
            ),
        ],
      ),
    );
  }
}

/// The amount to collect, in the largest type on the screen, with change from
/// the notes a Dominican customer actually hands over.
class _CashSheet extends StatelessWidget {
  const _CashSheet({required this.amountCents});

  final int amountCents;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final usefulBills = Money.commonBillsCents
        .where((bill) => bill >= amountCents)
        .take(3)
        .toList();

    return BottomActionSheet(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(child: FieldLabel('Cobrar al cliente')),
          const SizedBox(height: Insets.md),
          Center(
            child: Text(
              amountCents.formatDOP,
              style: text.displaySmall?.copyWith(color: BrandColors.red),
            ),
          ),
          const SizedBox(height: Insets.xl),
          if (usefulBills.isNotEmpty) ...[
            const FieldLabel('Devuelta'),
            const SizedBox(height: Insets.sm),
            for (final bill in usefulBills)
              DetailRow(
                label: 'Si paga con ${bill.formatDOPCompact}',
                value: (bill - amountCents).formatDOP,
              ),
            const SizedBox(height: Insets.lg),
          ],
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('RECIBÍ EL EFECTIVO'),
          ),
          const SizedBox(height: Insets.sm),
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Todavía no'),
          ),
        ],
      ),
    );
  }
}
