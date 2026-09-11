import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

import '../shared/form_dialog.dart';

/// How the dialog gets a file off the office's machine.
///
/// A provider rather than a direct call so a widget test can hand the form a
/// file: there is no native picker to drive in a test, and a form whose only
/// required attachment cannot be filled in is a form that cannot be tested.
typedef DocumentPicker = Future<PickedDocument?> Function();

final documentPickerProvider =
    Provider<DocumentPicker>((ref) => pickDocumentFromDisk);

/// The profile-photo picker. Images the browser can draw only: the roster shows
/// this file in a circle, where a PDF or a HEIC would just be initials.
final avatarPickerProvider =
    Provider<DocumentPicker>((ref) => pickAvatarFromDisk);

Future<PickedDocument?> pickDocumentFromDisk() =>
    _pickFromDisk(const ['jpg', 'jpeg', 'png', 'webp', 'heic', 'pdf']);

Future<PickedDocument?> pickAvatarFromDisk() =>
    _pickFromDisk(const ['jpg', 'jpeg', 'png', 'webp']);

/// The real picker. Reads the bytes on the spot: the panel is a web build,
/// where a picked file is a blob with no path an uploader could open later.
Future<PickedDocument?> _pickFromDisk(List<String> extensions) async {
  final file = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: extensions,
  );
  if (file == null) return null;

  return PickedDocument(
    name: file.name,
    bytes: await file.readAsBytes(),
    extension: (file.extension ?? 'jpg').toLowerCase(),
  );
}

/// The "Nuevo chofer" form.
///
/// Everything here is what the office copies off a chofer's papers, in the
/// order the papers are usually laid out: identity, licence, the grúa, then the
/// company details that end up on an invoice. The account it opens is always
/// `inactive` — the server decides that, not this form — so nothing on screen
/// pretends the chofer can start working when the dialog closes.
///
/// Returns the created chofer's id, or null when the dialog was dismissed.
Future<String?> showCreateDriverDialog(BuildContext context) {
  return showDialog<String>(
    context: context,
    // The form holds typed data; a stray tap outside should not throw it away.
    barrierDismissible: false,
    builder: (context) => const CreateDriverDialog(),
  );
}

/// The same form, filled in from [driver] and saved through `updateDriver`.
///
/// The cédula is shown but not editable: it is who the chofer is, and the
/// duplicate check keys on it. Both photos are already on file, so picking one
/// here replaces it rather than being required. Returns true once saved.
Future<bool?> showEditDriverDialog(BuildContext context, Driver driver) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => CreateDriverDialog(editing: driver),
  );
}

class CreateDriverDialog extends ConsumerStatefulWidget {
  const CreateDriverDialog({this.editing, super.key});

  /// The chofer being edited, or null when opening a new account.
  final Driver? editing;

  @override
  ConsumerState<CreateDriverDialog> createState() => _CreateDriverDialogState();
}

class _CreateDriverDialogState extends ConsumerState<CreateDriverDialog> {
  final _formKey = GlobalKey<FormState>();

  final _name = TextEditingController();
  final _cedula = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _license = TextEditingController();
  final _company = TextEditingController();
  final _rnc = TextEditingController();
  final _zoneInput = TextEditingController();

  DateTime? _licenseExpiry;
  String? _truckId;
  final _zones = <String>[];

  PickedDocument? _licensePhoto;
  String? _photoError;

  PickedDocument? _avatar;
  String? _avatarError;

  var _submitting = false;
  String? _error;

  Driver? get _editing => widget.editing;
  bool get _isEdit => widget.editing != null;

  @override
  void initState() {
    super.initState();
    final driver = widget.editing;
    if (driver == null) return;

    // Through the same formatters a typed value goes through, so the fields
    // read "(809) 555-1234" rather than the stored "+18095551234".
    String formatted(TextInputFormatter formatter, String raw) => formatter
        .formatEditUpdate(TextEditingValue.empty, TextEditingValue(text: raw))
        .text;

    _name.text = driver.name;
    _cedula.text = formatted(CedulaInputFormatter(), driver.cedula);
    _phone.text = formatted(DoPhoneInputFormatter(), driver.phone);
    _email.text = driver.email;
    _license.text = driver.licenseNumber;
    _company.text = driver.companyName;
    _rnc.text = driver.rnc;
    _licenseExpiry = driver.licenseExpiry;
    _truckId = driver.assignedTruckId;
    _zones.addAll(driver.zones);
  }

