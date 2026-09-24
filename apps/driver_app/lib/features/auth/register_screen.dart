import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';
import 'license_upload.dart';

/// Chofer self-registration.
///
/// The same papers the office copies into "Nuevo chofer" — identity, licence,
/// billing — minus the grúa and the coverage zones, which are the office's to
/// assign, plus a password, since nobody is reading a temporary one out.
///
/// Submitting opens an `inactive` account and signs the chofer in. The router
/// then shows the waiting screen while the licence photos are checked, and
/// nothing works until the office has activated the account.
class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _cedula = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _license = TextEditingController();
  final _company = TextEditingController();
  final _rnc = TextEditingController();

  var _obscure = true;
  DateTime? _licenseExpiry;
  String? _expiryError;
  PickedPhoto? _licenseFront;
  String? _frontError;
  PickedPhoto? _licenseBack;
  String? _backError;
  PickedPhoto? _avatar;
  String? _avatarError;

  var _submitting = false;
  String? _error;

  @override
  void dispose() {
    for (final controller in [
      _name,
      _cedula,
      _phone,
      _email,
      _password,
      _confirm,
      _license,
      _company,
      _rnc,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: BrandColors.white,
      appBar: AppBar(
        leading: BackButton(onPressed: _submitting ? null : _back),
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          // A Column rather than a ListView: every field stays built, so the
          // validator of one scrolled out of view still runs on submit.
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              Insets.gutter,
              0,
              Insets.gutter,
              Insets.xxl,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(child: GruaLogo(size: 120)),
                const SizedBox(height: Insets.lg),
                Text('Registro de chofer', style: text.headlineMedium),
                const SizedBox(height: Insets.sm),
                Text(
                  'Completa tus datos. La oficina verificará tus documentos '
                  'antes de activar tu cuenta.',
                  style: text.bodyLarge?.copyWith(color: BrandColors.grey600),
                ),
                const SizedBox(height: Insets.xxl),

                const _Section('Datos personales'),
                _Field(
                  label: 'Foto de perfil',
                  help: 'Una foto de tu cara, sin lentes oscuros. El cliente '
                      'la ve mientras vas en camino.',
                  child: _AvatarField(
                    photo: _avatar,
                    error: _avatarError,
                    onPick: _pickAvatar,
                    onClear: () => setState(() => _avatar = null),
                  ),
                ),
                _Field(
                  label: 'Nombre completo',
                  child: TextFormField(
                    controller: _name,
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      hintText: 'Juan Alberto Pérez Núñez',
                    ),
                    validator: (value) {
                      final v = (value ?? '').trim();
                      if (v.length < 3) return 'Escribe tu nombre completo.';
                      if (!v.contains(' ')) return 'Falta el apellido.';
                      return null;
                    },
                  ),
                ),
                _Field(
                  label: 'Cédula',
                  child: TextFormField(
                    controller: _cedula,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.next,
                    inputFormatters: [CedulaInputFormatter()],
                    decoration: const InputDecoration(
                      hintText: '001-1234567-8',
                    ),
                    validator: DoValidators.cedula,
                  ),
                ),
                _Field(
                  label: 'Teléfono',
                  child: TextFormField(
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    textInputAction: TextInputAction.next,
                    inputFormatters: [DoPhoneInputFormatter()],
                    decoration: const InputDecoration(
                      hintText: '(809) 555-1234',
                    ),
                    validator: DoValidators.phone,
                  ),
                ),
                _Field(
                  label: 'Correo electrónico',
                  help: 'Con este correo entras a la app.',
                  child: TextFormField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      hintText: 'tucorreo@ejemplo.com',
                    ),
                    validator: DoValidators.email,
                  ),
                ),

                const _Section('Contraseña'),
                _Field(
                  label: 'Contraseña',
                  child: TextFormField(
                    controller: _password,
                    obscureText: _obscure,
                    enableSuggestions: false,
                    autocorrect: false,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      hintText: 'Mínimo 8 caracteres',
                      suffixIcon: IconButton(
                        tooltip: _obscure ? 'Mostrar' : 'Ocultar',
                        onPressed: () => setState(() => _obscure = !_obscure),
                        icon: Icon(
                          _obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          color: BrandColors.grey400,
                        ),
                      ),
                    ),
                    validator: (value) => (value ?? '').length < 8
                        ? 'Usa al menos 8 caracteres.'
                        : null,
                  ),
                ),
                _Field(
                  label: 'Confirmar contraseña',
                  child: TextFormField(
                    controller: _confirm,
                    obscureText: _obscure,
                    enableSuggestions: false,
                    autocorrect: false,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      hintText: 'Repite la contraseña',
                    ),
                    validator: (value) => value != _password.text
                        ? 'Las contraseñas no coinciden.'
                        : null,
                  ),
                ),

                const _Section('Licencia de conducir'),
                _Field(
                  label: 'Número de licencia',
                  child: TextFormField(
                    controller: _license,
                    textCapitalization: TextCapitalization.characters,
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(
                      hintText: 'Como aparece en la licencia',
                    ),
                    validator: (value) => (value ?? '').trim().isEmpty
                        ? 'Escribe el número de licencia.'
                        : null,
                  ),
                ),
                _Field(
                  label: 'Vencimiento de la licencia',
                  child: _DateField(
                    value: _licenseExpiry,
                    error: _expiryError,
                    onPick: _pickExpiry,
                  ),
                ),
                _Field(
                  label: 'Licencia (frente)',
                  help: 'Una foto clara del frente. Máximo 10 MB.',
                  child: LicensePhotoField(
                    photo: _licenseFront,
                    error: _frontError,
                    onPick: () => _pickLicense(back: false),
                    onClear: () => setState(() => _licenseFront = null),
                  ),
                ),
                _Field(
                  label: 'Licencia (reverso)',
                  help: 'Una foto clara de la parte de atrás. Máximo 10 MB.',
                  child: LicensePhotoField(
                    photo: _licenseBack,
                    error: _backError,
                    onPick: () => _pickLicense(back: true),
                    onClear: () => setState(() => _licenseBack = null),
                  ),
                ),

                const _Section('Facturación (opcional)'),
                _Field(
                  label: 'Nombre de la empresa',
                  required: false,
                  child: TextFormField(
                    controller: _company,
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      hintText: 'Solo si facturas por tu cuenta',
                    ),
                  ),
                ),
                _Field(
                  label: 'RNC',
                  required: false,
                  child: TextFormField(
                    controller: _rnc,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
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

                if (_error != null) ...[
                  InlineNotice(message: _error!, tone: NoticeTone.error),
                  const SizedBox(height: Insets.lg),
                ],
                const SizedBox(height: Insets.sm),
                ElevatedButton(
                  onPressed: _submitting ? null : _submit,
                  child: _submitting
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.4,
                            color: BrandColors.white,
                          ),
                        )
                      : const Text('ENVIAR REGISTRO'),
                ),
                const SizedBox(height: Insets.md),
                Center(
                  child: TextButton(
                    onPressed: _submitting ? null : _back,
                    child: const Text('Ya tengo cuenta'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _back() =>
      context.canPop() ? context.pop() : context.go(Routes.login);

  // ---------------------------------------------------------------------------
  // Field actions
  // ---------------------------------------------------------------------------

  Future<void> _pickExpiry() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _licenseExpiry ?? now.add(const Duration(days: 365)),
      // An expired licence is not a chofer who can work, and the server
      // refuses one, so the picker does not offer it.
      firstDate: now,
      lastDate: DateTime(now.year + 15),
      helpText: 'Vencimiento de la licencia',
    );
    if (picked != null) {
      setState(() {
        _licenseExpiry = picked;
        _expiryError = null;
      });
    }
  }

  Future<void> _pickAvatar() async {
    final picked = await choosePhoto(context, ref);
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
      _avatar = picked;
      _avatarError = null;
    });
  }

  /// Picks one side of the licence.
  Future<void> _pickLicense({required bool back}) async {
    final picked = await choosePhoto(context, ref);
    if (picked == null || !mounted) return;

    final error = licensePhotoTooBig(picked);
    final photo = error == null ? picked : null;
    setState(() {
      if (back) {
        _licenseBack = photo;
        _backError = error;
      } else {
        _licenseFront = photo;
        _frontError = error;
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Submit
  // ---------------------------------------------------------------------------

  Future<void> _submit() async {
    if (_submitting) return;
    FocusScope.of(context).unfocus();

    final formOk = _formKey.currentState?.validate() ?? false;
    // The date and the photos are not form fields, so they are checked here and
    // reported the way a validator would.
    setState(() {
      _expiryError = _licenseExpiry == null
          ? 'Escoge la fecha de vencimiento.'
          : null;
      _frontError =
          _licenseFront == null ? 'Sube el frente de la licencia.' : null;
      _backError =
          _licenseBack == null ? 'Sube el reverso de la licencia.' : null;
      _avatarError = _avatar == null ? 'Agrega tu foto de perfil.' : null;
      _error = null;
    });

    final expiry = _licenseExpiry;
    final front = _licenseFront;
    final back = _licenseBack;
    final avatar = _avatar;
    if (!formOk ||
        expiry == null ||
        front == null ||
        back == null ||
        avatar == null) {
      return;
    }

    setState(() => _submitting = true);

    // Read before the first await. Once the chofer is signed in the router
    // moves them on and this State is disposed, but the licence upload still
    // has to finish — so nothing after the sign-in may touch `ref`.
    final gateway = ref.read(functionsGatewayProvider);
    final auth = ref.read(authRepositoryProvider);
    final drivers = ref.read(driverRepositoryProvider);
    final submitting = ref.read(licenseSubmittingProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);

    final email = _email.text.trim();
    final password = _password.text;

    final registered = await gateway.registerDriver(
      DriverSignUp(
        name: _name.text.trim(),
        cedula: DoValidators.digits(_cedula.text),
        phone: '+1${DoValidators.digits(_phone.text)}',
        email: email,
        password: password,
        licenseNumber: _license.text.trim(),
        licenseExpiry: expiry,
        companyName: _company.text.trim(),
        rnc: DoValidators.digits(_rnc.text),
      ),
    );

    final driverId = registered.valueOrNull;
    if (driverId == null) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = registered.failureOrNull?.userMessage;
        });
      }
      return;
    }

    // Up before the sign-in, so the waiting screen the router opens next
    // says "sending" rather than asking for photos already on their way.
    submitting.set(busy: true);
    final signedIn = await auth.signInWithEmail(email, password);
    if (signedIn.isErr) {
      submitting.set(busy: false);
      // The account exists, so sending the form again would only hit the
      // duplicate-cédula refusal. Point the chofer at the sign-in screen.
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = 'Tu cuenta fue creada, pero no pudimos iniciar sesión. '
              'Entra con tu correo y contraseña.';
        });
      }
      return;
    }

    // The avatar first: the licence check compares the face on the card
    // with it.
    final warnings = [
      await _attachAvatar(
        drivers: drivers,
        gateway: gateway,
        driverId: driverId,
        photo: avatar,
      ),
      await submitLicense(
        drivers: drivers,
        gateway: gateway,
        submitting: submitting,
        driverId: driverId,
        front: front,
        back: back,
        expiry: expiry,
      ),
    ].nonNulls;
    if (warnings.isNotEmpty) {
      messenger.showSnackBar(SnackBar(content: Text(warnings.join('\n'))));
    }
  }
}

