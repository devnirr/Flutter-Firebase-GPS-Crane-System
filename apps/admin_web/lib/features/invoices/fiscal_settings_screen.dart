import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';
import '../shared/toast.dart';
import 'invoices_screen.dart';

/// Comprobantes (NCF): the company's fiscal details and the range its
/// invoices are numbered from.
///
/// This page is the whole switch from test receipts to real ones. When the
/// DGII authorises the company's range, the office enters it here and the next
/// invoice uses it; nothing else changes.
class FiscalSettingsScreen extends ConsumerWidget {
  const FiscalSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final isAdmin = ref.watch(currentRoleProvider).value == UserRole.admin;
    final issuer = ref.watch(fiscalIssuerProvider).value;
    final sequence = ref.watch(creditNcfSequenceProvider).value;

    return ListView(
      padding: const EdgeInsets.all(Insets.xl),
      children: [
        Row(
          children: [
            IconButton(
              tooltip: 'Volver a facturación',
              onPressed: () => context.go(Routes.invoices),
              icon: const Icon(Icons.arrow_back),
            ),
            const SizedBox(width: Insets.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Comprobantes fiscales (NCF)', style: text.headlineSmall),
                  Text(
                    'Datos de la empresa que emite las facturas y la secuencia '
                    'de NCF autorizada por la DGII.',
                    style: text.bodyMedium?.copyWith(color: palette.textMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (!isAdmin) ...[
          const SizedBox(height: Insets.lg),
          const InlineNotice(
            tone: NoticeTone.info,
            message: 'Solo un administrador puede cambiar estos datos.',
          ),
        ],
        const SizedBox(height: Insets.xl),
        if (issuer == null || sequence == null)
          const Padding(
            padding: EdgeInsets.all(Insets.xl),
            child: Center(child: CircularProgressIndicator()),
          )
        else
          LayoutBuilder(
            builder: (context, constraints) {
              // A new key when the stored data changes, so each form shows
              // what was saved rather than what was typed before.
              final issuerForm = _IssuerForm(
                key: ValueKey(issuer.updatedAt),
                issuer: issuer,
                canEdit: isAdmin,
              );
              final sequenceForm = _SequenceForm(
                key: ValueKey(sequence.updatedAt),
                sequence: sequence,
                canEdit: isAdmin,
              );
              // Side by side only where both have room.
              if (constraints.maxWidth < 900) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    sequenceForm,
                    const SizedBox(height: Insets.xl),
                    issuerForm,
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: issuerForm),
                  const SizedBox(width: Insets.xl),
                  Expanded(child: sequenceForm),
                ],
              );
            },
          ),
      ],
    );
  }
}

class _IssuerForm extends ConsumerStatefulWidget {
  const _IssuerForm({required this.issuer, required this.canEdit, super.key});

  final FiscalIssuer issuer;
  final bool canEdit;