  @override
  void dispose() {
    _name.dispose();
    _cedula.dispose();
    _phone.dispose();
    _email.dispose();
    _license.dispose();
    _company.dispose();
    _rnc.dispose();
    _zoneInput.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final trucks = ref.watch(allTrucksProvider).value ?? const <Truck>[];
    final zoneSuggestions = ref
            .watch(appSettingsProvider)
            .value
            ?.activeZones
            .map((z) => z.name)
            .toList() ??
        const <String>[];

    // A grúa with a chofer already on it would be reassigned by this form, so
    // the ones already spoken for are not offered — except this chofer's own.
    final ownTruckId = _editing?.assignedTruckId;
    final available = trucks
        .where(
          (t) =>
              t.id == ownTruckId ||
              (t.active && !t.archived && !t.isAssigned),
        )
        .toList()
      ..sort((a, b) => a.plate.compareTo(b.plate));
    // Until the fleet loads the chofer's own grúa is not in that list, and a
    // dropdown whose value matches no item throws.
    final ownMissing =
        ownTruckId != null && !available.any((t) => t.id == ownTruckId);

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
              title: _isEdit ? 'Editar chofer' : 'Nuevo chofer',
              subtitle: _isEdit
                  ? 'Los cambios se guardan en la cuenta del chofer.'
                  : 'La cuenta se crea inactiva hasta verificar los documentos.',
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
                      const FormSection('Identidad'),
                      LabeledField(
                        label: 'Foto del chofer',
                        required: !_isEdit,
                        help: 'JPG, PNG o WEBP con la cara visible. Máximo 5 MB.',
                        child: _AvatarPicker(
                          name: _editing?.name ?? '',
                          currentUrl: _editing?.photoUrl ?? '',
                          file: _avatar,
                          error: _avatarError,
                          onPick: _pickAvatar,
                          onClear: () => setState(() {
                            _avatar = null;
                            _avatarError = null;
                          }),
                        ),
                      ),
                      LabeledField(
                        label: 'Nombre completo',
                        required: true,
                        child: TextFormField(
                          controller: _name,
                          textCapitalization: TextCapitalization.words,
                          decoration: const InputDecoration(
                            hintText: 'Juan Alberto Pérez Núñez',
                          ),
                          validator: (value) {
                            final v = (value ?? '').trim();
                            if (v.length < 3) return 'Escribe el nombre completo.';
                            if (!v.contains(' ')) return 'Falta el apellido.';
                            return null;
                          },
                        ),
                      ),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: LabeledField(
                              label: 'Cédula',
                              required: true,
                              child: TextFormField(
                                controller: _cedula,
                                // Identity, not a detail: a wrong one is a
                                // new account, not an edit.
                                enabled: !_isEdit,
                                keyboardType: TextInputType.number,
                                inputFormatters: [CedulaInputFormatter()],
                                decoration: const InputDecoration(
                                  hintText: '001-1234567-8',
                                ),
                                // Not re-checked on an edit: an account opened
                                // before the check existed must stay editable.
                                validator: _isEdit ? null : DoValidators.cedula,
                              ),
                            ),
                          ),
                          const SizedBox(width: Insets.lg),
                          Expanded(
                            child: LabeledField(
                              label: 'Teléfono',
                              required: true,
                              child: TextFormField(
                                controller: _phone,
                                keyboardType: TextInputType.phone,
                                inputFormatters: [DoPhoneInputFormatter()],
                                decoration: const InputDecoration(
                                  hintText: '(809) 555-1234',
                                ),
                                validator: DoValidators.phone,
                              ),
                            ),
                          ),
                        ],
                      ),
                      LabeledField(
                        label: 'Correo electrónico',
                        required: true,
                        // Not on the paper form, but an Auth account cannot
                        // exist without one: this is what the chofer signs in
                        // with on the driver app.
                        help: 'Con este correo el chofer inicia sesión en la app.',
                        child: TextFormField(
                          controller: _email,
                          keyboardType: TextInputType.emailAddress,
                          decoration: const InputDecoration(
                            hintText: 'chofer@gruasrd.do',
                          ),
                          validator: (value) {
                            final v = (value ?? '').trim();
                            if (v.isEmpty) return 'Escribe un correo.';
                            if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]{2,}$')
                                .hasMatch(v)) {
                              return 'Ese correo no es válido.';
                            }
                            return null;
                          },
                        ),
                      ),
                      const SizedBox(height: Insets.sm),
                      const FormSection('Licencia'),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: LabeledField(
                              label: 'Licencia de conducir',
                              required: true,
                              child: TextFormField(
                                controller: _license,
                                decoration: const InputDecoration(
                                  hintText: 'Número de licencia',
                                ),
                                validator: (value) =>
                                    (value ?? '').trim().isEmpty
                                        ? 'Escribe el número de licencia.'
                                        : null,
                              ),
                            ),
                          ),
                          const SizedBox(width: Insets.lg),
                          Expanded(
                            child: LabeledField(
                              label: 'Vencimiento licencia',
                              required: true,
                              child: DateField(
                                value: _licenseExpiry,
                                onPick: _pickExpiry,
                              ),
                            ),
                          ),
                        ],
                      ),
                      LabeledField(
                        label: 'Foto de la licencia',
                        required: !_isEdit,
                        help: _isEdit
                            ? 'Solo si cambió la licencia. JPG, PNG o PDF. '
                                'Máximo 10 MB.'
                            : 'JPG, PNG o PDF. Máximo 10 MB.',
                        child: _PhotoPicker(
                          file: _licensePhoto,
                          error: _photoError,
                          onPick: _pickPhoto,
                          onClear: () => setState(() {
                            _licensePhoto = null;
                            _photoError = null;
                          }),
                        ),
                      ),
                      const SizedBox(height: Insets.sm),
                      const FormSection('Operación'),
                      LabeledField(
                        label: 'Grúa asignada',
                        help: available.isEmpty
                            ? 'No hay grúas libres. Puedes asignarla después.'
                            : 'Sin una grúa asignada el chofer no puede ponerse '
                                'en línea.',
                        child: DropdownButtonFormField<String?>(
                          initialValue: _truckId,
                          isExpanded: true,
                          decoration: const InputDecoration(),
                          hint: const Text('Sin asignar'),
                          items: [
                            const DropdownMenuItem(
                              child: Text('Sin asignar'),
                            ),
                            if (ownMissing)
                              DropdownMenuItem(
                                value: ownTruckId,
                                child: Text(
                                  '${_editing!.assignedTruckPlate} · '
                                  '${_editing!.truckType.label}',
                                ),
                              ),
                            for (final truck in available)
                              DropdownMenuItem(
                                value: truck.id,
                                child: Text(
                                  '${truck.displayPlate} · ${truck.type.label}',
                                ),
                              ),
                          ],
                          onChanged: (value) => setState(() => _truckId = value),
                        ),
                      ),
                      LabeledField(
                        label: 'Zona de cobertura',
                        help: 'Escribe una zona y presiona Enter. '
                            'Sin zonas, el chofer recibe servicios en toda la '
                            'cobertura.',
                        child: _ZoneField(
                          controller: _zoneInput,
                          zones: _zones,
                          suggestions: zoneSuggestions,
                          onAdd: _addZone,
                          onRemove: (zone) => setState(() => _zones.remove(zone)),
                        ),
                      ),
                      const SizedBox(height: Insets.sm),
                      const FormSection('Facturación'),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 3,
                            child: LabeledField(
                              label: 'Nombre de la empresa',
                              child: TextFormField(
                                controller: _company,
                                textCapitalization: TextCapitalization.words,
                                decoration: const InputDecoration(
                                  hintText: 'Solo si factura por su cuenta',
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: Insets.lg),
                          Expanded(
                            flex: 2,
                            child: LabeledField(
                              label: 'RNC',
                              child: TextFormField(
                                controller: _rnc,
                                keyboardType: TextInputType.number,
                                inputFormatters: [
                                  FilteringTextInputFormatter.digitsOnly,
                                  LengthLimitingTextInputFormatter(11),
                                ],
                                decoration: const InputDecoration(
                                  hintText: '9 u 11 dígitos',
                                ),
                                validator: DoValidators.rnc,
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
              label: _isEdit ? 'Guardar cambios' : 'Crear chofer',
              onCancel: () => Navigator.of(context).pop(),
              onSubmit: _submit,
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Field actions
  // ---------------------------------------------------------------------------

  Future<void> _pickExpiry() async {
    final now = DateTime.now();
    final current = _licenseExpiry;
    final picked = await showDatePicker(
      context: context,
      // An edited chofer's licence may already have lapsed, and the picker
      // throws on an initial date before its first one.
      initialDate: current != null && current.isAfter(now)
          ? current
          : now.add(const Duration(days: 365)),
      // An already-expired licence is not a chofer who can work, so the picker
      // does not offer one.
      firstDate: now,
      lastDate: DateTime(now.year + 15),
      helpText: 'Vencimiento de la licencia',
    );
    if (picked != null) setState(() => _licenseExpiry = picked);
  }

  Future<void> _pickPhoto() async {
    final picked = await ref.read(documentPickerProvider)();
    if (picked == null || !mounted) return;

    // Matches the 10 MB ceiling in storage.rules — better to say so here than
    // to have the upload refused after the account already exists.
    if (picked.bytes.lengthInBytes > 10 * 1024 * 1024) {
      setState(() {
        _licensePhoto = null;
        _photoError = 'El archivo pesa más de 10 MB.';
      });
      return;
    }

    setState(() {
      _photoError = null;
      _licensePhoto = picked;
    });
  }

  Future<void> _pickAvatar() async {
    final picked = await ref.read(avatarPickerProvider)();
    if (picked == null || !mounted) return;

    // Matches the 5 MB ceiling storage.rules puts on profile photos.
    if (picked.bytes.lengthInBytes > 5 * 1024 * 1024) {
      setState(() {
        _avatar = null;
        _avatarError = 'La foto pesa más de 5 MB.';
      });
      return;
    }

    setState(() {
      _avatarError = null;
      _avatar = picked;
    });
  }

  void _addZone(String raw) {
    final zone = raw.trim();
    if (zone.isEmpty) return;
    // Case-insensitive: "Naco" and "naco" are the same zone to a dispatcher.
    if (_zones.any((z) => z.toLowerCase() == zone.toLowerCase())) {
      _zoneInput.clear();
      return;
    }
    setState(() {
      _zones.add(zone);
      _zoneInput.clear();
    });
  }

  // ---------------------------------------------------------------------------
  // Submit
  // ---------------------------------------------------------------------------

  Future<void> _submit() async {
    final formOk = _formKey.currentState?.validate() ?? false;

    // On an edit both photos are already on file; a new one only replaces it.
    final needsPhotos = !_isEdit;

    // The date and the photos are not form fields, so they are checked here
    // and reported the same way a validator would.
    setState(() {
      _avatarError = needsPhotos && _avatar == null
          ? 'Agrega la foto del chofer.'
          : null;
      _photoError = needsPhotos && _licensePhoto == null
          ? 'Sube la foto de la licencia.'
          : null;
      _error = _licenseExpiry == null
          ? 'Escoge la fecha de vencimiento de la licencia.'
          : null;
    });
    if (!formOk ||
        _licenseExpiry == null ||
        (needsPhotos && (_licensePhoto == null || _avatar == null))) {
      return;
    }

    if (_isEdit) return await _save();

    setState(() {
      _submitting = true;
      _error = null;
    });

    final gateway = ref.read(functionsGatewayProvider);
    final created = await gateway.createDriver(
      NewDriver(
        name: _name.text.trim(),
        cedula: _cedula.text.replaceAll(RegExp(r'\D'), ''),
        phone: '+1${_phone.text.replaceAll(RegExp(r'\D'), '')}',
        email: _email.text.trim(),
        licenseNumber: _license.text.trim(),
        licenseExpiry: _licenseExpiry!,
        truckId: _truckId,
        zones: List.of(_zones),
        companyName: _company.text.trim(),
        rnc: _rnc.text.replaceAll(RegExp(r'\D'), ''),
      ),
    );

    if (!mounted) return;

    switch (created) {
      case Err(:final failure):
        setState(() {
          _submitting = false;
          _error = failure.userMessage;
        });
      case Ok(value: final driver):
        // The account exists from here on. A failed upload is worth telling the
        // office about, but it is not worth pretending the chofer was not
        // created — that would have them fill the form in again and hit the
        // duplicate-cédula refusal.
        final warnings = [
          await _uploadAvatar(driver.driverId),
          await _uploadLicensePhoto(driver.driverId),
        ].nonNulls;
        if (!mounted) return;

        // Held on to before the pop: this State is defunct the moment the
        // form closes, and the password still has to be shown from somewhere.
        await _closeAndShowPassword(
          Navigator.of(context),
          driver,
          warnings.isEmpty ? null : warnings.join('\n\n'),
        );
    }
  }

  /// Saves an edit, then any replacement photos, and closes the form.
  Future<void> _save() async {
    final driver = widget.editing!;
    setState(() {
      _submitting = true;
      _error = null;
    });

    final saved = await ref.read(functionsGatewayProvider).updateDriver(
          driver.id,
          DriverUpdate(
            name: _name.text.trim(),
            phone: '+1${DoValidators.digits(_phone.text)}',
            email: _email.text.trim(),
            licenseNumber: _license.text.trim(),
            licenseExpiry: _licenseExpiry!,
            truckId: _truckId,
            zones: List.of(_zones),
            companyName: _company.text.trim(),
            rnc: DoValidators.digits(_rnc.text),
          ),
        );
    if (!mounted) return;

    if (saved case Err(:final failure)) {
      setState(() {
        _submitting = false;
        _error = failure.userMessage;
      });
      return;
    }

    // The edits are saved from here on; a failed photo is reported, not
    // treated as the save failing.
    final avatarWarning = await _uploadAvatar(driver.id);
    final licenceWarning = await _uploadLicensePhoto(driver.id);
    if (!mounted) return;

    final warnings = [avatarWarning, licenceWarning].nonNulls;
    if (warnings.isNotEmpty) {
      // The form stays open, so "Guardar cambios" retries the photo without
      // picking it again. Saving the other fields a second time is harmless.
      setState(() {
        _submitting = false;
        // Whatever did go up is not sent again on the retry.
        if (avatarWarning == null) _avatar = null;
        if (licenceWarning == null) _licensePhoto = null;
        _error = 'Los datos se guardaron, pero:\n${warnings.join('\n')}';
      });
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop(true);
    messenger.showSnackBar(
      const SnackBar(content: Text('Cambios guardados.')),
    );
  }

  /// Closes the form and shows the temporary password on the navigator that
  /// outlives it.
  Future<void> _closeAndShowPassword(
    NavigatorState navigator,
    CreatedDriver driver,
    String? warning,
  ) {
    navigator.pop(driver.driverId);
    return showDialog<void>(
      context: navigator.context,
      builder: (context) => _CreatedDialog(driver: driver, warning: warning),
    );
  }

  /// Uploads the profile photo and sets it. Returns what went wrong, or null.
  Future<String?> _uploadAvatar(String driverId) async {
    final photo = _avatar;
    if (photo == null) return null;

    final upload = await ref.read(driverRepositoryProvider).uploadDriverPhoto(
          driverId: driverId,
          bytes: photo.bytes,
          contentType: photo.contentType,
        );

    final path = upload.valueOrNull;
    if (path == null) {
      return 'No se pudo subir la foto del chofer: '
          '${_reason(upload.failureOrNull)}';
    }

    final set = await ref
        .read(functionsGatewayProvider)
        .setDriverPhoto(driverId: driverId, storagePath: path);
    if (set.isErr) {
      return 'La foto del chofer se subió pero no quedó registrada: '
          '${_reason(set.failureOrNull)}';
    }
    return null;
  }

  /// Uploads the licence and records it. Returns what went wrong, or null.
  Future<String?> _uploadLicensePhoto(String driverId) async {
    final photo = _licensePhoto;
    if (photo == null) return null;

    final upload = await ref.read(driverRepositoryProvider).uploadDocument(
          driverId: driverId,
          type: DriverDocumentType.licencia,
          bytes: photo.bytes,
          fileName: photo.name,
          contentType: photo.contentType,
        );

    final path = upload.valueOrNull;
    if (path == null) {
      return 'No se pudo subir la foto de la licencia: '
          '${_reason(upload.failureOrNull)}';
    }

    final attached = await ref.read(functionsGatewayProvider).attachDriverDocument(
          driverId: driverId,
          type: DriverDocumentType.licencia,
          storagePath: path,
          fileName: photo.name,
          contentType: photo.contentType,
          sizeBytes: photo.bytes.lengthInBytes,
          expiresAt: _licenseExpiry,
        );

    if (attached.isErr) {
      return 'La foto de la licencia se subió pero no quedó registrada: '
          '${_reason(attached.failureOrNull)}';
    }
    return null;
  }

  /// Why an upload step failed, in the words the failure already carries — "it
  /// did not work" with no reason sends the office hunting in the console.
  static String _reason(Failure? failure) =>
      failure?.userMessage ?? 'error desconocido.';
}

// ---------------------------------------------------------------------------
// Result
// ---------------------------------------------------------------------------

/// Shown once, because the temporary password is never retrievable again.
class _CreatedDialog extends StatelessWidget {
  const _CreatedDialog({required this.driver, required this.warning});

  final CreatedDriver driver;
  final String? warning;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return AlertDialog(
      title: const Text('Chofer creado'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'La cuenta queda inactiva hasta que verifiques los documentos.',
              style: text.bodyMedium,
            ),
            const SizedBox(height: Insets.lg),
            const FieldLabel('CONTRASEÑA TEMPORAL'),
            const SizedBox(height: Insets.xs),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.md,
                vertical: Insets.sm,
              ),
              decoration: BoxDecoration(
                color: BrandColors.offWhite,
                borderRadius: Corners.brSm,
                border: Border.all(color: BrandColors.grey200),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      driver.temporaryPassword,
                      style: text.titleMedium?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copiar',
                    icon: const Icon(Icons.copy, size: 18),
                    onPressed: () => Clipboard.setData(
                      ClipboardData(text: driver.temporaryPassword),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Insets.sm),
            Text(
              'Léesela al chofer ahora: no se puede volver a ver. '
              'La app le pedirá cambiarla al entrar.',
              style: text.bodySmall?.copyWith(color: BrandColors.grey600),
            ),
            if (warning != null) ...[
              const SizedBox(height: Insets.lg),
              InlineNotice(
                message: warning!,
                icon: Icons.warning_amber_rounded,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Listo'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Pieces
// ---------------------------------------------------------------------------

/// A file chosen for upload, already read into memory.
class PickedDocument {
  const PickedDocument({
    required this.name,
    required this.bytes,
    required this.extension,
  });

  final String name;
  final Uint8List bytes;
  final String extension;

  bool get isPdf => extension == 'pdf';

  String get contentType => switch (extension) {
        'png' => 'image/png',
        'webp' => 'image/webp',
        'heic' => 'image/heic',
        'pdf' => 'application/pdf',
        _ => 'image/jpeg',
      };

  String get sizeLabel {
    final kb = bytes.lengthInBytes / 1024;
    return kb < 1024
        ? '${kb.toStringAsFixed(0)} KB'
        : '${(kb / 1024).toStringAsFixed(1)} MB';
  }
}

/// The chofer's face, previewed in the circle the roster will draw it in.
class _AvatarPicker extends StatelessWidget {
  const _AvatarPicker({
    required this.name,
    required this.currentUrl,
    required this.file,
    required this.error,
    required this.onPick,
    required this.onClear,
  });

  /// The chofer being edited, for the photo on file or its initials. Empty on
  /// a new account, which shows an empty circle instead.
  final String name;
  final String currentUrl;
  final PickedDocument? file;
  final String? error;
  final Future<void> Function() onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final picked = file;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (picked != null)
              DriverAvatar(name: name, bytes: picked.bytes, size: 64)
            else if (name.isNotEmpty)
              DriverAvatar(name: name, photoUrl: currentUrl, size: 64)
            else
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: BrandColors.offWhite,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: error != null ? BrandColors.danger : BrandColors.grey200,
                  ),
                ),
                child: const Icon(Icons.person_outline, color: BrandColors.grey400),
              ),
            const SizedBox(width: Insets.lg),
            if (picked == null)
              OutlinedButton.icon(
                onPressed: onPick,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 38),
                  padding: const EdgeInsets.symmetric(horizontal: Insets.md),
                ),
                icon: const Icon(Icons.add_a_photo_outlined, size: 18),
                label: Text(currentUrl.isEmpty ? 'Agregar foto' : 'Cambiar foto'),
              )
            else ...[
              TextButton(onPressed: onPick, child: const Text('Cambiar')),
              IconButton(
                tooltip: 'Quitar',
                onPressed: onClear,
                icon: const Icon(Icons.delete_outline, size: 18),
              ),
            ],
          ],
        ),
        if (error != null) ...[
          const SizedBox(height: Insets.xs),
          Text(
            error!,
            style: text.bodySmall?.copyWith(color: BrandColors.danger),
          ),
        ],
      ],
    );
  }
}

