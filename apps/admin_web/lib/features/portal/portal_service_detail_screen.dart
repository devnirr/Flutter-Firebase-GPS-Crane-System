import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';
import '../shared/toast.dart';

/// One tow, as the company that ordered it sees it: the claim, where the grúa
/// is, what it will cost, and — while nobody is towing yet — a way to cancel.
///
/// Nothing here says what the chofer is paid; the company's price is the
/// only number it is shown.
class PortalServiceDetailScreen extends ConsumerWidget {
  const PortalServiceDetailScreen({required this.serviceId, super.key});

  final String serviceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(serviceByIdProvider(serviceId));
    final insurerId = ref.watch(currentInsurerIdProvider).value;

    return switch (service) {
      // A tow of another company is refused by the rules; say "not found"
      // either way rather than hint that it exists.
      AsyncValue(:final value?) when value.insurerId == insurerId =>
        _Detail(service: value),
      AsyncValue(isLoading: true) => const Center(child: CircularProgressIndicator()),
      _ => EmptyState(
          key: const Key('portal-service-missing'),
          title: 'Servicio no encontrado',
          message: 'Ese servicio no existe o no es de tu aseguradora.',
          icon: Icons.search_off,
          actionLabel: 'Ver mis servicios',
          onAction: () => context.go(Routes.portalServices),
        ),
    };
  }
}

class _Detail extends ConsumerWidget {
  const _Detail({required this.service});

  final Service service;