/// Uploads the profile photo and sets it on the new account. Returns what went
/// wrong, or null. Like the licence, a failure does not undo the registration.
Future<String?> _attachAvatar({
  required DriverRepository drivers,
  required FunctionsGateway gateway,
  required String driverId,
  required PickedPhoto photo,
}) async {
  final upload = await drivers.uploadDriverPhoto(
    driverId: driverId,
    bytes: photo.bytes,
    contentType: photo.contentType,
  );

  final path = upload.valueOrNull;
  if (path == null) {
    return 'Tu cuenta fue creada, pero tu foto no se subió. '
        'La oficina te la pedirá.';
  }

  final set = await gateway.setDriverPhoto(driverId: driverId, storagePath: path);
  if (set.isErr) {
    return 'Tu cuenta fue creada, pero tu foto no quedó registrada. '
        'La oficina te la pedirá.';
  }
  return null;
}

// ---------------------------------------------------------------------------
// Pieces
// ---------------------------------------------------------------------------

class _Section extends StatelessWidget {
  const _Section(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: Insets.sm, bottom: Insets.lg),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    );
  }
}

/// One labelled field with its asterisk and the note under it.
class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.child,
    this.required = true,
    this.help,
  });

  final String label;
  final Widget child;
  final bool required;
  final String? help;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FieldLabel(required ? '$label *' : label),
          const SizedBox(height: Insets.sm),
          child,
          if (help != null) ...[
            const SizedBox(height: Insets.xs),
            Text(
              help!,
              style: text.bodySmall?.copyWith(color: BrandColors.grey600),
            ),
          ],
        ],
      ),
    );
  }
}

