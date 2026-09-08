import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

/// Chofer sign-in.
///
/// Red ground, the mark, two fields and a black button, as in the mockup.
/// There is no "create account" link and no route behind one: accounts come
/// from the admin panel, with documents verified before the chofer can work.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();

  var _obscure = true;
  var _signingIn = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (!(_formKey.currentState?.validate() ?? false) || _signingIn) return;

    setState(() {
      _signingIn = true;
      _error = null;
    });

    final result = await ref.read(authRepositoryProvider).signInWithEmail(
          _email.text.trim(),
          _password.text,
        );
    if (!mounted) return;

    result.fold(
      // The router takes over once the auth stream emits.
      (_) => setState(() => _signingIn = false),
      (failure) => setState(() {
        _signingIn = false;
        _error = failure.userMessage;
      }),
    );
  }

  Future<void> _forgotPassword() async {
    final email = _email.text.trim();
    if (email.isEmpty) {
      setState(() => _error = 'Escribe tu usuario primero.');
      return;
    }
    await ref.read(authRepositoryProvider).sendPasswordReset(email);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Si el usuario existe, te enviamos instrucciones.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: BrandColors.red,
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [BrandColors.redBright, BrandColors.redDark],
          ),
        ),
        child: SafeArea(
          child: Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: Insets.xxl),
              children: [
                const SizedBox(height: Insets.huge),
                const Center(
                  child: GruaLogo(size: 150, variant: GruaLogoVariant.onDark),
                ),
                const SizedBox(height: Insets.xxl),
                Text(
                  'ACCESO CHOFER',
                  textAlign: TextAlign.center,
                  style: text.headlineMedium?.copyWith(
                    color: BrandColors.white,
                    letterSpacing: 1.4,
                  ),
                ),
                const SizedBox(height: Insets.huge),

                _WhiteField(
                  controller: _email,
                  hint: 'Usuario',
                  icon: Icons.person_outline,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  validator: (v) => (v?.trim().isEmpty ?? true)
                      ? 'Escribe tu usuario.'
                      : null,
                ),
                const SizedBox(height: Insets.lg),
                _WhiteField(
                  controller: _password,
                  hint: 'Contraseña',
                  icon: Icons.lock_outline,
                  obscure: _obscure,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _signIn(),
                  suffix: IconButton(
                    onPressed: () => setState(() => _obscure = !_obscure),
                    icon: Icon(
                      _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                      color: BrandColors.grey400,
                    ),
                  ),
                  validator: (v) => (v?.isEmpty ?? true)
                      ? 'Escribe tu contraseña.'
                      : null,
                ),

                if (_error != null) ...[
                  const SizedBox(height: Insets.lg),
                  InlineNotice(message: _error!, tone: NoticeTone.error),
                ],

                const SizedBox(height: Insets.xxl),
                ElevatedButton(
                  onPressed: _signingIn ? null : _signIn,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: BrandColors.ink,
                    foregroundColor: BrandColors.white,
                    minimumSize: const Size.fromHeight(58),
                    shape: const RoundedRectangleBorder(
                      borderRadius: Corners.brLg,
                    ),
                  ),
                  child: _signingIn
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.4,
                            color: BrandColors.white,
                          ),
                        )
                      : const Text('ENTRAR'),
                ),
                const SizedBox(height: Insets.md),
                TextButton(
                  onPressed: _signingIn ? null : _forgotPassword,
                  style: TextButton.styleFrom(foregroundColor: BrandColors.white),
                  child: const Text('Olvidé mi contraseña'),
                ),

                const SizedBox(height: Insets.xxl),
                Text(
                  'Las cuentas de chofer las crea la oficina. Si no puedes '
                  'entrar, comunícate con administración.',
                  textAlign: TextAlign.center,
                  style: text.bodySmall?.copyWith(color: Colors.white70),
                ),
                const SizedBox(height: Insets.xxl),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The white rounded field from the mockup, on the red ground.
class _WhiteField extends StatelessWidget {
  const _WhiteField({
    required this.controller,
    required this.hint,
    required this.icon,
    this.obscure = false,
    this.suffix,
    this.keyboardType,
    this.textInputAction,
    this.onSubmitted,
    this.validator,
  });

  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final bool obscure;
  final Widget? suffix;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final FormFieldValidator<String>? validator;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      onFieldSubmitted: onSubmitted,
      validator: validator,
      autocorrect: false,
      enableSuggestions: !obscure,
      style: Theme.of(context).textTheme.titleMedium,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: Icon(icon, color: BrandColors.grey400),
        suffixIcon: suffix,
        filled: true,
        fillColor: BrandColors.white,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Insets.lg,
          vertical: Insets.xl,
        ),
        border: const OutlineInputBorder(
          borderRadius: Corners.brLg,
          borderSide: BorderSide.none,
        ),
        enabledBorder: const OutlineInputBorder(
          borderRadius: Corners.brLg,
          borderSide: BorderSide.none,
        ),
        focusedBorder: const OutlineInputBorder(
          borderRadius: Corners.brLg,
          borderSide: BorderSide(color: BrandColors.ink, width: 1.8),
        ),
        errorStyle: const TextStyle(
          color: BrandColors.white,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
