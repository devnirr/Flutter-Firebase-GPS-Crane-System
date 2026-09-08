import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

/// Shown when a chofer can sign in but cannot work.
///
/// It names the actual reason rather than a generic denial, because the fix
/// differs completely: a suspended account needs a phone call to the office,
/// an inactive one usually needs a document uploaded.
class BlockedScreen extends ConsumerWidget {
  const BlockedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final driver = ref.watch(currentDriverProvider).value;
    final support = ref.watch(appSettingsProvider).value?.supportPhone ?? '';

    final (title, message) = switch (driver?.status) {
      DriverStatus.suspended => (
          'Cuenta suspendida',
          driver!.statusReason.isNotEmpty
              ? driver.statusReason
              : 'Tu cuenta fue suspendida. Comunícate con la oficina para '
                  'resolverlo.',
        ),
      _ => (
          'Cuenta no activa',
          'Tu cuenta todavía no está habilitada para trabajar. Normalmente '
              'falta verificar un documento.',
        ),
    };

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: EmptyState(
                title: title,
                message: message,
                icon: Icons.gpp_maybe_outlined,
                tone: EmptyStateTone.error,
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(Insets.gutter),
              child: Column(
                children: [
                  if (support.isNotEmpty)
                    ElevatedButton.icon(
                      onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Llamando a $support…')),
                      ),
                      icon: const Icon(Icons.call, size: 20),
                      label: const Text('Llamar a la oficina'),
                    ),
                  const SizedBox(height: Insets.md),
                  OutlinedButton(
                    onPressed: () => ref.read(authRepositoryProvider).signOut(),
                    child: const Text('Cerrar sesión'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
