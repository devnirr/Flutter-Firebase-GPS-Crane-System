import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

import '../shared/form_dialog.dart';

/// Opens the form for a new insurance company. Returns its id, or null.
/// A tap outside closes an untouched form and asks before throwing away a
/// filled-in one; see [FormDialogScope].
Future<String?> showCreateInsurerDialog(BuildContext context) =>
    showDialog<String>(
      context: context,
      builder: (_) => const InsurerFormDialog(),
    );

/// The same form, filled in from [insurer]. Returns true once saved.
Future<bool?> showEditInsurerDialog(BuildContext context, Insurer insurer) =>
    showDialog<bool>(
      context: context,
      builder: (_) => InsurerFormDialog(editing: insurer),
    );

/// "70", "65.5" → basis points; null for a blank field, which means the
/// default share.
int? payoutBpsFromText(String text) {
  final t = text.trim().replaceAll('%', '').replaceAll(',', '.');
  if (t.isEmpty) return null;
  final value = double.tryParse(t);
  if (value == null) return -1;
  return (value * 100).round();
}

/// Create or edit an insurance company: who it is, where its invoice goes, and
/// what share of its tows the chofer is paid.
class InsurerFormDialog extends ConsumerStatefulWidget {
  const InsurerFormDialog({this.editing, super.key});

  final Insurer? editing;

  @override
  ConsumerState<InsurerFormDialog> createState() => _InsurerFormDialogState();
}

