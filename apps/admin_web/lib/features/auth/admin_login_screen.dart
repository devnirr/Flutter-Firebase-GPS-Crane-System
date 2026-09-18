import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

/// Panel sign-in.
///
/// Deliberately plain: this is a workstation login, not a storefront. The role
/// check happens after authentication — a valid account that is neither office
/// staff nor an insurance company's is signed straight back out rather than
/// shown an empty panel. Which of the two it is, the router decides.
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

  /// Set when the credentials were right but the account carries no staff
  /// claim. Offering the bootstrap only in that state keeps it out of the way
  /// of everybody who simply mistyped a password.
  var _offerBootstrap = false;

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

    if (!role.canUsePanel) {
      await auth.signOut();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Esta cuenta no tiene acceso al panel.';
        _offerBootstrap = true;
      });
      return;
    }

    setState(() => _busy = false);
  }

  /// Claims the admin role for the very first administrator.
  ///
  /// The server decides whether this is allowed: it refuses unless the
  /// account is on the `ADMIN_BOOTSTRAP_EMAILS` allowlist and no admin exists
  /// yet. Signing in again is what mints a token carrying the new claim.
  Future<void> _bootstrap() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    final auth = ref.read(authRepositoryProvider);
    final signedIn =
        await auth.signInWithEmail(_email.text.trim(), _password.text);
    if (!mounted) return;
    if (signedIn case Err(:final failure)) {
      setState(() {
        _busy = false;
        _error = failure.userMessage;
      });
      return;
    }

    final granted = await ref.read(functionsGatewayProvider).bootstrapFirstAdmin();
    if (!mounted) return;

    if (granted case Err(:final failure)) {
      await auth.signOut();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = failure.userMessage;
      });
      return;
    }

    // The claim only reaches the app in a freshly minted token.
    final role = await auth.currentRole(forceRefresh: true);
    if (!mounted) return;
    if (!role.isStaff) {
      await auth.signOut();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'El servidor no otorgó el acceso. Revisa ADMIN_BOOTSTRAP_EMAILS.';
      });
      return;
    }

    setState(() {
      _busy = false;
      _offerBootstrap = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;

    return Scaffold(
      backgroundColor: palette.sidebar,
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
                    'Panel de operaciones y aseguradoras',
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
                    if (_offerBootstrap) ...[
                      const SizedBox(height: Insets.md),
                      TextButton(
                        onPressed: _busy ? null : _bootstrap,
                        child: const Text('Soy el primer administrador'),
                      ),
                    ],
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
