import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';
import '../shared/toast.dart';
import 'file_saver.dart';
import 'invoice_view.dart';

/// Facturación: the monthly invoices to insurance companies.
///
/// Made by themselves on the 1st at 6:00 for the month before; here the
/// office sees what is owed, makes one early, records a transfer, or voids a
/// wrong one. Only an admin acts; a dispatcher reads.
class InvoicesScreen extends ConsumerStatefulWidget {
  const InvoicesScreen({super.key});

  @override
  ConsumerState<InvoicesScreen> createState() => _InvoicesScreenState();
}

enum _Filter {
  all('Todas'),
  issued('Por cobrar'),
  overdue('Vencidas'),
  paid('Cobradas'),
  voided('Anuladas');

  const _Filter(this.label);
  final String label;

  bool matches(InsurerInvoice i, DateTime now) => switch (this) {
        _Filter.all => true,
        _Filter.issued => i.isIssued,
        _Filter.overdue => i.isOverdueAt(now),
        _Filter.paid => i.isPaid,
        _Filter.voided => i.isVoided,
      };
}

class _InvoicesScreenState extends ConsumerState<InvoicesScreen> {
  _Filter _filter = _Filter.all;
  String _insurerId = '';

  void _export(List<InsurerInvoice> shown, List<Insurer> insurers) {
    final now = DateTime.now().toUtc();
    final company = insurers.where((i) => i.id == _insurerId).firstOrNull?.name;
    final name = InvoiceWorkbook.listFileName(now);
    final saved = ref.read(fileSaverProvider).save(
          InvoiceWorkbook.list(
            shown,
            subtitle: [
              if (_filter != _Filter.all) _filter.label,
              ?company,
            ].join(' · '),
            now: now,
          ),
          fileName: name,
          mimeType: xlsxMimeType,
        );
    showToast(
      context,
      saved
          ? 'Se descargó $name con ${shown.length} factura(s).'
          : 'No se pudo descargar el archivo de Excel.',
      tone: saved ? ToastTone.success : ToastTone.error,
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final isAdmin = ref.watch(currentRoleProvider).value == UserRole.admin;
    final invoicesAsync = ref.watch(insurerInvoicesProvider(''));
    final invoices = invoicesAsync.value ?? const <InsurerInvoice>[];
    final toInvoice = ref.watch(servicesToInvoiceProvider).value ?? const <Service>[];
    final insurers = ref.watch(allInsurersProvider).value ?? const <Insurer>[];
    final sequence = ref.watch(creditNcfSequenceProvider).value;
    final now = DateTime.now().toUtc();

    final issued = invoices.where((i) => i.isIssued).toList();
    final overdue = invoices.where((i) => i.isOverdueAt(now)).toList();
    int sum(Iterable<InsurerInvoice> list) => list.fold(0, (s, i) => s + i.totalCents);
    final waitingCents = toInvoice.fold<int>(0, (s, x) => s + (_billable(x) ?? 0));

    final shown = [
      for (final i in invoices)
        if (_filter.matches(i, now) && (_insurerId.isEmpty || i.insurerId == _insurerId)) i,
    ];

    return ListView(
      padding: const EdgeInsets.all(Insets.xl),
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Facturación a aseguradoras', style: text.headlineSmall),
                  const SizedBox(height: Insets.xs),
                  Text(
                    'El día 1 de cada mes a las 6:00 se factura a cada aseguradora '
                    'lo que terminó el mes anterior, con su NCF de crédito fiscal.',
                    style: text.bodyMedium?.copyWith(color: palette.textMuted),
                  ),
                ],
              ),
            ),
            OutlinedButton.icon(
              key: const Key('open-fiscal-settings'),
              onPressed: () => context.go(Routes.fiscalSettings),
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
              icon: const Icon(Icons.pin_outlined),
              label: const Text('Comprobantes (NCF)'),
            ),
            if (isAdmin) ...[
              const SizedBox(width: Insets.sm),
              ElevatedButton.icon(
                key: const Key('generate-invoices'),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const GenerateInvoicesDialog(),
                ),
                style: ElevatedButton.styleFrom(minimumSize: const Size(0, 44)),
                icon: const Icon(Icons.request_quote_outlined),
                label: const Text('Generar facturas'),
              ),
            ],
          ],
        ),
        if (sequence != null) ...[
          const SizedBox(height: Insets.lg),
          NcfSequenceNotice(sequence: sequence, now: now),
        ],
        const SizedBox(height: Insets.xl),
        Wrap(
          spacing: Insets.lg,
          runSpacing: Insets.lg,
          children: [
            _Kpi(
              key: const Key('kpi-receivable'),
              label: 'Por cobrar',
              value: sum(issued).formatDOP,
              detail: '${issued.length} factura(s)',
            ),
            _Kpi(
              key: const Key('kpi-overdue'),
              label: 'Vencidas',
              value: sum(overdue).formatDOP,
              detail: '${overdue.length} factura(s)',
              color: overdue.isEmpty ? null : palette.danger,
            ),
            _Kpi(
              key: const Key('kpi-to-invoice'),
              label: 'Por facturar',
              value: ZonePricing.withItbis(waitingCents).totalCents.formatDOP,
              detail: '${toInvoice.length} servicio(s), ITBIS incluido',
            ),
            _Kpi(
              key: const Key('kpi-next-ncf'),
              label: 'Próximo NCF',
              value: sequence == null ? '—' : (Ncf.next(sequence) ?? '—'),
              detail: sequence == null
                  ? ''
                  : sequence.isTest
                      ? 'Secuencia de prueba'
                      : '${sequence.remaining} disponible(s)',
            ),
          ],
        ),
        if (toInvoice.isNotEmpty) ...[
          const SizedBox(height: Insets.xl),
          Text('Por facturar', style: text.titleMedium),
          const SizedBox(height: Insets.sm),
          FloatingCard(
            child: Column(
              children: [
                for (final group in _byCompany(toInvoice, insurers))
                  ListTile(
                    key: Key('to-invoice-${group.insurerId}'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.shield_outlined),
                    title: Text(group.name),
                    subtitle: Text(
                      '${group.count} servicio(s) terminados, desde el '
                      '${group.oldest == null ? '—' : DoTime.fullDate(group.oldest!)}',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '${group.subtotalCents.formatDOP} + ITBIS',
                          style: text.titleSmall,
                        ),
                        if (isAdmin) ...[
                          const SizedBox(width: Insets.md),
                          TextButton(
                            key: Key('invoice-now-${group.insurerId}'),
                            onPressed: () => showDialog<void>(
                              context: context,
                              builder: (_) =>
                                  GenerateInvoicesDialog(insurerId: group.insurerId),
                            ),
                            child: const Text('Facturar'),
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: Insets.xl),
        Row(
          children: [
            Expanded(
              child: Wrap(
                spacing: Insets.sm,
                runSpacing: Insets.sm,
                children: [
                  for (final f in _Filter.values)
                    ChoiceChip(
                      key: Key('invoice-filter-${f.name}'),
                      label: Text(f.label),
                      selected: _filter == f,
                      onSelected: (_) => setState(() => _filter = f),
                    ),
                ],
              ),
            ),
            OutlinedButton.icon(
              key: const Key('export-invoices-excel'),
              onPressed: shown.isEmpty ? null : () => _export(shown, insurers),
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
              icon: const Icon(Icons.table_view_outlined),
              label: const Text('Exportar Excel'),
            ),
            const SizedBox(width: Insets.md),
            SizedBox(
              width: 280,
              child: DropdownButtonFormField<String>(
                key: const Key('invoice-insurer-filter'),
                initialValue: _insurerId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Aseguradora'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('Todas')),
                  for (final insurer in insurers)
                    DropdownMenuItem(
                      value: insurer.id,
                      child: Text(insurer.name, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) => setState(() => _insurerId = v ?? ''),
              ),
            ),
          ],
        ),
        const SizedBox(height: Insets.md),
        FloatingCard(
          child: switch (invoicesAsync) {
            AsyncValue(:final error?) when !invoicesAsync.hasValue => Text(
                error is Failure ? error.userMessage : 'No pudimos cargar las facturas.',
                style: text.bodyMedium?.copyWith(color: palette.danger),
              ),
            _ when shown.isEmpty => Text(
                invoicesAsync.isLoading
                    ? 'Cargando…'
                    : invoices.isEmpty
                        ? 'Todavía no hay facturas.'
                        : 'Ninguna factura coincide con el filtro.',
                key: const Key('invoices-empty'),
                style: text.bodyMedium?.copyWith(color: palette.textMuted),
              ),
            _ => Column(
                children: [
                  for (final invoice in shown)
                    InvoiceTile(
                      invoice: invoice,
                      now: now,
                      onTap: () => context.go(Routes.invoiceFor(invoice.id)),
                    ),
                ],
              ),
          },
        ),
      ],
    );
  }
}

/// What a waiting service will add, before ITBIS, if it is billed.
int? _billable(Service s) {
  if (s.status == ServiceStatus.cancelled) {
    final fee = s.cancellation?.feeCents ?? 0;
    return fee > 0 ? fee : null;
  }
  return s.billing?.subtotalCents ?? s.quote.subtotalCents;
}

typedef _Group = ({
  String insurerId,
  String name,
  int count,
  int subtotalCents,
  DateTime? oldest,
});

List<_Group> _byCompany(List<Service> services, List<Insurer> insurers) {
  final names = {for (final i in insurers) i.id: i.name};
  final groups = <String, _Group>{};
  for (final s in services) {
    final at = s.status == ServiceStatus.cancelled
        ? s.timeline.cancelledAt
        : s.timeline.completedAt ?? s.timeline.closedAt;
    final g = groups[s.insurerId];
    final oldest = g?.oldest;
    groups[s.insurerId] = (
      insurerId: s.insurerId,
      name: names[s.insurerId] ?? (s.insurerName.isEmpty ? s.insurerId : s.insurerName),
      count: (g?.count ?? 0) + 1,
      subtotalCents: (g?.subtotalCents ?? 0) + (_billable(s) ?? 0),
      oldest: oldest == null || (at != null && at.isBefore(oldest)) ? at ?? oldest : oldest,
    );
  }
  return groups.values.toList()..sort((a, b) => a.name.compareTo(b.name));
}

class _Kpi extends StatelessWidget {
  const _Kpi({
    required this.label,
    required this.value,
    this.detail = '',
    this.color,
    super.key,
  });

  final String label;
  final String value;
  final String detail;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    return SizedBox(
      width: 250,
      child: FloatingCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FieldLabel(label),
            const SizedBox(height: Insets.xs),
            Text(value, style: text.headlineSmall?.copyWith(color: color)),
            if (detail.isNotEmpty)
              Text(detail, style: text.bodySmall?.copyWith(color: palette.textMuted)),
          ],
        ),
      ),
    );
  }
}

