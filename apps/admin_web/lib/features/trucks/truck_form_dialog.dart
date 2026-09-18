import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

import '../shared/form_dialog.dart';
import '../shared/toast.dart';

/// Opens the form for a new grúa. Returns its id, or null when dismissed.
///
/// A tap outside closes an untouched form and asks before throwing away a
/// filled-in one: see [_TruckFormDialogState._close]. The barrier is dismissible
/// so that a tap outside reaches that code at all — with it off, the tap is
/// swallowed and the dialog just sits there.
Future<String?> showCreateTruckDialog(BuildContext context) =>
    showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (context) => const TruckFormDialog(),
    );

/// The same form, filled in from [truck]. Returns true once saved.
Future<bool?> showEditTruckDialog(BuildContext context, Truck truck) =>
    showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (context) => TruckFormDialog(editing: truck),
    );

/// Create or edit a grúa.
///
/// Who drives it is not on this form: a chofer is put on a grúa from the
/// chofer's form, so there is exactly one place that decides it.
class TruckFormDialog extends ConsumerStatefulWidget {
  const TruckFormDialog({this.editing, super.key});

  /// The grúa being edited, or null when adding one.
  final Truck? editing;

  @override
  ConsumerState<TruckFormDialog> createState() => _TruckFormDialogState();
}

class _TruckFormDialogState extends ConsumerState<TruckFormDialog> {
  final _formKey = GlobalKey<FormState>();

  final _plate = TextEditingController();
  final _make = TextEditingController();
  final _model = TextEditingController();
  final _year = TextEditingController();
  final _color = TextEditingController();
  final _capacity = TextEditingController();
  final _registration = TextEditingController();
  final _policy = TextEditingController();

  TruckType? _type;
  DateTime? _insuranceExpiry;
  DateTime? _marbeteExpiry;

  var _submitting = false;
  String? _error;

  /// Set on the first attempt to save. The two dates are not form fields, so
  /// this is what lets them stay quiet until then and report themselves after,
  /// the way a validator does.
  var _datesChecked = false;

  /// Every field as it stood when the form opened, to tell a form nobody has
  /// touched from one with work in it. Taken once [initState] has filled the
  /// controllers, so an edit starts out unchanged rather than fully typed.
  late final List<Object?> _opened;

  Truck? get _editing => widget.editing;
  bool get _isEdit => widget.editing != null;

  @override
  void initState() {
    super.initState();
    final truck = widget.editing;
    if (truck == null) {
      _opened = _snapshot();
      return;
    }

    _plate.text = truck.displayPlate;
    _make.text = truck.make;
    _model.text = truck.model;
    _year.text = truck.year?.toString() ?? '';
    _color.text = truck.color;
    _capacity.text = truck.capacityKg > 0 ? '${truck.capacityKg}' : '';
    _registration.text = truck.registrationNumber;
    _policy.text = truck.insurancePolicy;
    // A record decoded with a type this build does not know is not one to
    // save back: leave it unset so the office has to choose.
    _type = truck.type.isDispatchable ? truck.type : null;
    _insuranceExpiry = truck.insuranceExpiry;
    _marbeteExpiry = truck.marbeteExpiry;
    _opened = _snapshot();
  }