class _DateField extends StatelessWidget {
  const _DateField({
    required this.value,
    required this.error,
    required this.onPick,
  });

  final DateTime? value;
  final String? error;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final expiry = value;

    return InkWell(
      onTap: onPick,
      borderRadius: Corners.brMd,
      child: InputDecorator(
        decoration: InputDecoration(
          suffixIcon: const Icon(Icons.calendar_today_outlined, size: 20),
          errorText: error,
        ),
        child: Text(
          expiry == null ? 'dd/mm/aaaa' : DoTime.fullDate(expiry),
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: expiry == null ? BrandColors.grey400 : BrandColors.ink,
              ),
        ),
      ),
    );
  }
}

/// The profile photo, previewed in the circle the office and the customer see.
class _AvatarField extends StatelessWidget {
  const _AvatarField({
    required this.photo,
    required this.error,
    required this.onPick,
    required this.onClear,
  });

  final PickedPhoto? photo;
  final String? error;
  final VoidCallback onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final picked = photo;

    return Column(
      children: [
        InkWell(
          onTap: onPick,
          customBorder: const CircleBorder(),
          child: picked != null
              ? DriverAvatar(name: '', bytes: picked.bytes, size: 104)
              : Container(
                  width: 104,
                  height: 104,
                  decoration: BoxDecoration(
                    color: BrandColors.offWhite,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: error != null ? BrandColors.danger : BrandColors.grey200,
                      width: 1.5,
                    ),
                  ),
                  child: const Icon(
                    Icons.add_a_photo_outlined,
                    size: 32,
                    color: BrandColors.grey400,
                  ),
                ),
        ),
        const SizedBox(height: Insets.sm),
        if (picked == null)
          OutlinedButton.icon(
            onPressed: onPick,
            // The theme's buttons are full width; this one sits under a circle.
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 40),
              padding: const EdgeInsets.symmetric(horizontal: Insets.md),
            ),
            icon: const Icon(Icons.photo_camera_outlined, size: 18),
            label: const Text('Agregar foto'),
          )
        else
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(onPressed: onPick, child: const Text('Cambiar foto')),
              TextButton(onPressed: onClear, child: const Text('Quitar')),
            ],
          ),
        if (error != null) ...[
          const SizedBox(height: Insets.xs),
          Text(
            error!,
            textAlign: TextAlign.center,
            style: text.bodySmall?.copyWith(color: BrandColors.danger),
          ),
        ],
      ],
    );
  }
}