/// One invoice in a list.
class InvoiceTile extends StatelessWidget {
  const InvoiceTile({
    required this.invoice,
    required this.now,
    this.onTap,
    this.showCompany = true,
    super.key,
  });

  final InsurerInvoice invoice;
  final DateTime now;
  final VoidCallback? onTap;
  final bool showCompany;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final i = invoice;
    final period =
        InvoicePeriod.isKey(i.periodKey) ? InvoicePeriod.parse(i.periodKey).title : i.periodKey;
    return ListTile(
      key: Key('invoice-row-${i.id}'),
      contentPadding: EdgeInsets.zero,
      onTap: onTap,
      leading: const Icon(Icons.receipt_long_outlined),
      title: Row(
        children: [
          Flexible(
            child: Text(
              [i.ncf, if (showCompany) i.insurerName].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (i.isTestNcf) ...[
            const SizedBox(width: Insets.sm),
            const NcfTestChip(),
          ],
        ],
      ),
      subtitle: Text(
        [
          period,
          '${i.lines.length} servicio(s)',
          if (i.dueAt != null && i.isIssued) 'vence ${InvoiceDocument.day(i.dueAt)}',
          if (i.isPaid && i.paymentReference.isNotEmpty) 'Ref. ${i.paymentReference}',
        ].join(' · '),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(i.totalCents.formatDOP, style: text.titleSmall),
          const SizedBox(width: Insets.md),
          InvoiceStatusChip(invoice: i, now: now),
        ],
      ),
    );
  }
}