class _InsurerFormDialogState extends ConsumerState<InsurerFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.editing?.name);
  late final _rnc = TextEditingController(text: widget.editing?.rncLabel);
  late final _billingEmail = TextEditingController(
    text: widget.editing?.billingEmail,
  );
  late final _contactName = TextEditingController(
    text: widget.editing?.contactName,
  );
  late final _contactEmail = TextEditingController(
    text: widget.editing?.contactEmail,
  );
  late final _contactPhone = TextEditingController(
    text: widget.editing?.contactPhone,
  );
  late final _payout = TextEditingController(text: _payoutText);

  var _submitting = false;
  String? _error;

  /// The contact block is folded away on a new company — it is optional, and
  /// hiding it is what makes the form fit without scrolling. A company that
  /// already has one opens with it in view.
  late bool _showContact =
      _isEdit &&
      [
        widget.editing?.contactName,
        widget.editing?.contactEmail,
        widget.editing?.contactPhone,
      ].any((v) => (v ?? '').trim().isNotEmpty);

  bool get _isEdit => widget.editing != null;

  String get _payoutText => switch (widget.editing?.driverPayoutBps) {
    null => '',
    final bps when bps % 100 == 0 => '${bps ~/ 100}',
    final bps => (bps / 100).toStringAsFixed(1),
  };

  /// Every field as it stood when the form opened. An edit starts out
  /// unchanged rather than fully typed.
  late final List<Object?> _opened;

  @override
  void initState() {
    super.initState();
    _opened = _snapshot();
    // The example under the field follows what is typed.
    _payout.addListener(() => setState(() {}));
  }

  /// Every field, in a fixed order, to compare against [_opened].
  List<Object?> _snapshot() => [
    for (final c in [
      _name,
      _rnc,
      _billingEmail,
      _contactName,
      _contactEmail,
      _contactPhone,
      _payout,
    ])
      c.text.trim(),
  ];

  bool get _dirty => !listEquals(_snapshot(), _opened);

  /// Closes the form, through the panel's one rule for it.
  Future<void> _close() => closeFormDialog(
    context,
    dirty: _dirty,
    submitting: _submitting,
    question: _isEdit
        ? '¿Descartar los cambios?'
        : '¿Descartar la aseguradora?',
    detail: _isEdit
        ? 'Los cambios que hiciste no se guardan.'
        : 'Lo que escribiste se pierde y la empresa no se agrega.',
  );

  @override
  void dispose() {
    for (final c in [
      _name,
      _rnc,
      _billingEmail,
      _contactName,
      _contactEmail,
      _contactPhone,
      _payout,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _payoutProblem(String? value) {
    final bps = payoutBpsFromText(value ?? '');
    if (bps == null) return null;
    if (bps < 0 || bps > 10000) return 'Escribe un porcentaje entre 0 y 100.';
    return null;
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _submitting = true;
      _error = null;
    });

    final details = InsurerDetails(
      name: _name.text,
      rnc: DoValidators.digits(_rnc.text),
      billingEmail: _billingEmail.text,
      contactName: _contactName.text,
      contactEmail: _contactEmail.text,
      contactPhone: _contactPhone.text,
    );
    final bps = payoutBpsFromText(_payout.text);
    final gateway = ref.read(functionsGatewayProvider);

    if (_isEdit) {
      final result = await gateway.updateInsurer(
        insurerId: widget.editing!.id,
        details: details,
        driverPayoutBps: bps,
        clearDriverPayout:
            bps == null && widget.editing!.driverPayoutBps != null,
      );
      if (!mounted) return;
      switch (result) {
        case Ok():
          Navigator.of(context).pop(true);
        case Err(:final failure):
          setState(() {
            _submitting = false;
            _error = failure.userMessage;
          });
      }
    } else {
      final result = await gateway.createInsurer(
        details: details,
        driverPayoutBps: bps,
      );
      if (!mounted) return;
      switch (result) {
        case Ok(:final value):
          Navigator.of(context).pop(value);
        case Err(:final failure):
          setState(() {
            _submitting = false;
            _error = failure.userMessage;
          });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return FormDialogScope(
      onClose: () => unawaited(_close()),
      child: Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720, maxHeight: 760),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FormDialogHeader(
                icon: Icons.shield_outlined,
                title: _isEdit ? 'Editar aseguradora' : 'Nueva aseguradora',
                subtitle:
                    'Sus datos de facturación y lo que se le paga al chofer.',
                onClose: _submitting ? null : () => unawaited(_close()),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(
                    Insets.xxl,
                    Insets.xl,
                    Insets.xxl,
                    Insets.lg,
                  ),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const FormSection(
                          'Empresa',
                          note: 'Como aparece en la factura del mes.',
                        ),
                        LabeledField(
                          label: 'Razón social',
                          required: true,
                          child: TextFormField(
                            key: const Key('insurer-name'),
                            controller: _name,
                            textCapitalization: TextCapitalization.words,
                            decoration: const InputDecoration(
                              hintText: 'Seguros Universal, S. A.',
                              prefixIcon: Icon(
                                Icons.business_outlined,
                                size: 18,
                              ),
                            ),
                            validator: (v) => (v ?? '').trim().length < 2
                                ? 'Escribe el nombre.'
                                : null,
                          ),
                        ),
                        FormRow(
                          left: LabeledField(
                            label: 'RNC',
                            required: true,
                            help: 'Nueve dígitos, como lo emite la DGII.',
                            child: TextFormField(
                              key: const Key('insurer-rnc'),
                              controller: _rnc,
                              inputFormatters: [RncInputFormatter()],
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                hintText: '1-30-00000-1',
                                prefixIcon: Icon(
                                  Icons.badge_outlined,
                                  size: 18,
                                ),
                              ),
                              validator: DoValidators.companyRnc,
                            ),
                          ),
                          right: LabeledField(
                            label: 'Correo de facturación',
                            required: true,
                            help: 'Adonde va la factura del mes.',
                            child: TextFormField(
                              key: const Key('insurer-billing-email'),
                              controller: _billingEmail,
                              keyboardType: TextInputType.emailAddress,
                              decoration: const InputDecoration(
                                hintText: 'facturas@empresa.com.do',
                                prefixIcon: Icon(
                                  Icons.receipt_long_outlined,
                                  size: 18,
                                ),
                              ),
                              validator: DoValidators.email,
                            ),
                          ),
                        ),
                        const SizedBox(height: Insets.sm),
                        const FormSection(
                          'Contacto',
                          note:
                              'Opcional: a quién llamar por un servicio o una '
                              'factura.',
                        ),
                        if (!_showContact)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              key: const Key('add-insurer-contact'),
                              onPressed: () =>
                                  setState(() => _showContact = true),
                              icon: const Icon(Icons.person_add_alt, size: 18),
                              label: const Text('Agregar contacto'),
                            ),
                          ),
                        if (_showContact) ...[
                          FormRow(
                            left: LabeledField(
                              label: 'Nombre',
                              child: TextFormField(
                                key: const Key('insurer-contact-name'),
                                controller: _contactName,
                                textCapitalization: TextCapitalization.words,
                                decoration: const InputDecoration(
                                  hintText: 'Marta Reyes',
                                  prefixIcon: Icon(
                                    Icons.person_outline,
                                    size: 18,
                                  ),
                                ),
                              ),
                            ),
                            right: LabeledField(
                              label: 'Teléfono',
                              child: TextFormField(
                                key: const Key('insurer-contact-phone'),
                                controller: _contactPhone,
                                keyboardType: TextInputType.phone,
                                inputFormatters: [DoPhoneInputFormatter()],
                                decoration: const InputDecoration(
                                  hintText: '(809) 555-0123',
                                  prefixIcon: Icon(
                                    Icons.call_outlined,
                                    size: 18,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          LabeledField(
                            label: 'Correo',
                            child: TextFormField(
                              key: const Key('insurer-contact-email'),
                              controller: _contactEmail,
                              keyboardType: TextInputType.emailAddress,
                              decoration: const InputDecoration(
                                hintText: 'marta@empresa.com.do',
                                prefixIcon: Icon(
                                  Icons.alternate_email,
                                  size: 18,
                                ),
                              ),
                              validator: (v) => (v ?? '').trim().isEmpty
                                  ? null
                                  : DoValidators.email(v),
                            ),
                          ),
                        ],
                        const SizedBox(height: Insets.sm),
                        const FormSection(
                          'Pago al chofer',
                          note:
                              'Lo que recibe el chofer por cada grúa de esta '
                              'empresa, sobre el precio sin ITBIS.',
                        ),
                        _PayoutField(
                          controller: _payout,
                          validator: _payoutProblem,
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: Insets.sm),
                          InlineNotice(
                            key: const Key('insurer-form-error'),
                            tone: NoticeTone.error,
                            icon: Icons.error_outline,
                            message: _error!,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              FormDialogFooter(
                submitting: _submitting,
                note: '* Obligatorio',
                label: _isEdit ? 'Guardar cambios' : 'Crear aseguradora',
                onCancel: () => unawaited(_close()),
                onSubmit: _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The chofer's share: a narrow percentage field, the usual values one press
/// away, and what the split works out to on a normal tow.
class _PayoutField extends StatelessWidget {
  const _PayoutField({required this.controller, required this.validator});

  final TextEditingController controller;
  final FormFieldValidator<String> validator;

  /// A zone-1 tow at the base price. Nothing is billed on this number; it is
  /// there so a percentage reads as money before anyone saves it.
  static const _exampleCents = 250000;

  static const _common = [65, 70, 75, 80];

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    final typed = payoutBpsFromText(controller.text);
    final bps = typed == null || typed < 0 || typed > 10000 ? 7000 : typed;
    final driver = Money.bps(_exampleCents, bps);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 190,
              child: LabeledField(
                label: 'Porcentaje para el chofer',
                help: 'En blanco: 70%.',
                child: TextFormField(
                  key: const Key('insurer-payout'),
                  controller: controller,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    hintText: '70',
                    suffixText: '%',
                    prefixIcon: Icon(Icons.percent, size: 18),
                  ),
                  validator: validator,
                ),
              ),
            ),
            const SizedBox(width: Insets.lg),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: Insets.xl),
                child: Wrap(
                  spacing: Insets.sm,
                  runSpacing: Insets.sm,
                  children: [
                    for (final value in _common)
                      _PayoutChoice(
                        value: value,
                        selected: typed == value * 100,
                        onTap: () => controller.text = '$value',
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
        Container(
          padding: const EdgeInsets.all(Insets.md),
          decoration: BoxDecoration(
            color: palette.surfaceSubtle,
            borderRadius: Corners.brSm,
            border: Border.all(color: palette.borderSubtle),
          ),
          child: Row(
            children: [
              Icon(
                Icons.calculate_outlined,
                size: 18,
                color: palette.textMuted,
              ),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    style: text.bodySmall?.copyWith(color: palette.textMuted),
                    children: [
                      TextSpan(
                        text:
                            'De una grúa de '
                            '${_exampleCents.formatDOPShort} (zona 1, '
                            'vehículo ligero), el chofer recibe ',
                      ),
                      TextSpan(
                        text: driver.formatDOPShort,
                        style: text.titleSmall?.copyWith(color: palette.text),
                      ),
                      TextSpan(
                        text:
                            ' y la empresa se queda con '
                            '${(_exampleCents - driver).formatDOPShort}.',
                      ),
                    ],
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

/// One of the shares the office actually negotiates, as a one-press chip.
class _PayoutChoice extends StatelessWidget {
  const _PayoutChoice({
    required this.value,
    required this.selected,
    required this.onTap,
  });

  final int value;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return InkWell(
      key: Key('payout-choice-$value'),
      onTap: onTap,
      borderRadius: Corners.brSm,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.md,
          vertical: Insets.sm,
        ),
        decoration: BoxDecoration(
          color: selected ? palette.brandTint : palette.surfaceSubtle,
          borderRadius: Corners.brSm,
          border: Border.all(color: selected ? palette.brand : palette.border),
        ),
        child: Text(
          '$value%',
          style: Theme.of(context).textTheme.labelMedium
              ?.copyWith(color: selected ? palette.brand : palette.textStrong),
        ),
      ),
    );
  }
}