  @override
  ConsumerState<_IssuerForm> createState() => _IssuerFormState();
}

class _IssuerFormState extends ConsumerState<_IssuerForm> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.issuer.name);
  late final _rnc = TextEditingController(text: widget.issuer.rnc);
  late final _address = TextEditingController(text: widget.issuer.address);
  late final _phone = TextEditingController(text: widget.issuer.phone);
  late final _email = TextEditingController(text: widget.issuer.email);
  late final _terms =
      TextEditingController(text: widget.issuer.paymentTermsDays.toString());
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _rnc, _address, _phone, _email, _terms]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await ref.read(functionsGatewayProvider).saveFiscalIssuer(
          FiscalIssuer(
            name: _name.text,
            rnc: DoValidators.digits(_rnc.text),
            address: _address.text,
            phone: _phone.text,
            email: _email.text,
            paymentTermsDays: int.parse(_terms.text.trim()),
          ),
        );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = result.failureOrNull?.userMessage;
    });
    if (result.isOk) {
      showToast(context, 'Datos fiscales guardados.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final enabled = widget.canEdit && !_busy;

    return FloatingCard(
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Empresa emisora', style: text.titleMedium),
            const SizedBox(height: Insets.xs),
            Text(
              'Sale en el encabezado de cada factura. El RNC puede quedar vacío '
              'mientras la empresa está en constitución; las facturas dirán "En trámite".',
              style: text.bodySmall?.copyWith(color: palette.textMuted),
            ),
            const SizedBox(height: Insets.lg),
            TextFormField(
              key: const Key('issuer-name'),
              controller: _name,
              enabled: enabled,
              decoration: const InputDecoration(labelText: 'Razón social'),
              validator: (v) =>
                  (v?.trim().length ?? 0) < 2 ? 'Escribe la razón social.' : null,
            ),
            const SizedBox(height: Insets.md),
            TextFormField(
              key: const Key('issuer-rnc'),
              controller: _rnc,
              enabled: enabled,
              decoration: const InputDecoration(
                labelText: 'RNC',
                hintText: '1-30-00000-1',
                helperText: 'Vacío hasta que la DGII lo asigne.',
              ),
              validator: (v) {
                final digits = DoValidators.digits(v);
                if (digits.isEmpty) return null;
                return DoValidators.companyRnc(digits) == null ? null : 'Ese RNC no es válido.';
              },
            ),
            const SizedBox(height: Insets.md),
            TextFormField(
              key: const Key('issuer-address'),
              controller: _address,
              enabled: enabled,
              decoration: const InputDecoration(labelText: 'Dirección'),
            ),
            const SizedBox(height: Insets.md),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    key: const Key('issuer-phone'),
                    controller: _phone,
                    enabled: enabled,
                    decoration: const InputDecoration(labelText: 'Teléfono'),
                  ),
                ),
                const SizedBox(width: Insets.md),
                Expanded(
                  child: TextFormField(
                    key: const Key('issuer-email'),
                    controller: _email,
                    enabled: enabled,
                    decoration: const InputDecoration(labelText: 'Correo'),
                    validator: (v) {
                      final value = v?.trim() ?? '';
                      if (value.isEmpty) return null;
                      return DoValidators.email(value);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: Insets.md),
            TextFormField(
              key: const Key('issuer-terms'),
              controller: _terms,
              enabled: enabled,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: 'Días de crédito para las aseguradoras',
                helperText: '0 para contado.',
              ),
              validator: (v) {
                final days = int.tryParse(v?.trim() ?? '');
                return days == null || days > 180 ? 'Entre 0 y 180 días.' : null;
              },
            ),
            if (_error != null) ...[
              const SizedBox(height: Insets.md),
              InlineNotice(
                key: const Key('issuer-error'),
                tone: NoticeTone.error,
                message: _error!,
              ),
            ],
            if (widget.canEdit) ...[
              const SizedBox(height: Insets.lg),
              Align(
                alignment: Alignment.centerRight,
                child: ElevatedButton(
                  key: const Key('save-issuer'),
                  onPressed: enabled ? _save : null,
                  style: ElevatedButton.styleFrom(minimumSize: const Size(0, 44)),
                  child: const Text('Guardar datos fiscales'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SequenceForm extends ConsumerStatefulWidget {
  const _SequenceForm({required this.sequence, required this.canEdit, super.key});

  final NcfSequence sequence;
  final bool canEdit;

  @override
  ConsumerState<_SequenceForm> createState() => _SequenceFormState();
}

class _SequenceFormState extends ConsumerState<_SequenceForm> {
  final _formKey = GlobalKey<FormState>();
  late final _next = TextEditingController(
    text: widget.sequence.isTest ? '' : widget.sequence.nextNumber.toString(),
  );
  late final _last = TextEditingController(
    text: widget.sequence.isTest ? '' : widget.sequence.lastNumber.toString(),
  );
  late final _expires = TextEditingController(
    text: widget.sequence.isTest || widget.sequence.expiresOn == null
        ? ''
        : InvoiceDocument.isoDay(widget.sequence.expiresOn),
  );
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _next.dispose();
    _last.dispose();
    _expires.dispose();
    super.dispose();
  }

  /// `31/12/2027` → `2027-12-31`, or null.
  static String? _isoOf(String value) {
    final m = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{4})$').firstMatch(value.trim());
    if (m == null) return null;
    final iso = '${m.group(3)}-${m.group(2)!.padLeft(2, '0')}-${m.group(1)!.padLeft(2, '0')}';
    return Ncf.isIsoDay(iso) ? iso : null;
  }

  Future<void> _submit(NcfSequence sequence, String done) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await ref.read(functionsGatewayProvider).saveNcfSequence(sequence);
    if (!mounted) return;
    switch (result) {
      case Ok(:final value):
        setState(() => _busy = false);
        showToast(context, '$done La próxima factura será $value.');
      case Err(:final failure):
        setState(() {
          _busy = false;
          _error = failure.userMessage;
        });
    }
  }

  Future<void> _saveReal() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final sequence = NcfSequence(
      prefix: Ncf.creditoFiscal,
      nextNumber: int.parse(_next.text.trim()),
      lastNumber: int.parse(_last.text.trim()),
      expiresOn: _isoOf(_expires.text),
      isTest: false,
    );
    final first = Ncf.format(sequence.prefix, sequence.nextNumber);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('¿Usar la secuencia real?'),
        content: Text(
          'Desde ahora las facturas saldrán con NCF reales, empezando por $first '
          'hasta ${Ncf.format(sequence.prefix, sequence.lastNumber)}, válidos hasta '
          'el ${_expires.text.trim()}. Las facturas de prueba ya emitidas siguen '
          'marcadas como prueba; anúlalas para volver a emitirlas con NCF real.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            key: const Key('confirm-real-sequence'),
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(minimumSize: const Size(0, 40)),
            child: const Text('Usar secuencia real'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _submit(sequence, 'Secuencia real registrada.');
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final s = widget.sequence;
    final enabled = widget.canEdit && !_busy;
    final now = DateTime.now().toUtc();

    String? number(String? v) {
      final n = int.tryParse(v?.trim() ?? '');
      if (n == null || n < 1 || n > NcfSequence.maxNumber) return 'Número de 1 a 99,999,999.';
      return null;
    }

    return FloatingCard(
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Secuencia B01 · Crédito fiscal', style: text.titleMedium),
            const SizedBox(height: Insets.md),
            NcfSequenceNotice(sequence: s, now: now, linkToSettings: false),
            const SizedBox(height: Insets.md),
            DetailRow(
              label: 'Tipo',
              value: s.isTest ? 'Prueba (sin valor fiscal)' : 'Real, autorizada por la DGII',
              valueColor: s.isTest ? palette.warning : palette.success,
            ),
            DetailRow(
              key: const Key('sequence-next'),
              label: 'Próximo NCF',
              value: Ncf.next(s) ?? '—',
              emphasise: true,
            ),
            if (!s.isTest) ...[
              DetailRow(
                label: 'Último de la secuencia',
                value: Ncf.format(s.prefix, s.lastNumber),
              ),
              DetailRow(label: 'Disponibles', value: '${s.remaining}'),
              DetailRow(label: 'Válida hasta', value: InvoiceDocument.isoDay(s.expiresOn)),
            ],
            if (s.lastIssued.isNotEmpty)
              DetailRow(
                label: 'Último emitido',
                value: [
                  s.lastIssued,
                  if (s.lastIssuedAt != null) InvoiceDocument.day(s.lastIssuedAt),
                ].join(' · '),
              ),
            if (widget.canEdit) ...[
              const Divider(height: Insets.xxl),
              Text('Registrar secuencia autorizada', style: text.titleSmall),
              const SizedBox(height: Insets.xs),
              Text(
                'Copia los datos de la autorización de la DGII. Las facturas '
                'siguientes usarán esta secuencia; no hay que cambiar nada más.',
                style: text.bodySmall?.copyWith(color: palette.textMuted),
              ),
              const SizedBox(height: Insets.md),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextFormField(
                      key: const Key('sequence-from'),
                      controller: _next,
                      enabled: enabled,
                      onChanged: (_) => setState(() {}),
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        labelText: 'Desde (número)',
                        hintText: '1',
                      ),
                      validator: number,
                    ),
                  ),
                  const SizedBox(width: Insets.md),
                  Expanded(
                    child: TextFormField(
                      key: const Key('sequence-to'),
                      controller: _last,
                      enabled: enabled,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        labelText: 'Hasta (número)',
                        hintText: '500',
                      ),
                      validator: (v) {
                        final problem = number(v);
                        if (problem != null) return problem;
                        final from = int.tryParse(_next.text.trim());
                        if (from != null && int.parse(v!.trim()) < from) {
                          return 'Debe ser mayor o igual a "Desde".';
                        }
                        return null;
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Insets.md),
              TextFormField(
                key: const Key('sequence-expires'),
                controller: _expires,
                enabled: enabled,
                decoration: const InputDecoration(
                  labelText: 'Fecha de vencimiento',
                  hintText: 'dd/mm/aaaa',
                ),
                validator: (v) {
                  final iso = _isoOf(v ?? '');
                  if (iso == null) return 'Escribe la fecha como dd/mm/aaaa.';
                  final expiry = Ncf.expiryInstant(iso);
                  if (expiry == null || !expiry.isAfter(now)) return 'Esa fecha ya pasó.';
                  return null;
                },
              ),
              const SizedBox(height: Insets.sm),
              Text(
                [
                  'Primer NCF: ',
                  if (int.tryParse(_next.text.trim()) case final n?
                      when n >= 1 && n <= NcfSequence.maxNumber)
                    Ncf.format(Ncf.creditoFiscal, n)
                  else
                    '—',
                ].join(),
                style: text.bodySmall?.copyWith(color: palette.textMuted),
              ),
              if (_error != null) ...[
                const SizedBox(height: Insets.md),
                InlineNotice(
                  key: const Key('sequence-error'),
                  tone: NoticeTone.error,
                  message: _error!,
                ),
              ],
              const SizedBox(height: Insets.lg),
              Align(
                alignment: Alignment.centerRight,
                child: ElevatedButton(
                  key: const Key('save-real-sequence'),
                  onPressed: enabled ? _saveReal : null,
                  style: ElevatedButton.styleFrom(minimumSize: const Size(0, 44)),
                  child: const Text('Guardar secuencia real'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