/// Test range in use, a real one running out, or one expiring.
class NcfSequenceNotice extends StatelessWidget {
  const NcfSequenceNotice({
    required this.sequence,
    required this.now,
    this.linkToSettings = true,
    super.key,
  });

  final NcfSequence sequence;
  final DateTime now;

  /// Off on the settings page itself, where the link would lead nowhere.
  final bool linkToSettings;

  @override
  Widget build(BuildContext context) {
    final problem = Ncf.problem(sequence, now);
    if (problem != null) {
      return InlineNotice(
        key: const Key('ncf-blocked'),
        tone: NoticeTone.error,
        message: problem,
        actionLabel: linkToSettings ? 'Registrar secuencia' : null,
        onAction: linkToSettings ? () => context.go(Routes.fiscalSettings) : null,
      );
    }
    if (sequence.isTest) {
      return InlineNotice(
        key: const Key('ncf-test-mode'),
        message: 'Modo prueba: las facturas salen con NCF de prueba '
            '(${Ncf.next(sequence) ?? ''} en adelante) y quedan marcadas como tales. '
            'Cuando la DGII autorice la secuencia real, regístrala en '
            'Comprobantes (NCF) y las siguientes facturas la usarán.',
        actionLabel: linkToSettings ? 'Comprobantes (NCF)' : null,
        onAction: linkToSettings ? () => context.go(Routes.fiscalSettings) : null,
      );
    }
    final expiresOn = sequence.expiresOn;
    final expiry = expiresOn == null ? null : Ncf.expiryInstant(expiresOn);
    final daysLeft = expiry?.difference(now).inDays;
    if (sequence.remaining <= 20 || (daysLeft != null && daysLeft <= 30)) {
      return InlineNotice(
        key: const Key('ncf-running-out'),
        message: [
          if (sequence.remaining <= 20)
            'Quedan ${sequence.remaining} NCF en la secuencia.',
          if (daysLeft != null && daysLeft <= 30)
            'La secuencia vence el ${InvoiceDocument.isoDay(expiresOn)}.',
          'Solicita la próxima a la DGII.',
        ].join(' '),
      );
    }
    return const SizedBox.shrink();
  }
}

