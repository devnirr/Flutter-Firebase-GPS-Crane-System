import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';
import '../shared/form_dialog.dart';
import '../shared/page_parts.dart';
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
            PageBackButton(
              tooltip: 'Volver a facturación',
              onPressed: () => context.go(Routes.invoices),
            ),
            const SizedBox(width: Insets.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Comprobantes fiscales (NCF)',
                    style: text.headlineSmall,
                  ),
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
  late final _terms = TextEditingController(
    text: widget.issuer.paymentTermsDays.toString(),
  );
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
    final result = await ref
        .read(functionsGatewayProvider)
        .saveFiscalIssuer(
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
    final enabled = widget.canEdit && !_busy;

    return FloatingCard(
      padding: const EdgeInsets.all(Insets.xl),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _CardTitle(
              icon: Icons.business_outlined,
              title: 'Empresa emisora',
              note:
                  'Sale en el encabezado de cada factura. El RNC puede quedar '
                  'vacío mientras la empresa está en constitución; las '
                  'facturas dirán "En trámite".',
            ),
            const SizedBox(height: Insets.xl),
            LabeledField(
              label: 'Razón social',
              required: true,
              child: TextFormField(
                key: const Key('issuer-name'),
                controller: _name,
                enabled: enabled,
                decoration: const InputDecoration(
                  hintText: 'Grúas RD, SRL',
                  prefixIcon: Icon(Icons.business_outlined, size: 18),
                ),
                validator: (v) => (v?.trim().length ?? 0) < 2
                    ? 'Escribe la razón social.'
                    : null,
              ),
            ),
            FormRow(
              left: LabeledField(
                label: 'RNC',
                help: 'Vacío hasta que la DGII lo asigne.',
                child: TextFormField(
                  key: const Key('issuer-rnc'),
                  controller: _rnc,
                  enabled: enabled,
                  decoration: const InputDecoration(
                    hintText: '1-30-00000-1',
                    prefixIcon: Icon(Icons.badge_outlined, size: 18),
                  ),
                  validator: (v) {
                    final digits = DoValidators.digits(v);
                    if (digits.isEmpty) return null;
                    return DoValidators.companyRnc(digits) == null
                        ? null
                        : 'Ese RNC no es válido.';
                  },
                ),
              ),
              right: LabeledField(
                label: 'Días de crédito',
                required: true,
                help: 'Para pagar cada factura. 0 para contado.',
                child: TextFormField(
                  key: const Key('issuer-terms'),
                  controller: _terms,
                  enabled: enabled,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    hintText: '30',
                    prefixIcon: Icon(Icons.event_outlined, size: 18),
                    suffixText: 'días',
                  ),
                  validator: (v) {
                    final days = int.tryParse(v?.trim() ?? '');
                    return days == null || days > 180
                        ? 'Entre 0 y 180 días.'
                        : null;
                  },
                ),
              ),
            ),
            LabeledField(
              label: 'Dirección',
              child: TextFormField(
                key: const Key('issuer-address'),
                controller: _address,
                enabled: enabled,
                decoration: const InputDecoration(
                  hintText: 'Calle, número, sector, ciudad',
                  prefixIcon: Icon(Icons.place_outlined, size: 18),
                ),
              ),
            ),
            FormRow(
              left: LabeledField(
                label: 'Teléfono',
                child: TextFormField(
                  key: const Key('issuer-phone'),
                  controller: _phone,
                  enabled: enabled,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    hintText: '809 555-0150',
                    prefixIcon: Icon(Icons.phone_outlined, size: 18),
                  ),
                ),
              ),
              right: LabeledField(
                label: 'Correo',
                child: TextFormField(
                  key: const Key('issuer-email'),
                  controller: _email,
                  enabled: enabled,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    hintText: 'facturacion@empresa.com.do',
                    prefixIcon: Icon(Icons.mail_outline, size: 18),
                  ),
                  validator: (v) {
                    final value = v?.trim() ?? '';
                    if (value.isEmpty) return null;
                    return DoValidators.email(value);
                  },
                ),
              ),
            ),
            if (_error != null) ...[
              InlineNotice(
                key: const Key('issuer-error'),
                tone: NoticeTone.error,
                icon: Icons.error_outline,
                message: _error!,
              ),
              const SizedBox(height: Insets.lg),
            ],
            if (widget.canEdit)
              Align(
                alignment: Alignment.centerRight,
                child: _SaveButton(
                  buttonKey: const Key('save-issuer'),
                  label: 'Guardar datos fiscales',
                  busy: _busy,
                  onPressed: enabled ? _save : null,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SequenceForm extends ConsumerStatefulWidget {
  const _SequenceForm({
    required this.sequence,
    required this.canEdit,
    super.key,
  });

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
    final iso =
        '${m.group(3)}-${m.group(2)!.padLeft(2, '0')}-${m.group(1)!.padLeft(2, '0')}';
    return Ncf.isIsoDay(iso) ? iso : null;
  }

  Future<void> _submit(NcfSequence sequence, String done) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await ref
        .read(functionsGatewayProvider)
        .saveNcfSequence(sequence);
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
      if (n == null || n < 1 || n > NcfSequence.maxNumber) {
        return 'Número de 1 a 99,999,999.';
      }
      return null;
    }

    final firstNcf = switch (int.tryParse(_next.text.trim())) {
      final n? when n >= 1 && n <= NcfSequence.maxNumber => Ncf.format(
        Ncf.creditoFiscal,
        n,
      ),
      _ => '—',
    };

    return FloatingCard(
      padding: const EdgeInsets.all(Insets.xl),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _CardTitle(
              icon: Icons.pin_outlined,
              title: 'Secuencia B01 · Crédito fiscal',
              note: 'El rango de números con que se emiten las facturas.',
            ),
            const SizedBox(height: Insets.lg),
            NcfSequenceNotice(sequence: s, now: now, linkToSettings: false),
            const SizedBox(height: Insets.lg),
            // The state of the range at a glance: each figure over its label
            // rather than at the far end of a row, where the eye had to cross
            // half a card to pair them up.
            Wrap(
              spacing: Insets.xl,
              runSpacing: Insets.lg,
              children: [
                _Fact(
                  label: 'Tipo',
                  value: s.isTest
                      ? 'Prueba (sin valor fiscal)'
                      : 'Real, autorizada por la DGII',
                  color: s.isTest ? palette.warning : palette.success,
                ),
                _Fact(
                  key: const Key('sequence-next'),
                  label: 'Próximo NCF',
                  value: Ncf.next(s) ?? '—',
                  large: true,
                ),
                if (!s.isTest) ...[
                  _Fact(
                    label: 'Último de la secuencia',
                    value: Ncf.format(s.prefix, s.lastNumber),
                  ),
                  _Fact(label: 'Disponibles', value: '${s.remaining}'),
                  _Fact(
                    label: 'Válida hasta',
                    value: InvoiceDocument.isoDay(s.expiresOn),
                  ),
                ],
                if (s.lastIssued.isNotEmpty)
                  _Fact(
                    label: 'Último emitido',
                    value: [
                      s.lastIssued,
                      if (s.lastIssuedAt != null)
                        InvoiceDocument.day(s.lastIssuedAt),
                    ].join(' · '),
                  ),
              ],
            ),
            if (widget.canEdit) ...[
              const SizedBox(height: Insets.xl),
              const FormSection(
                'Registrar secuencia autorizada',
                note:
                    'Copia los datos de la autorización de la DGII. Las '
                    'facturas siguientes usarán esta secuencia; no hay que '
                    'cambiar nada más.',
              ),
              FormRow(
                left: LabeledField(
                  label: 'Desde',
                  required: true,
                  child: TextFormField(
                    key: const Key('sequence-from'),
                    controller: _next,
                    enabled: enabled,
                    onChanged: (_) => setState(() {}),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      hintText: '1',
                      prefixIcon: Icon(Icons.first_page, size: 18),
                    ),
                    validator: number,
                  ),
                ),
                right: LabeledField(
                  label: 'Hasta',
                  required: true,
                  child: TextFormField(
                    key: const Key('sequence-to'),
                    controller: _last,
                    enabled: enabled,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      hintText: '500',
                      prefixIcon: Icon(Icons.last_page, size: 18),
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
              ),
              LabeledField(
                label: 'Fecha de vencimiento',
                required: true,
                child: TextFormField(
                  key: const Key('sequence-expires'),
                  controller: _expires,
                  enabled: enabled,
                  decoration: const InputDecoration(
                    hintText: 'dd/mm/aaaa',
                    prefixIcon: Icon(Icons.event_outlined, size: 18),
                  ),
                  validator: (v) {
                    final iso = _isoOf(v ?? '');
                    if (iso == null) return 'Escribe la fecha como dd/mm/aaaa.';
                    final expiry = Ncf.expiryInstant(iso);
                    if (expiry == null || !expiry.isAfter(now)) {
                      return 'Esa fecha ya pasó.';
                    }
                    return null;
                  },
                ),
              ),
              // What "Desde" turns into, as the number the first invoice will
              // carry, so a missing digit shows before it is saved.
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: Insets.lg,
                  vertical: Insets.md,
                ),
                decoration: BoxDecoration(
                  color: palette.surfaceSubtle,
                  borderRadius: Corners.brMd,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.receipt_long_outlined,
                      size: 18,
                      color: palette.textMuted,
                    ),
                    const SizedBox(width: Insets.sm),
                    Text('Primer NCF: $firstNcf', style: text.bodyMedium),
                  ],
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: Insets.md),
                InlineNotice(
                  key: const Key('sequence-error'),
                  tone: NoticeTone.error,
                  icon: Icons.error_outline,
                  message: _error!,
                ),
              ],
              const SizedBox(height: Insets.lg),
              Align(
                alignment: Alignment.centerRight,
                child: _SaveButton(
                  buttonKey: const Key('save-real-sequence'),
                  label: 'Guardar secuencia real',
                  busy: _busy,
                  onPressed: enabled ? _saveReal : null,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// An icon, a card's title, and a line saying what the card is for.
class _CardTitle extends StatelessWidget {
  const _CardTitle({
    required this.icon,
    required this.title,
    required this.note,
  });

  final IconData icon;
  final String title;
  final String note;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: palette.brandTint,
            borderRadius: Corners.brSm,
          ),
          child: Icon(icon, size: 20, color: palette.brand),
        ),
        const SizedBox(width: Insets.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: text.titleMedium),
              const SizedBox(height: Insets.xxs),
              Text(
                note,
                style: text.bodySmall?.copyWith(color: palette.textMuted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One stored figure: its label over its value.
class _Fact extends StatelessWidget {
  const _Fact({
    required this.label,
    required this.value,
    this.color,
    this.large = false,
    super.key,
  });

  final String label;
  final String value;
  final Color? color;

  /// The next NCF, the figure the whole card is about.
  final bool large;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 160),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          FieldLabel(label),
          const SizedBox(height: Insets.xxs),
          Text(
            value,
            style: (large ? text.titleLarge : text.bodyLarge)?.copyWith(
              color: color ?? palette.text,
              fontWeight: large ? FontWeight.w700 : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// A save button that turns into a spinner while it saves, so the wait is
/// seen rather than guessed at from a greyed-out button.
class _SaveButton extends StatelessWidget {
  const _SaveButton({
    required this.buttonKey,
    required this.label,
    required this.busy,
    required this.onPressed,
  });

  final Key buttonKey;
  final String label;
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return ElevatedButton(
      key: buttonKey,
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: Insets.xl),
        disabledBackgroundColor: busy
            ? palette.brand.withValues(alpha: 0.75)
            : null,
        disabledForegroundColor: busy ? BrandColors.white : null,
      ),
      child: busy
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: BrandColors.white,
              ),
            )
          : Text(label),
    );
  }
}