  Future<void> _cancel(BuildContext context, WidgetRef ref) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => _CancelDialog(service: service),
    );
    if (reason == null || !context.mounted) return;
    final result = await ref
        .read(functionsGatewayProvider)
        .cancelService(serviceId: service.id, reason: reason);
    if (!context.mounted) return;
    showToast(
      context,
      switch (result) {
        Ok() => 'Servicio cancelado.',
        Err(:final failure) => failure.userMessage,
      },
      tone: result.isOk ? ToastTone.success : ToastTone.error,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final s = service;
    final claim = s.insurance ?? const InsuranceClaim();
    final tracking = s.isActive && s.hasDriver
        ? ref.watch(serviceTrackingProvider(s.id)).value
        : null;
    final truckAt = tracking != null &&
            (tracking.position.latitude != 0 || tracking.position.longitude != 0)
        ? tracking.position
        : null;
    final member = ref.watch(myInsurerMemberProvider).value;
    final canCancel = s.isCancellableByClient && (member?.active ?? false);

    return ListView(
      padding: const EdgeInsets.all(Insets.xl),
      children: [
        Row(
          children: [
            IconButton(
              tooltip: 'Volver a servicios',
              onPressed: () => context.go(Routes.portalServices),
              icon: const Icon(Icons.arrow_back),
            ),
            const SizedBox(width: Insets.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    claim.claimNumber.isEmpty
                        ? s.code
                        : 'Siniestro ${claim.claimNumber}',
                    key: const Key('portal-detail-title'),
                    style: text.headlineSmall,
                  ),
                  Text(
                    [
                      s.code,
                      if (s.createdAt ?? s.timeline.createdAt case final at?)
                        'pedido ${DoTime.dateAndTime(at)}',
                    ].join(' · '),
                    style: text.bodyMedium?.copyWith(color: palette.textMuted),
                  ),
                ],
              ),
            ),
            StatusChip(s.status, label: s.status.officeLabel),
            if (canCancel) ...[
              const SizedBox(width: Insets.md),
              OutlinedButton.icon(
                key: const Key('portal-cancel-service'),
                onPressed: () => _cancel(context, ref),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 44),
                  foregroundColor: palette.danger,
                ),
                icon: const Icon(Icons.close),
                label: const Text('Cancelar servicio'),
              ),
            ],
          ],
        ),
        const SizedBox(height: Insets.xl),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (s.isActive || s.dropoff != null)
                    SizedBox(
                      height: 320,
                      child: ClipRRect(
                        borderRadius: Corners.brMd,
                        child: GruaMap(
                          center: s.pickup.geo,
                          hasApiKey: ref.watch(hasMapsKeyProvider),
                          fitTo: [
                            s.pickup.geo,
                            if (s.dropoff != null) s.dropoff!.geo,
                            ?truckAt,
                          ],
                          route: s.route.path,
                          expandable: true,
                          markers: [
                            MapMarker(
                              id: 'pickup',
                              position: s.pickup.geo,
                              kind: MapMarkerKind.pickup,
                            ),
                            if (s.dropoff != null)
                              MapMarker(
                                id: 'dropoff',
                                position: s.dropoff!.geo,
                                kind: MapMarkerKind.dropoff,
                              ),
                            if (truckAt != null)
                              MapMarker(
                                id: 'truck',
                                position: truckAt,
                                heading: tracking!.heading,
                                kind: MapMarkerKind.truckOnService,
                                label: s.truckPlate.isEmpty ? null : s.truckPlate,
                              ),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: Insets.lg),
                  _Card(
                    title: 'Recorrido',
                    children: [
                      RouteSummary(
                        pickup: s.pickup.fullDescription,
                        dropoff: s.dropoff?.fullDescription,
                      ),
                      if (tracking != null && tracking.etaSeconds > 0) ...[
                        const SizedBox(height: Insets.md),
                        InlineNotice(
                          tone: NoticeTone.info,
                          message: s.status == ServiceStatus.inProgress
                              ? 'Llega al destino en ${tracking.etaLabel}.'
                              : 'La grúa llega en ${tracking.etaLabel}.',
                        ),
                      ],
                      if (s.driverNotes.isNotEmpty)
                        DetailRow(label: 'Notas para el chofer', value: s.driverNotes),
                    ],
                  ),
                  const SizedBox(height: Insets.lg),
                  _Card(
                    title: 'Grúa',
                    children: s.hasDriver
                        ? [
                            DetailRow(
                              label: 'Chofer',
                              value: s.driverName.isEmpty ? '—' : s.driverName,
                            ),
                            if (s.driverPhone.isNotEmpty && s.isActive)
                              DetailRow(label: 'Teléfono', value: s.driverPhone),
                            DetailRow(
                              label: 'Grúa',
                              value: [
                                if (s.truckLabel.isNotEmpty) s.truckLabel,
                                if (s.truckPlate.isNotEmpty) s.truckPlate,
                              ].join(' · ').ifEmpty('—'),
                            ),
                          ]
                        : [
                            Text(
                              s.isActive
                                  ? 'Buscando la grúa más cercana…'
                                  : 'No se asignó ninguna grúa.',
                              style: text.bodyMedium?.copyWith(
                                color: palette.textMuted,
                              ),
                            ),
                          ],
                  ),
                  const SizedBox(height: Insets.lg),
                  _Card(
                    title: 'Tiempos',
                    children: [
                      for (final (label, at) in [
                        ('Pedido', s.timeline.createdAt ?? s.createdAt),
                        ('Grúa asignada', s.timeline.acceptedAt),
                        ('Grúa en el punto', s.timeline.arrivedAt),
                        ('Remolque iniciado', s.timeline.startedAt),
                        ('Entregado', s.timeline.completedAt),
                        ('Cancelado', s.timeline.cancelledAt),
                      ])
                        if (at != null)
                          DetailRow(label: label, value: DoTime.dateAndTime(at)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: Insets.xl),
            Expanded(
              flex: 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Card(
                    title: 'Siniestro',
                    children: [
                      DetailRow(
                        label: 'Número de siniestro',
                        value: claim.claimNumber.ifEmpty('—'),
                      ),
                      DetailRow(
                        label: 'Póliza',
                        value: claim.policyNumber.ifEmpty('—'),
                      ),
                      DetailRow(
                        label: 'Asegurado',
                        value: claim.insuredName.ifEmpty('—'),
                      ),
                      DetailRow(
                        label: 'Teléfono',
                        value: claim.insuredPhone.ifEmpty('—'),
                      ),
                    ],
                  ),
                  const SizedBox(height: Insets.lg),
                  _Card(
                    title: 'Vehículo',
                    children: [
                      DetailRow(label: 'Tipo', value: s.vehicle.type.label),
                      DetailRow(label: 'Placa', value: s.vehicle.plate.ifEmpty('—')),
                      DetailRow(
                        label: 'Marca y modelo',
                        value: [s.vehicle.make, s.vehicle.model]
                            .where((p) => p.isNotEmpty)
                            .join(' ')
                            .ifEmpty('—'),
                      ),
                      DetailRow(label: 'Color', value: s.vehicle.color.ifEmpty('—')),
                    ],
                  ),
                  const SizedBox(height: Insets.lg),
                  _PriceCard(service: s),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return FloatingCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Insets.sm),
          ...children,
        ],
      ),
    );
  }
}