/// Makes invoices now: for one month, and one company or every one.
class GenerateInvoicesDialog extends ConsumerStatefulWidget {
  const GenerateInvoicesDialog({this.insurerId, super.key});

  final String? insurerId;

  @override
  ConsumerState<GenerateInvoicesDialog> createState() => _GenerateInvoicesDialogState();
}

class _GenerateInvoicesDialogState extends ConsumerState<GenerateInvoicesDialog> {
  late final List<InvoicePeriod> _periods = InvoicePeriod.recent(DateTime.now().toUtc());
  late InvoicePeriod _period = _periods[1];
  late String _insurerId = widget.insurerId ?? '';
  var _busy = false;
  String? _error;

  Future<void> _generate() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await ref.read(functionsGatewayProvider).generateInsurerInvoices(
          insurerId: _insurerId.isEmpty ? null : _insurerId,
          periodKey: _period.key,
        );
    if (!mounted) return;
    switch (result) {
      case Ok(:final value):
        final toast = Toaster.of(context);
        Navigator.of(context).pop();
        final made = value.created.length;
        final test = value.created.any((c) => c.isTestNcf) ? ' con NCF de prueba' : '';
        toast.show(
          [
            if (made == 0)
              'No había servicios por facturar hasta ${_period.label}.'
            else if (made == 1)
              'Se emitió 1 factura$test (${value.created.single.ncf}) por ${value.totalCents.formatDOP}.'
            else
              'Se emitieron $made facturas$test por ${value.totalCents.formatDOP}.',
            if (value.failed.isNotEmpty)
              '${value.failed.length} aseguradora(s) sin facturar: ${value.failed.first.message}',
          ].join(' '),
          tone: value.failed.isNotEmpty
              ? ToastTone.warning
              : made == 0
                  ? ToastTone.info
                  : ToastTone.success,
        );
      case Err(:final failure):
        setState(() {
          _busy = false;
          _error = failure.userMessage;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final insurers = ref.watch(allInsurersProvider).value ?? const <Insurer>[];
    final palette = context.palette;
    final current = _periods.first;

    return AlertDialog(
      title: const Text('Generar facturas'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<InvoicePeriod>(
              key: const Key('invoice-period'),
              initialValue: _period,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Mes'),
              items: [
                for (final p in _periods)
                  DropdownMenuItem(
                    value: p,
                    child: Text(p == current ? '${p.title} (en curso)' : p.title),
                  ),
              ],
              onChanged: (p) => setState(() => _period = p ?? _period),
            ),
            const SizedBox(height: Insets.md),
            DropdownButtonFormField<String>(
              key: const Key('invoice-insurer'),
              initialValue: _insurerId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Aseguradora'),
              items: [
                const DropdownMenuItem(value: '', child: Text('Todas')),
                for (final insurer in insurers)
                  DropdownMenuItem(
                    value: insurer.id,
                    child: Text(insurer.name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) => setState(() => _insurerId = v ?? ''),
            ),
            const SizedBox(height: Insets.md),
            Text(
              _period == current
                  ? 'Se factura lo terminado hasta ahora. Lo que termine después '
                      'irá en la factura del próximo mes.'
                  : 'Se factura lo terminado hasta el final de ${_period.label} '
                      'que no esté facturado todavía, incluidos servicios de meses '
                      'anteriores que hayan quedado pendientes.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: palette.textMuted),
            ),
            if (_error != null) ...[
              const SizedBox(height: Insets.md),
              InlineNotice(
                key: const Key('generate-invoices-error'),
                tone: NoticeTone.error,
                message: _error!,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          key: const Key('confirm-generate-invoices'),
          onPressed: _busy ? null : _generate,
          style: ElevatedButton.styleFrom(minimumSize: const Size(0, 44)),
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: BrandColors.white,
                  ),
                )
              : const Text('Emitir facturas'),
        ),
      ],
    );
  }
}

/// One invoice, for the office: print it, record its payment, or void it.
class InvoiceDetailScreen extends ConsumerWidget {
  const InvoiceDetailScreen({required this.invoiceId, super.key});

  final String invoiceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final invoice = ref.watch(insurerInvoiceProvider(invoiceId));
    final isAdmin = ref.watch(currentRoleProvider).value == UserRole.admin;
    final palette = context.palette;

    return switch (invoice) {
      AsyncValue(:final value?) => InsurerInvoiceView(
          invoice: value,
          onBack: () => context.go(Routes.invoices),
          actions: [
            if (isAdmin && value.isIssued) ...[
              TextButton(
                key: const Key('void-invoice'),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => _InvoiceActionDialog(invoice: value, voiding: true),
                ),
                style: TextButton.styleFrom(foregroundColor: palette.danger),
                child: const Text('Anular'),
              ),
              ElevatedButton.icon(
                key: const Key('pay-invoice'),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => _InvoiceActionDialog(invoice: value, voiding: false),
                ),
                style: ElevatedButton.styleFrom(minimumSize: const Size(0, 44)),
                icon: const Icon(Icons.payments_outlined),
                label: const Text('Registrar cobro'),
              ),
            ],
          ],
        ),
      AsyncValue(isLoading: true) => const Center(child: CircularProgressIndicator()),
      _ => EmptyState(
          key: const Key('invoice-missing'),
          title: 'Factura no encontrada',
          message: 'Esa factura no existe.',
          icon: Icons.search_off,
          actionLabel: 'Ver facturas',
          onAction: () => context.go(Routes.invoices),
        ),
    };
  }
}