class _PhotoPicker extends StatelessWidget {
  const _PhotoPicker({
    required this.file,
    required this.error,
    required this.onPick,
    required this.onClear,
  });

  final PickedDocument? file;
  final String? error;
  final Future<void> Function() onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final picked = file;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(Insets.md),
          decoration: BoxDecoration(
            color: BrandColors.offWhite,
            borderRadius: Corners.brSm,
            border: Border.all(
              color: error != null ? BrandColors.danger : BrandColors.grey200,
            ),
          ),
          child: Row(
            children: [
              if (picked != null) ...[
                _Thumbnail(file: picked),
                const SizedBox(width: Insets.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        picked.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyMedium,
                      ),
                      Text(
                        picked.sizeLabel,
                        style: text.bodySmall
                            ?.copyWith(color: BrandColors.grey600),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Quitar',
                  onPressed: onClear,
                  icon: const Icon(Icons.delete_outline, size: 18),
                ),
                TextButton(onPressed: onPick, child: const Text('Cambiar')),
              ] else ...[
                const Icon(Icons.badge_outlined, size: 20, color: BrandColors.grey600),
                const SizedBox(width: Insets.md),
                Expanded(
                  child: Text(
                    'Ningún archivo seleccionado',
                    style: text.bodyMedium?.copyWith(color: BrandColors.grey600),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: onPick,
                  // The theme's buttons are the full-width ones from the phone
                  // mockups; inside a row they have to be told their own size.
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 38),
                    padding: const EdgeInsets.symmetric(horizontal: Insets.md),
                  ),
                  icon: const Icon(Icons.upload_file, size: 18),
                  label: const Text('Subir foto'),
                ),
              ],
            ],
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: Insets.xs),
          Text(
            error!,
            style: text.bodySmall?.copyWith(color: BrandColors.danger),
          ),
        ],
      ],
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.file});

  final PickedDocument file;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: Corners.brXs,
      child: SizedBox(
        width: 44,
        height: 44,
        child: file.isPdf
            ? Container(
                color: BrandColors.grey100,
                alignment: Alignment.center,
                child: const Icon(
                  Icons.picture_as_pdf,
                  size: 20,
                  color: BrandColors.grey600,
                ),
              )
            : Image.memory(
                file.bytes,
                fit: BoxFit.cover,
                // HEIC has no decoder on the web; the file still uploads fine.
                errorBuilder: (context, error, stack) => Container(
                  color: BrandColors.grey100,
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.image_outlined,
                    size: 20,
                    color: BrandColors.grey600,
                  ),
                ),
              ),
      ),
    );
  }
}