  @override
  void dispose() {
    for (final controller in [
      _plate,
      _make,
      _model,
      _year,
      _color,
      _capacity,
      _registration,
      _policy,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final assignedTo = _editing?.isAssigned == true
        ? _editing!.assignedDriverName
        : null;

    return FormDialogScope(
      onClose: () => unawaited(_close()),
      child: Dialog(
        backgroundColor: palette.surface,
        // The header and footer paint their own rounded corners over the full
        // width; without the clip they square off against the dialog's.
        clipBehavior: Clip.antiAlias,
        shape: const RoundedRectangleBorder(borderRadius: Corners.brLg),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 720,
            maxHeight: MediaQuery.sizeOf(context).height * 0.9,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FormDialogHeader(
                icon: Icons.local_shipping_outlined,
                title: _isEdit ? 'Editar grúa' : 'Nueva grúa',
                subtitle: _isEdit
                    ? 'Los cambios se guardan en la flota.'
                    : 'Se agrega sin chofer. Asígnala desde el formulario del '
                          'chofer.',
                onClose: _submitting ? null : _close,
              ),
              FormDialogBody(
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (assignedTo != null) ...[
                        InlineNotice(
                          icon: Icons.person_outline,
                          tone: NoticeTone.info,
                          message:
                              'Asignada a $assignedTo. Con un servicio en '
                              'curso no se le cambia la placa ni el tipo.',
                        ),
                        const SizedBox(height: Insets.lg),
                      ],
                      const FormSection('Identificación'),
                      FormRow(
                        left: LabeledField(
                          label: 'Placa',
                          required: true,
                          child: TextFormField(
                            controller: _plate,
                            textCapitalization: TextCapitalization.characters,
                            inputFormatters: [
                              _UpperCaseFormatter(),
                              LengthLimitingTextInputFormatter(10),
                            ],
                            decoration: const InputDecoration(
                              hintText: 'L123456',
                              prefixIcon: Icon(
                                Icons.confirmation_number_outlined,
                                size: 18,
                              ),
                            ),
                            validator: DoValidators.plate,
                          ),
                        ),
                        right: LabeledField(
                          label: 'Tipo de grúa',
                          required: true,
                          help: 'Decide qué servicios se le ofrecen.',
                          child: DropdownButtonFormField<TruckType>(
                            initialValue: _type,
                            isExpanded: true,
                            hint: const Text('Escoge el tipo'),
                            decoration: const InputDecoration(
                              prefixIcon: Icon(
                                Icons.local_shipping_outlined,
                                size: 18,
                              ),
                            ),
                            items: [
                              for (final type in TruckType.values)
                                if (type.isDispatchable)
                                  DropdownMenuItem(
                                    value: type,
                                    child: Text(type.label),
                                  ),
                            ],
                            onChanged: (value) => setState(() => _type = value),
                            validator: (value) => value == null
                                ? 'Escoge el tipo de grúa.'
                                : null,
                          ),
                        ),
                      ),
                      const FormSection('Vehículo'),
                      FormRow(
                        left: LabeledField(
                          label: 'Marca',
                          required: true,
                          child: TextFormField(
                            controller: _make,
                            textCapitalization: TextCapitalization.words,
                            inputFormatters: [
                              LengthLimitingTextInputFormatter(40),
                            ],
                            decoration: const InputDecoration(hintText: 'Ford'),
                            validator: (value) => (value ?? '').trim().isEmpty
                                ? 'Escribe la marca.'
                                : null,
                          ),
                        ),
                        right: LabeledField(
                          label: 'Modelo',
                          required: true,
                          child: TextFormField(
                            controller: _model,
                            textCapitalization: TextCapitalization.words,
                            inputFormatters: [
                              LengthLimitingTextInputFormatter(40),
                            ],
                            decoration: const InputDecoration(
                              hintText: 'F-450',
                            ),
                            validator: (value) => (value ?? '').trim().isEmpty
                                ? 'Escribe el modelo.'
                                : null,
                          ),
                        ),
                      ),
                      FormRow(
                        left: LabeledField(
                          label: 'Año',
                          child: TextFormField(
                            controller: _year,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(4),
                            ],
                            decoration: const InputDecoration(hintText: '2020'),
                            validator: _validateYear,
                          ),
                        ),
                        right: LabeledField(
                          label: 'Color',
                          child: TextFormField(
                            controller: _color,
                            textCapitalization: TextCapitalization.sentences,
                            inputFormatters: [
                              LengthLimitingTextInputFormatter(30),
                            ],
                            decoration: const InputDecoration(
                              hintText: 'Blanco',
                            ),
                          ),
                        ),
                        third: LabeledField(
                          label: 'Capacidad',
                          required: true,
                          child: TextFormField(
                            controller: _capacity,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(5),
                            ],
                            decoration: const InputDecoration(
                              hintText: '4500',
                              // Not `suffixText`, which Flutter hides until the
                              // field has focus or text: the unit is part of
                              // what is being asked for, so it stays put.
                              suffixIcon: _Unit('kg'),
                              suffixIconConstraints: BoxConstraints(
                                minWidth: 0,
                                minHeight: 0,
                              ),
                            ),
                            validator: _validateCapacity,
                          ),
                        ),
                      ),
                      const FormSection(
                        'Documentos',
                        note: 'La grúa sale de línea sola cuando uno vence.',
                      ),
                      FormRow(
                        left: LabeledField(
                          label: 'Matrícula',
                          child: TextFormField(
                            controller: _registration,
                            inputFormatters: [
                              LengthLimitingTextInputFormatter(40),
                            ],
                            decoration: const InputDecoration(
                              hintText: 'Número de matrícula',
                              prefixIcon: Icon(
                                Icons.description_outlined,
                                size: 18,
                              ),
                            ),
                          ),
                        ),
                        right: LabeledField(
                          label: 'Póliza de seguro',
                          child: TextFormField(
                            controller: _policy,
                            inputFormatters: [
                              LengthLimitingTextInputFormatter(60),
                            ],
                            decoration: const InputDecoration(
                              hintText: 'Número de póliza',
                              prefixIcon: Icon(Icons.shield_outlined, size: 18),
                            ),
                          ),
                        ),
                      ),
                      FormRow(
                        left: LabeledField(
                          label: 'Vencimiento del seguro',
                          required: true,
                          child: DateField(
                            value: _insuranceExpiry,
                            error: _dateError(_insuranceExpiry),
                            onPick: () => _pickDate(
                              current: _insuranceExpiry,
                              help: 'Vencimiento del seguro',
                              onPicked: (d) => _insuranceExpiry = d,
                            ),
                          ),
                        ),
                        right: LabeledField(
                          label: 'Vencimiento del marbete',
                          required: true,
                          child: DateField(
                            value: _marbeteExpiry,
                            error: _dateError(_marbeteExpiry),
                            onPick: () => _pickDate(
                              current: _marbeteExpiry,
                              help: 'Vencimiento del marbete',
                              onPicked: (d) => _marbeteExpiry = d,
                            ),
                          ),
                        ),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: Insets.md),
                        InlineNotice(
                          message: _error!,
                          icon: Icons.error_outline,
                          tone: NoticeTone.error,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              FormDialogFooter(
                submitting: _submitting,
                note: '* Obligatorio',
                label: _isEdit ? 'Guardar cambios' : 'Crear grúa',
                onCancel: _close,
                onSubmit: _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Closing
  // ---------------------------------------------------------------------------

  /// Every field, in a fixed order, to compare against [_opened].
  List<Object?> _snapshot() => [
    _plate.text.trim(),
    _make.text.trim(),
    _model.text.trim(),
    _year.text.trim(),
    _color.text.trim(),
    _capacity.text.trim(),
    _registration.text.trim(),
    _policy.text.trim(),
    _type,
    _insuranceExpiry,
    _marbeteExpiry,
  ];

  bool get _dirty => !listEquals(_snapshot(), _opened);

  /// Closes the form, through the panel's one rule for it.
  Future<void> _close() => closeFormDialog(
    context,
    dirty: _dirty,
    submitting: _submitting,
    question: _isEdit ? '¿Descartar los cambios?' : '¿Descartar la grúa?',
    detail: _isEdit
        ? 'Los cambios que hiciste no se guardan.'
        : 'Lo que escribiste se pierde y la grúa no se agrega.',
  );

  // ---------------------------------------------------------------------------
  // Fields
  // ---------------------------------------------------------------------------

  String? _validateYear(String? value) {
    final raw = (value ?? '').trim();
    if (raw.isEmpty) return null;
    final year = int.tryParse(raw);
    // The same bounds `truckFields` enforces on the server.
    final newest = DateTime.now().year + 1;
    if (year == null || year < 1970 || year > newest) {
      return 'Entre 1970 y $newest.';
    }
    return null;
  }

  String? _validateCapacity(String? value) {
    final kg = int.tryParse((value ?? '').trim());
    if (kg == null || kg <= 0) return 'Escribe la capacidad en kilos.';
    if (kg > 60000) return 'Máximo 60,000 kg.';
    return null;
  }

  /// A date left empty, reported under its own field rather than as one line
  /// by the button, and only once saving has been tried.
  String? _dateError(DateTime? value) =>
      _datesChecked && value == null ? 'Escoge la fecha.' : null;

  Future<void> _pickDate({
    required DateTime? current,
    required String help,
    required ValueChanged<DateTime> onPicked,
  }) async {
    final now = DateTime.now();
    // Past dates are allowed: the office records the paperwork as it is, and
    // an expired seguro is exactly what the fleet screen should then flag.
    final first = DateTime(now.year - 5);
    final last = DateTime(now.year + 10);
    final initial =
        current == null || current.isBefore(first) || current.isAfter(last)
        ? now.add(const Duration(days: 365))
        : current;

    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
      helpText: help,
    );
    if (picked != null) setState(() => onPicked(picked));
  }

  // ---------------------------------------------------------------------------
  // Submit
  // ---------------------------------------------------------------------------

  Future<void> _submit() async {
    final formOk = _formKey.currentState?.validate() ?? false;

    // The dates are not form fields, so they are checked here; from now on
    // each reports itself under its own field.
    setState(() => _datesChecked = true);
    final datesOk = _insuranceExpiry != null && _marbeteExpiry != null;
    if (!formOk || !datesOk) return;

    final details = TruckDetails(
      plate: DoValidators.plateKey(_plate.text),
      make: _make.text.trim(),
      model: _model.text.trim(),
      year: int.tryParse(_year.text.trim()),
      color: _color.text.trim(),
      type: _type!,
      capacityKg: int.parse(_capacity.text.trim()),
      registrationNumber: _registration.text.trim(),
      insurancePolicy: _policy.text.trim(),
      insuranceExpiry: _insuranceExpiry!,
      marbeteExpiry: _marbeteExpiry!,
    );

    setState(() {
      _submitting = true;
      _error = null;
    });

    final gateway = ref.read(functionsGatewayProvider);
    final editing = _editing;
    final Result<Object?> result = editing == null
        ? await gateway.createTruck(details)
        : await gateway.updateTruck(editing.id, details);
    if (!mounted) return;

    switch (result) {
      case Err(:final failure):
        setState(() {
          _submitting = false;
          _error = failure.userMessage;
        });
      case Ok(:final value):
        final toast = Toaster.of(context);
        Navigator.of(context).pop(editing == null ? value : true);
        toast.show(
          editing == null
              ? 'Grúa ${details.plate} agregada a la flota.'
              : 'Cambios guardados.',
        );
    }
  }
}

/// The unit a number is asked in, sitting inside the field's trailing edge.
class _Unit extends StatelessWidget {
  const _Unit(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: Insets.lg, left: Insets.sm),
    child: Text(
      label,
      style: Theme.of(context).textTheme.bodyMedium
          ?.copyWith(color: context.palette.textFaint),
    ),
  );
}

/// Plates are written in capitals; typing "l123456" should read as it will
/// be stored.
class _UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) => newValue.copyWith(text: newValue.text.toUpperCase());
}
