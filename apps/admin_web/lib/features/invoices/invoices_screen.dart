import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';
import '../shared/form_dialog.dart';
import '../shared/page_parts.dart';
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
    final saved = ref
        .read(fileSaverProvider)
        .save(
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
    final toInvoice =
        ref.watch(servicesToInvoiceProvider).value ?? const <Service>[];
    final insurers = ref.watch(allInsurersProvider).value ?? const <Insurer>[];
    final sequence = ref.watch(creditNcfSequenceProvider).value;
    final now = DateTime.now().toUtc();

    final issued = invoices.where((i) => i.isIssued).toList();
    final overdue = invoices.where((i) => i.isOverdueAt(now)).toList();
    int sum(Iterable<InsurerInvoice> list) =>
        list.fold(0, (s, i) => s + i.totalCents);
    final waitingCents = toInvoice.fold<int>(
      0,
      (s, x) => s + (_billable(x) ?? 0),
    );

    final shown = [
      for (final i in invoices)
        if (_filter.matches(i, now) &&
            (_insurerId.isEmpty || i.insurerId == _insurerId))
          i,
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
        StatRow(
          children: [
            StatTile(
              key: const Key('kpi-receivable'),
              icon: Icons.request_quote_outlined,
              label: 'Por cobrar',
              value: sum(issued).formatDOP,
              detail: _count(issued.length, 'factura', 'facturas'),
              color: issued.isEmpty ? null : palette.info,
            ),
            StatTile(
              key: const Key('kpi-overdue'),
              icon: Icons.warning_amber_rounded,
              label: 'Vencidas',
              value: sum(overdue).formatDOP,
              detail: _count(overdue.length, 'factura', 'facturas'),
              color: overdue.isEmpty ? null : palette.danger,
            ),
            StatTile(
              key: const Key('kpi-to-invoice'),
              icon: Icons.pending_actions_outlined,
              label: 'Por facturar',
              value: ZonePricing.withItbis(waitingCents).totalCents.formatDOP,
              detail:
                  '${_count(toInvoice.length, 'servicio', 'servicios')}, '
                  'ITBIS incluido',
            ),
            StatTile(
              key: const Key('kpi-next-ncf'),
              icon: Icons.pin_outlined,
              label: 'Próximo NCF',
              value: sequence == null ? '—' : (Ncf.next(sequence) ?? '—'),
              detail: sequence == null
                  ? ''
                  : sequence.isTest
                  ? 'Secuencia de prueba'
                  : '${sequence.remaining} disponible(s)',
              color: sequence != null && sequence.isTest
                  ? palette.warning
                  : null,
            ),
          ],
        ),
        if (toInvoice.isNotEmpty) ...[
          const SizedBox(height: Insets.xl),
          ListCard(
            title: 'Por facturar',
            trailing: _CountChip(_byCompany(toInvoice, insurers).length),
            children: [
              for (final group in _byCompany(toInvoice, insurers))
                _ToInvoiceRow(group: group, canAct: isAdmin),
            ],
          ),
        ],
        const SizedBox(height: Insets.xl),
        // The filters on the left, what can be done with the result on the
        // right: the bar reads as "which invoices", then "and then".
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
            SizedBox(
              width: 260,
              child: DropdownButtonFormField<String>(
                key: const Key('invoice-insurer-filter'),
                initialValue: _insurerId,
                isExpanded: true,
                // No floating label: "Todas las aseguradoras" says what the
                // field is about on its own, and the label sat over the
                // border like a second heading.
                // Brought down to the export button's 44 px, so the two
                // controls at the end of the bar sit as one row.
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: Insets.md,
                    vertical: Insets.sm + 2,
                  ),
                  prefixIcon: Icon(Icons.shield_outlined, size: 18),
                ),
                items: [
                  const DropdownMenuItem(
                    value: '',
                    child: Text('Todas las aseguradoras'),
                  ),
                  for (final insurer in insurers)
                    DropdownMenuItem(
                      value: insurer.id,
                      child: Text(
                        insurer.name,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => _insurerId = v ?? ''),
              ),
            ),
            const SizedBox(width: Insets.sm),
            OutlinedButton.icon(
              key: const Key('export-invoices-excel'),
              onPressed: shown.isEmpty ? null : () => _export(shown, insurers),
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
              icon: const Icon(Icons.table_view_outlined),
              label: const Text('Exportar Excel'),
            ),
          ],
        ),
        const SizedBox(height: Insets.md),
        switch (invoicesAsync) {
          AsyncValue(:final error?) when !invoicesAsync.hasValue =>
            FloatingCard(
              child: EmptyState(
                icon: Icons.error_outline,
                tone: EmptyStateTone.error,
                title: 'No pudimos cargar las facturas',
                message: error is Failure
                    ? error.userMessage
                    : 'Revisa tu conexión e intenta de nuevo.',
              ),
            ),
          _ when shown.isEmpty && invoicesAsync.isLoading => const FloatingCard(
            child: Padding(
              padding: EdgeInsets.all(Insets.xl),
              child: BrandLoader(),
            ),
          ),
          _ when shown.isEmpty => FloatingCard(
            child: invoices.isEmpty
                ? EmptyState(
                    key: const Key('invoices-empty'),
                    icon: Icons.receipt_long_outlined,
                    title: 'Todavía no hay facturas',
                    message:
                        'Se emiten solas el día 1 de cada mes. También puedes '
                        'generarlas ahora.',
                    actionLabel: isAdmin ? 'Generar facturas' : null,
                    onAction: isAdmin
                        ? () => showDialog<void>(
                            context: context,
                            builder: (_) => const GenerateInvoicesDialog(),
                          )
                        : null,
                  )
                : const EmptyState(
                    key: Key('invoices-empty'),
                    icon: Icons.filter_alt_off_outlined,
                    title: 'Ninguna factura coincide',
                    message: 'Prueba con otro estado o con otra aseguradora.',
                  ),
          ),
          _ => ListCard(
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
      ],
    );
  }
}

