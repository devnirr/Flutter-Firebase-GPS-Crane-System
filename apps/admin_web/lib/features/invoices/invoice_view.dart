import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

import '../shared/toast.dart';
import 'file_saver.dart';
import 'invoice_printer.dart';

/// A monthly invoice on screen: the same document the company prints, with
/// the office's or the company's actions above it.
class InsurerInvoiceView extends ConsumerWidget {
  const InsurerInvoiceView({
    required this.invoice,
    this.actions = const [],
    this.onBack,
    super.key,
  });

  final InsurerInvoice invoice;
  final List<Widget> actions;
  final VoidCallback? onBack;

  void _print(BuildContext context, WidgetRef ref) {
    final opened = ref.read(invoicePrinterProvider).open(invoice);
    if (opened) return;
    showToast(
      context,
      'No se pudo abrir la factura. Permite las ventanas emergentes para este sitio.',
      tone: ToastTone.error,
    );
  }

  void _export(BuildContext context, WidgetRef ref) {
    final name = InvoiceWorkbook.fileName(invoice);
    final saved = ref.read(fileSaverProvider).save(
          InvoiceWorkbook.invoice(invoice),
          fileName: name,
          mimeType: xlsxMimeType,
        );
    showToast(
      context,
      saved ? 'Se descargó $name.' : 'No se pudo descargar el archivo de Excel.',
      tone: saved ? ToastTone.success : ToastTone.error,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final i = invoice;
    final now = DateTime.now().toUtc();

    return ListView(
      padding: const EdgeInsets.all(Insets.xl),
      children: [
        Row(
          children: [
            if (onBack != null) ...[
              IconButton(
                tooltip: 'Volver',
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back),
              ),
              const SizedBox(width: Insets.sm),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          'Factura ${i.ncf}',
                          key: const Key('invoice-title'),
                          style: text.headlineSmall,
                        ),
                      ),
                      const SizedBox(width: Insets.sm),
                      if (i.isTestNcf) const NcfTestChip(),
                    ],
                  ),
                  Text(
                    '${i.insurerName} · ${InvoicePeriod.isKey(i.periodKey) ? InvoicePeriod.parse(i.periodKey).title : i.periodKey}',
                    style: text.bodyMedium?.copyWith(
                      color: palette.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            InvoiceStatusChip(invoice: i, now: now),
          ],
        ),
        const SizedBox(height: Insets.md),
        // A wrap, not a row: four buttons do not fit beside the title on the
        // narrowest screen the panel allows.
        Align(
          alignment: Alignment.centerRight,
          child: Wrap(
            spacing: Insets.sm,
            runSpacing: Insets.sm,
            alignment: WrapAlignment.end,
            children: [
              OutlinedButton.icon(
                key: const Key('print-invoice'),
                onPressed: () => _print(context, ref),
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                icon: const Icon(Icons.print_outlined),
                label: const Text('Imprimir / PDF'),
              ),
              OutlinedButton.icon(
                key: const Key('export-invoice-excel'),
                onPressed: () => _export(context, ref),
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                icon: const Icon(Icons.table_view_outlined),
                label: const Text('Exportar Excel'),
              ),
              ...actions,
            ],
          ),
        ),
        if (i.isTestNcf) ...[
          const SizedBox(height: Insets.lg),
          const InlineNotice(
            key: Key('invoice-test-notice'),
            message:
                'Comprobante de prueba: este NCF no tiene valor fiscal. La '
                'factura sirve para revisar y cobrar mientras la DGII autoriza '
                'la secuencia real.',
          ),
        ],
        if (i.isVoided) ...[
          const SizedBox(height: Insets.lg),
          InlineNotice(
            tone: NoticeTone.error,
            message:
                'Anulada${i.voidedAt == null ? '' : ' el ${DoTime.fullDate(i.voidedAt!)}'}'
                '${i.voidReason.isEmpty ? '' : ': ${i.voidReason}'}. Sus servicios '
                'pasaron a la siguiente factura.',
          ),
        ],
        if (i.isPaid) ...[
          const SizedBox(height: Insets.lg),
          InlineNotice(
            tone: NoticeTone.success,
            message:
                'Cobrada${i.paidAt == null ? '' : ' el ${DoTime.fullDate(i.paidAt!)}'}'
                '${i.paymentReference.isEmpty ? '' : ' · Ref. ${i.paymentReference}'}.',
          ),
        ],
        const SizedBox(height: Insets.lg),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _Box(
                title: 'Emisor',
                rows: [
                  (i.issuer.name, true),
                  ('RNC: ${i.issuer.rncLabel}', false),
                  if (i.issuer.address.isNotEmpty) (i.issuer.address, false),
                  if (i.issuer.phone.isNotEmpty || i.issuer.email.isNotEmpty)
                    (
                      [
                        i.issuer.phone,
                        i.issuer.email,
                      ].where((p) => p.isNotEmpty).join(' · '),
                      false,
                    ),
                ],
              ),
            ),
            const SizedBox(width: Insets.lg),
            Expanded(
              child: _Box(
                title: 'Cliente',
                rows: [
                  (i.insurerName, true),
                  ('RNC: ${formatRnc(i.insurerRnc)}', false),
                  if (i.billingEmail.isNotEmpty) (i.billingEmail, false),
                ],
              ),
            ),
            const SizedBox(width: Insets.lg),
            Expanded(
              child: _Box(
                title: 'Comprobante',
                rows: [
                  ('NCF ${i.ncf} · ${i.ncfType.label}', true),
                  (
                    i.isTestNcf
                        ? 'Válido hasta: N/A (prueba)'
                        : 'Válido hasta: ${InvoiceDocument.isoDay(i.ncfExpiresOn)}',
                    false,
                  ),
                  (
                    'Emitida: ${InvoiceDocument.day(i.issuedAt ?? i.createdAt)}',
                    false,
                  ),
                  (
                    'Vence: ${InvoiceDocument.day(i.dueAt)}'
                        ' (${i.paymentTermsDays == 0 ? 'contado' : '${i.paymentTermsDays} días'})',
                    false,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: Insets.lg),
        FloatingCard(
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(Insets.lg),
                child: Text(
                  '${i.lines.length} línea(s) · ${i.towCount} servicio(s) de grúa'
                  ' · ${i.cancellationCount} cargo(s) por cancelación',
                  style: text.titleSmall,
                ),
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  key: const Key('invoice-lines'),
                  headingRowHeight: 40,
                  dataRowMinHeight: 44,
                  dataRowMaxHeight: 64,
                  columnSpacing: Insets.lg,
                  columns: const [
                    DataColumn(label: Text('Fecha')),
                    DataColumn(label: Text('Código')),
                    DataColumn(label: Text('Siniestro')),
                    DataColumn(label: Text('Asegurado')),
                    DataColumn(label: Text('Vehículo')),
                    DataColumn(label: Text('Descripción')),
                    DataColumn(label: Text('Monto'), numeric: true),
                  ],
                  rows: [
                    for (final line in i.lines)
                      DataRow(
                        key: ValueKey('invoice-line-${line.serviceId}'),
                        cells: [
                          DataCell(Text(InvoiceDocument.day(line.finishedAt))),
                          DataCell(Text(line.serviceCode)),
                          DataCell(Text(line.claimNumber)),
                          DataCell(Text(line.insuredName)),
                          DataCell(
                            Text(
                              [
                                line.plate,
                                line.vehicle,
                              ].where((p) => p.isNotEmpty).join(' · '),
                            ),
                          ),
                          DataCell(Text(line.description)),
                          DataCell(Text(line.amountCents.formatDOP)),
                        ],
                      ),
                  ],
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
                  width: 320,
                  child: Padding(
                    padding: const EdgeInsets.all(Insets.lg),
                    child: Column(
                      children: [
                        DetailRow(
                          label: 'Subtotal',
                          value: i.subtotalCents.formatDOP,
                        ),
                        DetailRow(
                          label: 'ITBIS 18%',
                          value: i.itbisCents.formatDOP,
                        ),
                        const Divider(),
                        DetailRow(
                          key: const Key('invoice-total'),
                          label: 'Total',
                          value: i.totalCents.formatDOP,
                          emphasise: true,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Box extends StatelessWidget {
  const _Box({required this.title, required this.rows});

  final String title;
  final List<(String, bool)> rows;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    return FloatingCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FieldLabel(title.toUpperCase()),
          const SizedBox(height: Insets.xs),
          for (final (value, strong) in rows)
            Text(
              value,
              style: strong
                  ? text.titleSmall
                  : text.bodySmall?.copyWith(color: palette.textMuted),
            ),
        ],
      ),
    );
  }
}

/// "PRUEBA": the NCF has no fiscal value.
class NcfTestChip extends StatelessWidget {
  const NcfTestChip({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Insets.sm, vertical: 2),
      decoration: BoxDecoration(
        color: palette.warningTint,
        borderRadius: Corners.brSm,
      ),
      child: Text(
        'NCF DE PRUEBA',
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: palette.warning),
      ),
    );
  }
}

/// Por cobrar, Vencida, Cobrada or Anulada.
class InvoiceStatusChip extends StatelessWidget {
  const InvoiceStatusChip({
    required this.invoice,
    required this.now,
    super.key,
  });

  final InsurerInvoice invoice;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final overdue = invoice.isOverdueAt(now);
    final (label, fg, bg) = switch (invoice.status) {
      InsurerInvoiceStatus.issued when overdue => (
        'Vencida',
        palette.danger,
        palette.dangerTint,
      ),
      InsurerInvoiceStatus.issued => (
        'Por cobrar',
        palette.warning,
        palette.warningTint,
      ),
      InsurerInvoiceStatus.paid => (
        'Cobrada',
        palette.success,
        palette.successTint,
      ),
      InsurerInvoiceStatus.voided => (
        'Anulada',
        palette.textMuted,
        palette.surfaceSubtle,
      ),
      InsurerInvoiceStatus.unknown => (
        'Desconocido',
        palette.textMuted,
        palette.surfaceSubtle,
      ),
    };
    return Container(
      key: Key('invoice-status-${invoice.id}'),
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.md,
        vertical: Insets.xs,
      ),
      decoration: BoxDecoration(color: bg, borderRadius: Corners.brSm),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg),
      ),
    );
  }
}