class _ZoneField extends StatelessWidget {
  const _ZoneField({
    required this.controller,
    required this.zones,
    required this.suggestions,
    required this.onAdd,
    required this.onRemove,
  });

  final TextEditingController controller;
  final List<String> zones;
  final List<String> suggestions;
  final ValueChanged<String> onAdd;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    final unused =
        suggestions.where((s) => !zones.any((z) => z.toLowerCase() == s.toLowerCase()));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: 'Santo Domingo Este, Naco…',
            suffixIcon: IconButton(
              icon: const Icon(Icons.add, size: 18),
              tooltip: 'Agregar zona',
              onPressed: () => onAdd(controller.text),
            ),
          ),
          onSubmitted: onAdd,
        ),
        if (zones.isNotEmpty) ...[
          const SizedBox(height: Insets.sm),
          Wrap(
            spacing: Insets.sm,
            runSpacing: Insets.xs,
            children: [
              for (final zone in zones)
                Chip(
                  label: Text(zone),
                  onDeleted: () => onRemove(zone),
                  deleteIcon: const Icon(Icons.close, size: 14),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: BrandColors.redTint,
                  side: const BorderSide(color: BrandColors.redTintStrong),
                ),
            ],
          ),
        ],
        if (unused.isNotEmpty) ...[
          const SizedBox(height: Insets.sm),
          Wrap(
            spacing: Insets.sm,
            runSpacing: Insets.xs,
            children: [
              for (final zone in unused)
                ActionChip(
                  label: Text(zone),
                  onPressed: () => onAdd(zone),
                  avatar: const Icon(Icons.add, size: 14),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ],
      ],
    );
  }
}
