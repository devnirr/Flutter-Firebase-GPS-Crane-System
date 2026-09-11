import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

import '../shared/form_dialog.dart';

/// Opens the form for a new grúa. Returns its id, or null when dismissed.
Future<String?> showCreateTruckDialog(BuildContext context) => showDialog<String>(
      context: context,
      // The form holds typed data; a stray tap outside should not throw it away.
      barrierDismissible: false,
      builder: (context) => const TruckFormDialog(),
    );

/// The same form, filled in from [truck]. Returns true once saved.
Future<bool?> showEditTruckDialog(BuildContext context, Truck truck) =>
    showDialog<bool>(
      context: context,
      barrierDismissible: false,
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

  Truck? get _editing => widget.editing;
  bool get _isEdit => widget.editing != null;

  @override
  void initState() {
    super.initState();
    final truck = widget.editing;
    if (truck == null) return;

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
    final assignedTo = _editing?.isAssigned == true
        ? _editing!.assignedDriverName
        : null;

    return Dialog(
      backgroundColor: BrandColors.white,
      shape: const RoundedRectangleBorder(borderRadius: Corners.brMd),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 620,
          maxHeight: MediaQuery.sizeOf(context).height * 0.9,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FormDialogHeader(
              title: _isEdit ? 'Editar grúa' : 'Nueva grúa',
              subtitle: _isEdit
                  ? 'Los cambios se guardan en la flota.'
                  : 'Se agrega sin chofer. Asígnala desde el formulario del '
                      'chofer.',
              onClose: _submitting ? null : () => Navigator.of(context).pop(),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  Insets.xxl,
                  Insets.lg,
                  Insets.xxl,
                  Insets.lg,
                ),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (assignedTo != null) ...[
                        InlineNotice(
                          icon: Icons.person_outline,
                          tone: NoticeTone.info,
                          message: 'Asignada a $assignedTo. La placa y el tipo '
                              'no se pueden cambiar mientras tenga un servicio '
                              'en curso, ni el tipo mientras esté en línea.',
                        ),
                        const SizedBox(height: Insets.lg),
                      ],
                      const FormSection('Identificación'),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: LabeledField(
                              label: 'Placa',
                              required: true,
                              child: TextFormField(
                                controller: _plate,
                                textCapitalization:
                                    TextCapitalization.characters,
                                inputFormatters: [
                                  _UpperCaseFormatter(),
                                  LengthLimitingTextInputFormatter(10),
                                ],
                                decoration: const InputDecoration(
                                  hintText: 'L123456',
                                ),
                                validator: DoValidators.plate,
                              ),
                            ),
                          ),
                          const SizedBox(width: Insets.lg),
                          Expanded(
                            child: LabeledField(
                              label: 'Tipo de grúa',
                              required: true,
                              help: 'Decide qué servicios se le ofrecen.',
                              child: DropdownButtonFormField<TruckType>(
                                initialValue: _type,
                                isExpanded: true,
                                hint: const Text('Escoge el tipo'),
                                decoration: const InputDecoration(),
                                items: [
                                  for (final type in TruckType.values)
                                    if (type.isDispatchable)
                                      DropdownMenuItem(
                                        value: type,
                                        child: Text(type.label),
                                      ),
                                ],
                                onChanged: (value) =>
                                    setState(() => _type = value),
                                validator: (value) => value == null
                                    ? 'Escoge el tipo de grúa.'
                                    : null,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: Insets.sm),
                      const FormSection('Vehículo'),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: LabeledField(
                              label: 'Marca',
                              required: true,
                              child: TextFormField(
                                controller: _make,
                                textCapitalization: TextCapitalization.words,
                                inputFormatters: [
                                  LengthLimitingTextInputFormatter(40),
                                ],
                                decoration: const InputDecoration(
                                  hintText: 'Ford',
                                ),
                                validator: (value) =>
                                    (value ?? '').trim().isEmpty
                                        ? 'Escribe la marca.'
                                        : null,
                              ),
                            ),
                          ),
                          const SizedBox(width: Insets.lg),
                          Expanded(
                            child: LabeledField(
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
                                validator: (value) =>
                                    (value ?? '').trim().isEmpty
                                        ? 'Escribe el modelo.'
                                        : null,
                              ),
                            ),
                          ),
                        ],
                      ),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: LabeledField(
                              label: 'Año',
                              child: TextFormField(
                                controller: _year,
                                keyboardType: TextInputType.number,
                                inputFormatters: [
                                  FilteringTextInputFormatter.digitsOnly,
                                  LengthLimitingTextInputFormatter(4),
                                ],
                                decoration: const InputDecoration(
                                  hintText: '2020',
                                ),
                                validator: _validateYear,
                              ),
                            ),
                          ),
                          const SizedBox(width: Insets.lg),
                          Expanded(
                            child: LabeledField(
                              label: 'Color',
                              child: TextFormField(
                                controller: _color,
                                textCapitalization:
                                    TextCapitalization.sentences,
                                inputFormatters: [
                                  LengthLimitingTextInputFormatter(30),
                                ],
                                decoration: const InputDecoration(
                                  hintText: 'Blanco',
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: Insets.lg),
                          Expanded(
                            child: LabeledField(
                              label: 'Capacidad (kg)',
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
                                ),
                                validator: _validateCapacity,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: Insets.sm),
                      const FormSection('Documentos'),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: LabeledField(
                              label: 'Matrícula',
                              child: TextFormField(
                                controller: _registration,
                                inputFormatters: [
                                  LengthLimitingTextInputFormatter(40),
                                ],
                                decoration: const InputDecoration(
                                  hintText: 'Número de matrícula',
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: Insets.lg),
                          Expanded(
                            child: LabeledField(
                              label: 'Póliza de seguro',
                              child: TextFormField(
                                controller: _policy,
                                inputFormatters: [
                                  LengthLimitingTextInputFormatter(60),
                                ],
                                decoration: const InputDecoration(
                                  hintText: 'Número de póliza',
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: LabeledField(
                              label: 'Vencimiento del seguro',
                              required: true,
                              child: DateField(
                                value: _insuranceExpiry,
                                onPick: () => _pickDate(
                                  current: _insuranceExpiry,
                                  help: 'Vencimiento del seguro',
                                  onPicked: (d) => _insuranceExpiry = d,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: Insets.lg),
                          Expanded(
                            child: LabeledField(
                              label: 'Vencimiento del marbete',
                              required: true,
                              child: DateField(
                                value: _marbeteExpiry,
                                onPick: () => _pickDate(
                                  current: _marbeteExpiry,
                                  help: 'Vencimiento del marbete',
                                  onPicked: (d) => _marbeteExpiry = d,
                                ),
                              ),
                            ),
                          ),
                        ],
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
            ),
            FormDialogFooter(
              submitting: _submitting,
              label: _isEdit ? 'Guardar cambios' : 'Crear grúa',
              onCancel: () => Navigator.of(context).pop(),
              onSubmit: _submit,
            ),
          ],
        ),
      ),
    );
  }

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
    final initial = current == null ||
            current.isBefore(first) ||
            current.isAfter(last)
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

    // The dates are not form fields, so they are checked here and reported the
    // way a validator would.
    final missing = [
      if (_insuranceExpiry == null) 'del seguro',
      if (_marbeteExpiry == null) 'del marbete',
    ];
    setState(() {
      _error = missing.isEmpty
          ? null
          : 'Escoge la fecha de vencimiento ${missing.join(' y ')}.';
    });
    if (!formOk || missing.isNotEmpty) return;

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
        final messenger = ScaffoldMessenger.of(context);
        Navigator.of(context).pop(editing == null ? value : true);
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              editing == null
                  ? 'Grúa ${details.plate} agregada a la flota.'
                  : 'Cambios guardados.',
            ),
          ),
        );
    }
  }
}

/// Plates are written in capitals; typing "l123456" should read as it will
/// be stored.
class _UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) =>
      newValue.copyWith(text: newValue.text.toUpperCase());
}
