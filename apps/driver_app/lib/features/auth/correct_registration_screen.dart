import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

import 'license_upload.dart';

/// Opens the form where a rejected chofer fixes what they typed.
Future<void> showCorrectRegistration(BuildContext context, Driver driver) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => CorrectRegistrationScreen(driver: driver),
      ),
    );

/// The details the licence check compares with the card, editable while the
/// check is waiting on the chofer.
///
/// Beside each field sits what the check read off the card, when it differs,
/// so a typo is visible rather than guessed at. Saving checks the photos
/// already uploaded again — no new photos needed for a typo.
class CorrectRegistrationScreen extends ConsumerStatefulWidget {
  const CorrectRegistrationScreen({required this.driver, super.key});

  final Driver driver;

  @override
  ConsumerState<CorrectRegistrationScreen> createState() =>
      _CorrectRegistrationScreenState();
}

class _CorrectRegistrationScreenState
    extends ConsumerState<CorrectRegistrationScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.driver.name);
  late final _cedula =
      TextEditingController(text: widget.driver.displayCedula);
  late final _license =
      TextEditingController(text: widget.driver.licenseNumber);
  late DateTime? _expiry = widget.driver.licenseExpiry;
  String? _expiryError;
  String? _error;
  var _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _cedula.dispose();
    _license.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final read = widget.driver.licenseVerification?.extracted;

    return Scaffold(
      backgroundColor: BrandColors.white,
      appBar: AppBar(title: const Text('Corregir mis datos')),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Insets.gutter),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Escribe tus datos tal como aparecen en tu licencia. Al '
                  'guardar, verificamos de nuevo las fotos que ya subiste.',
                  style: text.bodyLarge?.copyWith(color: BrandColors.grey600),
                ),
                const SizedBox(height: Insets.xl),
                _Labeled(
                  label: 'NOMBRE COMPLETO',
                  onCard: read?.fullName,
                  matches: _sameName,
                  controller: _name,
                  child: TextFormField(
                    controller: _name,
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.next,
                    onChanged: (_) => setState(() {}),
                    validator: (value) {
                      final v = (value ?? '').trim();
                      if (v.length < 3) return 'Escribe tu nombre completo.';
                      if (!v.contains(' ')) return 'Falta el apellido.';
                      return null;
                    },
                  ),
                ),
                _Labeled(
                  label: 'CÉDULA',
                  onCard: read?.cedula,
                  matches: _sameDigits,
                  controller: _cedula,
                  child: TextFormField(
                    controller: _cedula,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.next,
                    inputFormatters: [CedulaInputFormatter()],
                    onChanged: (_) => setState(() {}),
                    decoration:
                        const InputDecoration(hintText: '001-1234567-8'),
                    validator: DoValidators.cedula,
                  ),
                ),
                _Labeled(
                  label: 'NÚMERO DE LICENCIA',
                  onCard: read?.licenseNumber,
                  matches: _sameDigits,
                  controller: _license,
                  child: TextFormField(
                    controller: _license,
                    textCapitalization: TextCapitalization.characters,
                    textInputAction: TextInputAction.done,
                    onChanged: (_) => setState(() {}),
                    validator: (value) => (value ?? '').trim().isEmpty
                        ? 'Escribe el número de licencia.'
                        : null,
                  ),
                ),
                const FieldLabel('VENCIMIENTO DE LA LICENCIA *'),
                const SizedBox(height: Insets.sm),
                InkWell(
                  onTap: _pickExpiry,
                  borderRadius: Corners.brMd,
                  child: InputDecorator(
                    decoration: InputDecoration(
                      suffixIcon:
                          const Icon(Icons.calendar_today_outlined, size: 20),
                      errorText: _expiryError,
                    ),
                    child: Text(
                      _expiry == null
                          ? 'dd/mm/aaaa'
                          : DoTime.fullDate(_expiry!),
                      style: text.bodyLarge,
                    ),
                  ),
                ),
                if (read != null && read.expiryDate.isNotEmpty) ...[
                  const SizedBox(height: Insets.xs),
                  Text(
                    'En tu licencia: ${read.expiryDate}',
                    style: text.bodySmall?.copyWith(color: BrandColors.grey600),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: Insets.lg),
                  InlineNotice(message: _error!, tone: NoticeTone.error),
                ],
                const SizedBox(height: Insets.xl),
                ElevatedButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.4,
                            color: BrandColors.white,
                          ),
                        )
                      : const Text('GUARDAR Y VERIFICAR'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _digits(String v) => v.replaceAll(RegExp(r'\D'), '');

  static bool _sameDigits(String typed, String card) =>
      _digits(card).isEmpty || _digits(typed) == _digits(card);

  static bool _sameName(String typed, String card) {
    String fold(String v) => v
        .toUpperCase()
        .replaceAll(RegExp('[ÁÀÄ]'), 'A')
        .replaceAll(RegExp('[ÉÈË]'), 'E')
        .replaceAll(RegExp('[ÍÌÏ]'), 'I')
        .replaceAll(RegExp('[ÓÒÖ]'), 'O')
        .replaceAll(RegExp('[ÚÙÜ]'), 'U')
        .replaceAll('Ñ', 'N')
        .trim();
    final have = fold(card).split(RegExp(r'\s+')).toSet();
    return card.trim().isEmpty ||
        fold(typed).split(RegExp(r'\s+')).every(have.contains);
  }

  Future<void> _pickExpiry() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _expiry != null && _expiry!.isAfter(now)
          ? _expiry!
          : now.add(const Duration(days: 365)),
      firstDate: now,
      lastDate: DateTime(now.year + 15),
      helpText: 'Vencimiento de la licencia',
    );
    if (picked != null) {
      setState(() {
        _expiry = picked;
        _expiryError = null;
      });
    }
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    final formOk = _formKey.currentState?.validate() ?? false;
    final expiry = _expiry;
    setState(() {
      _expiryError = expiry == null ? 'Escoge la fecha de vencimiento.' : null;
      _error = null;
    });
    if (!formOk || expiry == null) return;

    setState(() => _saving = true);
    final gateway = ref.read(functionsGatewayProvider);
    final submitting = ref.read(licenseSubmittingProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);

    final saved = await gateway.correctDriverRegistration(
      name: _name.text.trim(),
      cedula: DoValidators.digits(_cedula.text),
      licenseNumber: _license.text.trim(),
      licenseExpiry: expiry,
    );
    if (!mounted) return;
    if (saved.isErr) {
      setState(() {
        _saving = false;
        _error = saved.failureOrNull?.userMessage ??
            'No pudimos guardar tus datos. Inténtalo de nuevo.';
      });
      return;
    }

    // Back to the waiting screen, which shows the check running against the
    // photos already uploaded.
    Navigator.of(context).pop();
    submitting.set(busy: true);
    final checked = await gateway.verifyDriverLicense();
    submitting.set(busy: false);
    if (checked.isErr) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            checked.failureOrNull?.userMessage ??
                'No pudimos verificar tu licencia. Inténtalo de nuevo.',
          ),
        ),
      );
    }
  }
}

/// A field with its label, and what the card says when that differs.
class _Labeled extends StatelessWidget {
  const _Labeled({
    required this.label,
    required this.onCard,
    required this.matches,
    required this.controller,
    required this.child,
  });

  final String label;
  final String? onCard;
  final bool Function(String typed, String card) matches;
  final TextEditingController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final card = onCard ?? '';
    final differs = card.isNotEmpty && !matches(controller.text, card);

    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FieldLabel('$label *'),
          const SizedBox(height: Insets.sm),
          child,
          if (differs) ...[
            const SizedBox(height: Insets.xs),
            Text(
              'En tu licencia: $card',
              style: text.bodySmall?.copyWith(color: BrandColors.danger),
            ),
          ],
        ],
      ),
    );
  }
}
