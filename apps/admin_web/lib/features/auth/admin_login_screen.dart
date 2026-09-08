import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

/// Panel sign-in.
///
/// Deliberately plain: this is a workstation login, not a storefront. The role
/// check happens after authentication — a valid account without an admin claim
/// is signed straight back out rather than shown an empty panel.
class AdminLoginScreen extends ConsumerStatefulWidget {
  const AdminLoginScreen({super.key});

  @override
  ConsumerState<AdminLoginScreen> createState() => _AdminLoginScreenState();
}

class _AdminLoginScreenState extends ConsumerState<AdminLoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (!(_formKey.currentState?.validate() ?? false) || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    final auth = ref.read(authRepositoryProvider);
    final result = await auth.signInWithEmail(_email.text.trim(), _password.text);
    if (!mounted) return;

    if (result case Err(:final failure)) {
      setState(() {
        _busy = false;
        _error = failure.userMessage;
      });
      return;
    }

    final role = await auth.currentRole(forceRefresh: true);
    if (!mounted) return;

    if (!role.isStaff) {
      await auth.signOut();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Esta cuenta no tiene acceso al panel.';
      });
      return;
    }

    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: BrandColors.sidebar,
      body: Center(
        child: SizedBox(
          width: 380,
          child: FloatingCard(
            padding: const EdgeInsets.all(Insets.xxxl),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Center(child: GruaLogo(size: 108)),
                  const SizedBox(height: Insets.xl),
                  Text(
                    'Panel de operaciones',
                    textAlign: TextAlign.center,
                    style: text.titleLarge,
                  ),
                  const SizedBox(height: Insets.xxl),
                  TextFormField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(labelText: 'Correo'),
                    validator: (v) =>
                        (v?.trim().isEmpty ?? true) ? 'Requerido' : null,
                  ),
                  const SizedBox(height: Insets.md),
                  TextFormField(
                    controller: _password,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Contraseña'),
                    onFieldSubmitted: (_) => _signIn(),
                    validator: (v) => (v?.isEmpty ?? true) ? 'Requerido' : null,
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: Insets.lg),
                    InlineNotice(message: _error!, tone: NoticeTone.error),
                  ],
                  const SizedBox(height: Insets.xl),
                  ElevatedButton(
                    onPressed: _busy ? null : _signIn,
                    child: _busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.2,
                              color: BrandColors.white,
                            ),
                          )
                        : const Text('Entrar'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
