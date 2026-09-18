import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

import '../insurers/insurer_users_panel.dart';
import 'portal_shell.dart';

/// The company's own people, for its manager: the same list the office sees
/// on the company's page, limited by the server to this one company.
class PortalUsersScreen extends ConsumerWidget {
  const PortalUsersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final member = ref.watch(myInsurerMemberProvider).value;
    final insurerId = ref.watch(currentInsurerIdProvider).value;

    return ListView(
      padding: const EdgeInsets.all(Insets.xl),
      children: [
        const PortalHeader(
          title: 'Usuarios',
          subtitle: 'Las personas de tu aseguradora que pueden pedir grúas. Un '
              'administrador agrega, cambia o desactiva cuentas; un operador '
              'solo pide y consulta servicios.',
        ),
        const SizedBox(height: Insets.xl),
        if (insurerId != null && member != null)
          InsurerUsersPanel(
            insurerId: insurerId,
            canEdit: member.canManageMembers,
          ),
      ],
    );
  }
}
