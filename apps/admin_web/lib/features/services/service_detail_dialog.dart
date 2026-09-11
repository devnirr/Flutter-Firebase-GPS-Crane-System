import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';

/// Everything on file for one service, read-only.
///
/// Watches the service rather than showing the row it was opened from, so a
/// job still in progress keeps moving while the office reads it. [service] is
/// what is shown until the live copy arrives.
Future<void> showServiceDetailDialog(BuildContext context, Service service) =>
    showDialog<void>(
      context: context,
      builder: (context) => ServiceDetailDialog(service: service),
    );

class ServiceDetailDialog extends ConsumerWidget {
  const ServiceDetailDialog({required this.service, super.key});

  final Service service;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(serviceByIdProvider(service.id)).value ?? service;
    final events = ref.watch(serviceEventsProvider(s.id)).value ?? const [];
    final text = Theme.of(context).textTheme;

    String orDash(String value) => value.trim().isEmpty ? '—' : value;
    String when(DateTime? at) => at == null ? '—' : DoTime.dateAndTime(at);

    final quote = s.effectiveQuote;
    final timeline = s.timeline;
    final cancellation = s.cancellation;
    final rating = s.ratings.clientToDriver;

    return Dialog(
      backgroundColor: BrandColors.white,
      shape: const RoundedRectangleBorder(borderRadius: Corners.brMd),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 640,
          maxHeight: MediaQuery.sizeOf(context).height * 0.9,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Insets.xxl,
                Insets.xl,
                Insets.lg,
                Insets.lg,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                s.code.isEmpty ? 'Servicio' : s.code,
                                style: text.titleLarge,
                              ),
                            ),
                            const SizedBox(width: Insets.md),
                            StatusChip(s.status, label: s.status.officeLabel),
                          ],
                        ),
                        const SizedBox(height: Insets.xxs),
                        Text(
                          'Solicitado ${when(s.createdAt ?? timeline.createdAt)}',
                          style: text.bodySmall
                              ?.copyWith(color: BrandColors.grey600),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 20),
                    tooltip: 'Cerrar',
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: BrandColors.grey200),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  Insets.xxl,
                  Insets.lg,
                  Insets.xxl,
                  Insets.lg,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (s.status == ServiceStatus.needsManual) ...[
                      const InlineNotice(
                        message: 'La búsqueda automática no encontró chofer. '
                            'Asígnalo desde Operaciones.',
                        tone: NoticeTone.error,
                      ),
                      const SizedBox(height: Insets.lg),
                    ],
                    RouteSummary(
                      pickup: s.pickup.displayAddress,
                      pickupReference: s.pickup.reference,
                      dropoff: s.dropoff?.displayAddress,
                    ),
                    const SizedBox(height: Insets.lg),
                    _Section('Cliente', [
                      ('Nombre', orDash(s.clientName)),
                      ('Teléfono', orDash(s.clientPhone)),
                    ]),
                    _Section('Vehículo', [
                      ('Vehículo', s.vehicle.displayName),
                      ('Placa', orDash(s.vehicle.plate)),
                      ('Problema', s.vehicle.condition.label),
                      if (s.vehicle.notes.isNotEmpty) ('Notas', s.vehicle.notes),
                      ('Grúa requerida', s.truckTypeRequired.label),
                    ]),
                    _Section('Chofer', [
                      if (s.hasDriver) ...[
                        ('Nombre', orDash(s.driverName)),
                        ('Teléfono', orDash(s.driverPhone)),
                        (
                          'Grúa',
                          [s.truckPlate, s.truckLabel]
                                  .where((p) => p.isNotEmpty)
                                  .join(' · ')
                                  .ifEmpty('—'),
                        ),
                        ('Asignación', s.assignmentMode.label),
                      ] else
                        ('Nombre', 'Sin asignar'),
                    ]),
                    _Section('Recorrido', [
                      ('Distancia', s.route.distanceLabel),
                      ('Duración estimada', s.route.durationLabel),
                    ]),
                    _Section(s.finalQuote == null ? 'Precio estimado' : 'Precio final', [
                      for (final line in quote.breakdown)
                        (line.label, line.cents.formatDOP),
                      ('Total', quote.totalCents.formatDOP),
                    ]),
                    _Section('Pago', [
                      (
                        'Método',
                        s.payment.isCard ? s.payment.cardLabel : s.payment.method.label,
                      ),
                      ('Estado', s.payment.status.label),
                      if (s.payment.capturedCents > 0)
                        ('Cobrado', s.payment.capturedCents.formatDOP),
                      if (s.payment.refundedCents > 0)
                        ('Reembolsado', s.payment.refundedCents.formatDOP),
                      if (s.payment.failureMessage.isNotEmpty)
                        ('Error', s.payment.failureMessage),
                    ]),
                    _Section('Tiempos', [
                      ('Solicitado', when(timeline.createdAt ?? s.createdAt)),
                      if (timeline.acceptedAt != null)
                        ('Aceptado', when(timeline.acceptedAt)),
                      if (timeline.arrivedAt != null)
                        ('Llegó al punto', when(timeline.arrivedAt)),
                      if (timeline.startedAt != null)
                        ('Inició el remolque', when(timeline.startedAt)),
                      if (timeline.completedAt != null)
                        ('Completado', when(timeline.completedAt)),
                      if (timeline.closedAt != null)
                        ('Cerrado', when(timeline.closedAt)),
                      if (timeline.cancelledAt != null)
                        ('Cancelado', when(timeline.cancelledAt)),
                      if (timeline.timeToAccept != null)
                        ('Espera por chofer', DoTime.duration(timeline.timeToAccept!)),
                      if (timeline.timeToArrive != null)
                        ('Tiempo de llegada', DoTime.duration(timeline.timeToArrive!)),
                      if (timeline.serviceDuration != null)
                        ('Duración del remolque', DoTime.duration(timeline.serviceDuration!)),
                    ]),
                    if (cancellation != null)
                      _Section('Cancelación', [
                        ('Por', cancellation.by.label),
                        ('Motivo', orDash(cancellation.reason)),
                        if (cancellation.hasFee)
                          ('Cargo', cancellation.feeCents.formatDOP),
                      ]),
                    if (rating != null && rating.isRated)
                      _Section('Calificación del cliente', [
                        ('Estrellas', '${rating.stars} de 5'),
                        if (rating.comment.isNotEmpty) ('Comentario', rating.comment),
                      ]),
                    if (events.isNotEmpty) _History(events: events),
                  ],
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.all(Insets.lg),
              decoration: const BoxDecoration(
                color: BrandColors.offWhite,
                border: Border(top: BorderSide(color: BrandColors.grey200)),
                borderRadius:
                    BorderRadius.vertical(bottom: Radius.circular(Corners.md)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  // Where a live job is acted on: the map, the chofer's
                  // position and the manual assignment all live there.
                  if (s.isActive) ...[
                    OutlinedButton.icon(
                      onPressed: () {
                        Navigator.of(context).pop();
                        context.go(Routes.operationsFor(s.id));
                      },
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 40),
                        padding:
                            const EdgeInsets.symmetric(horizontal: Insets.lg),
                      ),
                      icon: const Icon(Icons.map_outlined, size: 18),
                      label: const Text('Ver en Operaciones'),
                    ),
                    const SizedBox(width: Insets.sm),
                  ],
                  ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(0, 40),
                      padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
                    ),
                    child: const Text('Cerrar'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

/// A titled group of label / value rows.
class _Section extends StatelessWidget {
  const _Section(this.title, this.rows);

  final String title;
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              FieldLabel(title.toUpperCase()),
              const SizedBox(width: Insets.sm),
              const Expanded(child: Divider(color: BrandColors.grey200)),
            ],
          ),
          const SizedBox(height: Insets.xs),
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Insets.xxs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 190,
                    child: Text(
                      label,
                      style: text.bodyMedium
                          ?.copyWith(color: BrandColors.grey600),
                    ),
                  ),
                  Expanded(child: Text(value, style: text.bodyMedium)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The transition log, oldest first: who moved the job, and when.
class _History extends StatelessWidget {
  const _History({required this.events});

  final List<ServiceEvent> events;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            FieldLabel('HISTORIAL'),
            SizedBox(width: Insets.sm),
            Expanded(child: Divider(color: BrandColors.grey200)),
          ],
        ),
        const SizedBox(height: Insets.sm),
        for (final event in events)
          Padding(
            padding: const EdgeInsets.only(bottom: Insets.sm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Icon(Icons.circle, size: 7, color: BrandColors.red),
                ),
                const SizedBox(width: Insets.sm),
                Expanded(child: Text(event.description, style: text.bodyMedium)),
                if (event.at != null)
                  Text(
                    DoTime.dateAndTime(event.at!),
                    style: text.bodySmall?.copyWith(color: BrandColors.grey600),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
