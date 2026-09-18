import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';
import '../shared/toast.dart';
import 'portal_shell.dart';

/// Choosing one's own password.
///
/// An account the office (or the company's manager) opened comes with a
/// password somebody else has seen, so the portal sends the person here
/// before anything else and keeps them here until they have changed it.
class ChangePasswordScreen extends ConsumerStatefulWidget {
  const ChangePasswordScreen({super.key});

  static const minLength = 8;

  @override
  ConsumerState<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends ConsumerState<ChangePasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _repeat = TextEditingController();
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _repeat.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy || !(_formKey.currentState?.validate() ?? false)) return;
    final member = ref.read(myInsurerMemberProvider).value;
    if (member == null) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    final auth = ref.read(authRepositoryProvider);

    // Signing in again proves the current password, and gives Firebase the
    // recent sign-in it insists on before a password change.
    final proved = await auth.signInWithEmail(member.email, _current.text);
    if (!mounted) return;
    if (proved case Err(:final failure)) {
      setState(() {
        _busy = false;
        // A wrong password says so; a network problem or too many tries says
        // what it is.
        _error = failure.code == FailureCode.invalidInput &&
                (failure.message ?? '').contains('contraseña')
            ? 'La contraseña actual no es correcta.'
            : failure.userMessage;
      });
      return;
    }

    final changed = await auth.changePassword(_next.text);
    if (!mounted) return;
    if (changed case Err(:final failure)) {
      setState(() {
        _busy = false;
        _error = failure.userMessage;
      });
      return;
    }

    // The password has changed whatever this answers; a failure only leaves
    // the reminder up. Tried a few times before saying so.
    final gateway = ref.read(functionsGatewayProvider);
    var cleared = await gateway.insurerPasswordChanged();
    for (var attempt = 1; attempt < 3 && cleared.isErr; attempt++) {
      await Future<void>.delayed(Duration(seconds: attempt));
      cleared = await gateway.insurerPasswordChanged();
    }
    if (!mounted) return;
    setState(() => _busy = false);
    _current.clear();
    _next.clear();
    _repeat.clear();
    showToast(
      context,
      cleared.isOk
          ? 'Contraseña actualizada.'
          : 'Tu contraseña nueva ya quedó guardada. Si el portal vuelve a '
              'pedirte cambiarla, escribe la nueva como contraseña actual.',
      tone: cleared.isOk ? ToastTone.success : ToastTone.warning,
    );
    if (cleared.isOk && member.mustChangePassword) context.go(Routes.portal);
  }

  @override
  Widget build(BuildContext context) {
    final member = ref.watch(myInsurerMemberProvider).value;
    final forced = member?.mustChangePassword ?? false;

    return ListView(
      padding: const EdgeInsets.all(Insets.xl),
      children: [
        const PortalHeader(
          title: 'Cambiar contraseña',
          subtitle: 'Usa al menos ${ChangePasswordScreen.minLength} caracteres, '
              'con letras y números.',
        ),
        const SizedBox(height: Insets.xl),
        Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: 420,
            child: FloatingCard(
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (forced) ...[
                      const InlineNotice(
                        key: Key('password-change-required'),
                        message: 'Tu cuenta se abrió con una contraseña '
                            'temporal. Elige una nueva para continuar.',
                      ),
                      const SizedBox(height: Insets.lg),
                    ],
                    TextFormField(
                      key: const Key('password-current'),
                      controller: _current,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Contraseña actual',
                      ),
                      validator: (v) => (v?.isEmpty ?? true) ? 'Requerido' : null,
                    ),
                    const SizedBox(height: Insets.md),
                    TextFormField(
                      key: const Key('password-new'),
                      controller: _next,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Contraseña nueva',
                      ),
                      validator: (v) {
                        final value = v ?? '';
                        if (value.length < ChangePasswordScreen.minLength) {
                          return 'Usa al menos ${ChangePasswordScreen.minLength} caracteres.';
                        }
                        if (!value.contains(RegExp('[A-Za-z]')) ||
                            !value.contains(RegExp('[0-9]'))) {
                          return 'Usa letras y números.';
                        }
                        if (value == _current.text) {
                          return 'Debe ser distinta de la actual.';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: Insets.md),
                    TextFormField(
                      key: const Key('password-repeat'),
                      controller: _repeat,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Repite la contraseña nueva',
                      ),
                      onFieldSubmitted: (_) => _save(),
                      validator: (v) =>
                          v != _next.text ? 'Las contraseñas no coinciden.' : null,
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: Insets.lg),
                      InlineNotice(
                        key: const Key('password-error'),
                        tone: NoticeTone.error,
                        message: _error!,
                      ),
                    ],
                    const SizedBox(height: Insets.xl),
                    ElevatedButton(
                      key: const Key('password-save'),
                      onPressed: _busy || member == null ? null : _save,
                      child: _busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                color: BrandColors.white,
                              ),
                            )
                          : const Text('Guardar contraseña'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