class _PriceCard extends StatelessWidget {
  const _PriceCard({required this.service});

  final Service service;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final s = service;
    final billing = s.billing;
    final cancelled = s.status == ServiceStatus.cancelled ||
        s.status == ServiceStatus.expired ||
        s.status == ServiceStatus.failed;
    final fee = s.cancellation?.feeCents ?? 0;
    final subtotal = cancelled ? fee : (billing?.subtotalCents ?? s.quote.subtotalCents);
    final totals = ZonePricing.withItbis(subtotal);

    return _Card(
      title: 'Precio',
      children: [
        if (cancelled)
          DetailRow(
            label: 'Cargo por cancelación',
            value: fee > 0 ? fee.formatDOP : 'Sin cargo',
          )
        else if (billing != null) ...[
          DetailRow(
            label: 'Zona',
            value: '${billing.zoneLabel} · ${billing.vehicleClass.label}',
          ),
          DetailRow(
            label: 'Distancia',
            value: '${billing.distanceKm.toStringAsFixed(1)} km',
          ),
          DetailRow(label: 'Tarifa de la zona', value: billing.baseCents.formatDOP),
          if (billing.extraCents > 0)
            DetailRow(
              label: 'Km adicionales (${billing.extraKm.toStringAsFixed(1)} km)',
              value: billing.extraCents.formatDOP,
            ),
        ],
        if (!cancelled || fee > 0) ...[
          const Divider(),
          DetailRow(label: 'Subtotal', value: totals.subtotalCents.formatDOP),
          DetailRow(label: 'ITBIS 18%', value: totals.itbisCents.formatDOP),
          DetailRow(
            key: const Key('portal-detail-total'),
            label: 'Total',
            value: totals.totalCents.formatDOP,
            emphasise: true,
          ),
        ],
        const SizedBox(height: Insets.xs),
        Text(
          switch (s.status) {
            ServiceStatus.completed ||
            ServiceStatus.closed =>
              'Incluido en la factura del mes.',
            _ when cancelled && fee > 0 => 'El cargo se incluye en la factura del mes.',
            _ when cancelled => 'No se factura.',
            _ => 'Se factura al terminar el servicio.',
          },
          style: text.bodySmall?.copyWith(color: palette.textMuted),
        ),
      ],
    );
  }
}

class _CancelDialog extends StatefulWidget {
  const _CancelDialog({required this.service});

  final Service service;

  @override
  State<_CancelDialog> createState() => _CancelDialogState();
}

class _CancelDialogState extends State<_CancelDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final onTheWay = widget.service.status == ServiceStatus.accepted ||
        widget.service.status == ServiceStatus.arrived;
    return AlertDialog(
      title: const Text('¿Cancelar este servicio?'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              onTheWay
                  ? 'La grúa ya va en camino. Si lleva varios minutos, la '
                      'cancelación puede tener un cargo que se suma a tu factura.'
                  : 'Todavía no hay grúa asignada. Cancelar ahora no tiene cargo.',
            ),
            const SizedBox(height: Insets.lg),
            TextField(
              key: const Key('portal-cancel-reason'),
              controller: _reason,
              maxLength: 300,
              decoration: const InputDecoration(
                labelText: 'Motivo',
                hintText: 'El asegurado resolvió por su cuenta…',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Volver'),
        ),
        ElevatedButton(
          key: const Key('portal-confirm-cancel'),
          onPressed: () => Navigator.of(context).pop(
            _reason.text.trim().isEmpty ? 'insurer_request' : _reason.text.trim(),
          ),
          style: ElevatedButton.styleFrom(
            minimumSize: const Size(0, 40),
            backgroundColor: context.palette.danger,
          ),
          child: const Text('Cancelar servicio'),
        ),
      ],
    );
  }
}