/// "1 factura", "3 facturas": the count and the word agreeing, which
/// "factura(s)" never did.
String _count(int n, String one, String many) => '$n ${n == 1 ? one : many}';

/// A small grey count beside a card's title.
class _CountChip extends StatelessWidget {
  const _CountChip(this.count);

  final int count;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Insets.sm, vertical: 2),
      decoration: BoxDecoration(
        color: palette.surfaceSubtle,
        borderRadius: Corners.brSm,
      ),
      child: Text(
        '$count',
        style: Theme.of(context).textTheme.labelMedium
            ?.copyWith(color: palette.textMuted),
      ),
    );
  }
}

/// One company with finished work nobody has invoiced yet.
class _ToInvoiceRow extends StatelessWidget {
  const _ToInvoiceRow({required this.group, required this.canAct});

  final _Group group;
  final bool canAct;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final since = group.oldest == null
        ? ''
        : ', desde el ${DoTime.fullDate(group.oldest!)}';

    return Padding(
      key: Key('to-invoice-${group.insurerId}'),
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.lg,
        vertical: Insets.md,
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: palette.brand.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.shield_outlined, size: 20, color: palette.brand),
          ),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(group.name, style: text.titleSmall),
                Text(
                  _count(
                        group.count,
                        'servicio terminado',
                        'servicios terminados',
                      ) +
                      since,
                  style: text.bodySmall?.copyWith(color: palette.textMuted),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(group.subtotalCents.formatDOP, style: text.titleSmall),
              Text(
                '+ ITBIS',
                style: text.bodySmall?.copyWith(color: palette.textMuted),
              ),
            ],
          ),
          if (canAct) ...[
            const SizedBox(width: Insets.lg),
            OutlinedButton.icon(
              key: Key('invoice-now-${group.insurerId}'),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) =>
                    GenerateInvoicesDialog(insurerId: group.insurerId),
              ),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 40),
                padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
              ),
              icon: const Icon(Icons.request_quote_outlined, size: 18),
              label: const Text('Facturar'),
            ),
          ],
        ],
      ),
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
      name:
          names[s.insurerId] ??
          (s.insurerName.isEmpty ? s.insurerId : s.insurerName),
      count: (g?.count ?? 0) + 1,
      subtotalCents: (g?.subtotalCents ?? 0) + (_billable(s) ?? 0),
      oldest: oldest == null || (at != null && at.isBefore(oldest))
          ? at ?? oldest
          : oldest,
    );
  }
  return groups.values.toList()..sort((a, b) => a.name.compareTo(b.name));
}

/// One invoice in a list: its number, whose it is, what it covers, the
/// amount and where it stands, and a chevron because the row opens it.
class InvoiceTile extends StatelessWidget {
  const InvoiceTile({
    required this.invoice,
    required this.now,
    this.onTap,
    this.showCompany = true,
    this.padding = const EdgeInsets.symmetric(
      horizontal: Insets.lg,
      vertical: Insets.md,
    ),
    super.key,
  });