class _InvoiceActionDialog extends ConsumerStatefulWidget {
  const _InvoiceActionDialog({required this.invoice, required this.voiding});

  final InsurerInvoice invoice;
  final bool voiding;

  @override
  ConsumerState<_InvoiceActionDialog> createState() => _InvoiceActionDialogState();
}

class _InvoiceActionDialogState extends ConsumerState<_InvoiceActionDialog> {
  final _main = TextEditingController();
  final _note = TextEditingController();
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _main.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final value = _main.text.trim();
    if (value.length < 3) {
      setState(() => _error = widget.voiding
          ? 'Escribe por qué se anula la factura.'
          : 'Escribe el número de la transferencia.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final gateway = ref.read(functionsGatewayProvider);
    final result = widget.voiding
        ? await gateway.voidInsurerInvoice(invoiceId: widget.invoice.id, reason: value)
        : await gateway.markInsurerInvoicePaid(
            invoiceId: widget.invoice.id,
            reference: value,
            note: _note.text.trim(),
          );
    if (!mounted) return;
    switch (result) {
      case Ok():
        final toast = Toaster.of(context);
        Navigator.of(context).pop();
        toast.show(
          widget.voiding
              ? 'Factura anulada. Sus servicios irán en la próxima factura.'
              : 'Cobro registrado.',
        );
      case Err(:final failure):
        setState(() {
          _busy = false;
          _error = failure.userMessage;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final i = widget.invoice;
    return AlertDialog(
      title: Text(widget.voiding ? 'Anular factura ${i.ncf}' : 'Registrar cobro de ${i.ncf}'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.voiding
                  ? 'Los ${i.lines.length} servicio(s) vuelven a quedar por facturar '
                      'y saldrán en la próxima factura, con un NCF nuevo. El NCF '
                      '${i.ncf} queda usado${i.isTestNcf ? '' : ' y debe reportarse como anulado en el formato 608 de la DGII'}.'
                  : '${i.insurerName} · ${i.totalCents.formatDOP}',
            ),
            const SizedBox(height: Insets.lg),
            TextField(
              key: Key(widget.voiding ? 'invoice-void-reason' : 'invoice-reference'),
              controller: _main,
              autofocus: true,
              decoration: InputDecoration(
                labelText: widget.voiding ? 'Por qué se anula' : 'Número de transferencia',
              ),
            ),
            if (!widget.voiding) ...[
              const SizedBox(height: Insets.sm),
              TextField(
                key: const Key('invoice-payment-note'),
                controller: _note,
                decoration: const InputDecoration(labelText: 'Nota (opcional)'),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: Insets.md),
              InlineNotice(
                key: const Key('invoice-action-error'),
                tone: NoticeTone.error,
                message: _error!,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Volver'),
        ),
        ElevatedButton(
          key: const Key('confirm-invoice-action'),
          onPressed: _busy ? null : _submit,
          style: ElevatedButton.styleFrom(
            minimumSize: const Size(0, 44),
            backgroundColor: widget.voiding ? palette.danger : null,
          ),
          child: Text(widget.voiding ? 'Confirmar anulación' : 'Confirmar cobro'),
        ),
      ],
    );
  }
}