  final InsurerInvoice invoice;
  final DateTime now;
  final VoidCallback? onTap;
  final bool showCompany;

  /// Edge to edge in a [ListCard]; a card that pads its own content passes
  /// only the vertical part.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final i = invoice;
    final period = InvoicePeriod.isKey(i.periodKey)
        ? InvoicePeriod.parse(i.periodKey).title
        : i.periodKey;
    final tone = i.isVoided
        ? palette.textFaint
        : i.isOverdueAt(now)
        ? palette.danger
        : i.isPaid
        ? palette.success
        : palette.info;

    return InkWell(
      key: Key('invoice-row-${i.id}'),
      onTap: onTap,
      child: Padding(
        padding: padding,
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: tone.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.receipt_long_outlined, size: 20, color: tone),
            ),
            const SizedBox(width: Insets.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(i.ncf, style: text.titleSmall),
                      if (showCompany) ...[
                        Text(
                          '  ·  ',
                          style: text.bodyMedium?.copyWith(
                            color: palette.textFaint,
                          ),
                        ),
                        Flexible(
                          child: Text(
                            i.insurerName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodyMedium,
                          ),
                        ),
                      ],
                      if (i.isTestNcf) ...[
                        const SizedBox(width: Insets.sm),
                        const NcfTestChip(),
                      ],
                    ],
                  ),
                  const SizedBox(height: 1),
                  Text(
                    [
                      period,
                      _count(i.lines.length, 'servicio', 'servicios'),
                      if (i.dueAt != null && i.isIssued)
                        'vence ${InvoiceDocument.day(i.dueAt)}',
                      if (i.isPaid && i.paymentReference.isNotEmpty)
                        'Ref. ${i.paymentReference}',
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(color: palette.textMuted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: Insets.md),
            Text(i.totalCents.formatDOP, style: text.titleSmall),
            const SizedBox(width: Insets.md),
            // A fixed slot so the chips stack in a column however long the
            // word in each one is.
            SizedBox(
              width: 104,
              child: Align(
                alignment: Alignment.centerRight,
                child: InvoiceStatusChip(invoice: i, now: now),
              ),
            ),
            if (onTap != null) ...[
              const SizedBox(width: Insets.sm),
              Icon(Icons.chevron_right, size: 20, color: palette.textFaint),
            ],
          ],
        ),
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
        onAction: linkToSettings
            ? () => context.go(Routes.fiscalSettings)
            : null,
      );
    }
    if (sequence.isTest) {
      return InlineNotice(
        key: const Key('ncf-test-mode'),
        message:
            'Modo prueba: las facturas salen con NCF de prueba '
            '(${Ncf.next(sequence) ?? ''} en adelante) y quedan marcadas como tales. '
            'Cuando la DGII autorice la secuencia real, regístrala en '
            'Comprobantes (NCF) y las siguientes facturas la usarán.',
        actionLabel: linkToSettings ? 'Comprobantes (NCF)' : null,
        onAction: linkToSettings
            ? () => context.go(Routes.fiscalSettings)
            : null,
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
  ConsumerState<GenerateInvoicesDialog> createState() =>
      _GenerateInvoicesDialogState();
}

class _GenerateInvoicesDialogState
    extends ConsumerState<GenerateInvoicesDialog> {
  late final List<InvoicePeriod> _periods = InvoicePeriod.recent(
    DateTime.now().toUtc(),
  );
  late InvoicePeriod _period = _periods[1];
  late String _insurerId = widget.insurerId ?? '';
  var _busy = false;
  String? _error;

  Future<void> _generate() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await ref
        .read(functionsGatewayProvider)
        .generateInsurerInvoices(
          insurerId: _insurerId.isEmpty ? null : _insurerId,
          periodKey: _period.key,
        );
    if (!mounted) return;
    switch (result) {
      case Ok(:final value):
        final toast = Toaster.of(context);
        Navigator.of(context).pop();
        final made = value.created.length;
        final test = value.created.any((c) => c.isTestNcf)
            ? ' con NCF de prueba'
            : '';
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

    return Dialog(
      backgroundColor: palette.surface,
      clipBehavior: Clip.antiAlias,
      shape: const RoundedRectangleBorder(borderRadius: Corners.brLg),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FormDialogHeader(
              icon: Icons.request_quote_outlined,
              title: 'Generar facturas',
              subtitle: 'Lo que la corrida del día 1 emitiría, emitido ahora.',
              onClose: _busy ? null : () => Navigator.of(context).pop(),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Insets.xxl,
                Insets.xl,
                Insets.xxl,
                Insets.lg,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LabeledField(
                    label: 'Mes',
                    child: DropdownButtonFormField<InvoicePeriod>(
                      key: const Key('invoice-period'),
                      initialValue: _period,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        prefixIcon: Icon(
                          Icons.calendar_month_outlined,
                          size: 18,
                        ),
                      ),
                      items: [
                        for (final p in _periods)
                          DropdownMenuItem(
                            value: p,
                            child: Text(
                              p == current ? '${p.title} (en curso)' : p.title,
                            ),
                          ),
                      ],
                      onChanged: _busy
                          ? null
                          : (p) => setState(() => _period = p ?? _period),
                    ),
                  ),
                  LabeledField(
                    label: 'Aseguradora',
                    child: DropdownButtonFormField<String>(
                      key: const Key('invoice-insurer'),
                      initialValue: _insurerId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.shield_outlined, size: 18),
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: '',
                          child: Text('Todas las aseguradoras'),
                        ),
                        for (final insurer in insurers)
                          DropdownMenuItem(
                            value: insurer.id,
                            child: Text(
                              insurer.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: _busy
                          ? null
                          : (v) => setState(() => _insurerId = v ?? ''),
                    ),
                  ),
                  // What this run will pick up, said before it is run: the
                  // month in the field is an end date, not a window, and
                  // that is the part nobody would guess.
                  InlineNotice(
                    tone: NoticeTone.info,
                    icon: Icons.info_outline,
                    message: _period == current
                        ? 'Se factura lo terminado hasta ahora. Lo que termine '
                              'después irá en la factura del próximo mes.'
                        : 'Se factura lo terminado hasta el final de '
                              '${_period.label} que no esté facturado todavía, '
                              'incluidos servicios de meses anteriores que hayan '
                              'quedado pendientes.',
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: Insets.md),
                    InlineNotice(
                      key: const Key('generate-invoices-error'),
                      tone: NoticeTone.error,
                      icon: Icons.error_outline,
                      message: _error!,
                    ),
                  ],
                ],
              ),
            ),
            FormDialogFooter(
              submitting: _busy,
              label: 'Emitir facturas',
              submitKey: const Key('confirm-generate-invoices'),
              onCancel: () => Navigator.of(context).pop(),
              onSubmit: _generate,
            ),
          ],
        ),
      ),
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
                builder: (_) =>
                    _InvoiceActionDialog(invoice: value, voiding: true),
              ),
              style: TextButton.styleFrom(foregroundColor: palette.danger),
              child: const Text('Anular'),
            ),
            ElevatedButton.icon(
              key: const Key('pay-invoice'),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) =>
                    _InvoiceActionDialog(invoice: value, voiding: false),
              ),
              style: ElevatedButton.styleFrom(minimumSize: const Size(0, 44)),
              icon: const Icon(Icons.payments_outlined),
              label: const Text('Registrar cobro'),
            ),
          ],
        ],
      ),
      AsyncValue(isLoading: true) => const Center(
        child: CircularProgressIndicator(),
      ),
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
  ConsumerState<_InvoiceActionDialog> createState() =>
      _InvoiceActionDialogState();
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
      setState(
        () => _error = widget.voiding
            ? 'Escribe por qué se anula la factura.'
            : 'Escribe el número de la transferencia.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final gateway = ref.read(functionsGatewayProvider);
    final result = widget.voiding
        ? await gateway.voidInsurerInvoice(
            invoiceId: widget.invoice.id,
            reason: value,
          )
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
      title: Text(
        widget.voiding
            ? 'Anular factura ${i.ncf}'
            : 'Registrar cobro de ${i.ncf}',
      ),
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
              key: Key(
                widget.voiding ? 'invoice-void-reason' : 'invoice-reference',
              ),
              controller: _main,
              autofocus: true,
              decoration: InputDecoration(
                labelText: widget.voiding
                    ? 'Por qué se anula'
                    : 'Número de transferencia',
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
          child: Text(
            widget.voiding ? 'Confirmar anulación' : 'Confirmar cobro',
          ),
        ),
      ],
    );
  }
}
