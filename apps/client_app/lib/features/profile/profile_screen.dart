import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider).value;
    final settings = ref.watch(appSettingsProvider).value;
    final config = ref.watch(appConfigProvider);
    final text = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: BrandColors.offWhite,
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.pop()),
        title: const Text('Mi cuenta'),
      ),
      body: user == null
          ? const BrandLoader()
          : ListView(
              padding: const EdgeInsets.all(Insets.lg),
              children: [
                FloatingCard(
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 28,
                        backgroundColor: BrandColors.redTint,
                        child: Text(
                          user.shortName.isEmpty ? '?' : user.shortName[0],
                          style: text.headlineSmall
                              ?.copyWith(color: BrandColors.red),
                        ),
                      ),
                      const SizedBox(width: Insets.lg),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(user.name, style: text.titleMedium),
                            const SizedBox(height: 2),
                            Text(
                              user.displayPhone,
                              style: text.bodyMedium
                                  ?.copyWith(color: BrandColors.grey600),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: Insets.lg),

                FloatingCard(
                  padding: const EdgeInsets.symmetric(vertical: Insets.sm),
                  child: Column(
                    children: [
                      _Row(
                        icon: Icons.receipt_long_outlined,
                        label: 'Mis servicios',
                        onTap: () => context.push(Routes.history),
                      ),
                      const Divider(indent: Insets.huge),
                      _Row(
                        icon: Icons.credit_card_outlined,
                        label: 'Métodos de pago',
                        subtitle: user.preferredPaymentMethod.label,
                        onTap: () => _notYet(context),
                      ),
                      const Divider(indent: Insets.huge),
                      _Row(
                        icon: Icons.business_outlined,
                        label: 'Facturación',
                        subtitle: user.billsWithRnc
                            ? 'RNC ${user.rnc} · crédito fiscal'
                            : 'Consumo',
                        onTap: () => _notYet(context),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: Insets.lg),

                FloatingCard(
                  padding: const EdgeInsets.symmetric(vertical: Insets.sm),
                  child: Column(
                    children: [
                      _Row(
                        icon: Icons.support_agent_outlined,
                        label: 'Soporte 24/7',
                        subtitle: settings?.supportPhone ?? '',
                        onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'Llamando a ${settings?.supportPhone ?? 'soporte'}…',
                            ),
                          ),
                        ),
                      ),
                      const Divider(indent: Insets.huge),
                      _Row(
                        icon: Icons.description_outlined,
                        label: 'Términos y privacidad',
                        onTap: () => _notYet(context),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: Insets.xl),

                OutlinedButton.icon(
                  onPressed: () async {
                    await ref.read(authRepositoryProvider).signOut();
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: BrandColors.danger,
                    side: const BorderSide(color: BrandColors.dangerTint),
                  ),
                  icon: const Icon(Icons.logout, size: 18),
                  label: const Text('Cerrar sesión'),
                ),
                const SizedBox(height: Insets.lg),
                Center(
                  child: Text(
                    'Grúas RD 24/7 · ${config.flavor.wire}',
                    style: text.bodySmall?.copyWith(color: BrandColors.grey400),
                  ),
                ),
              ],
            ),
    );
  }

  void _notYet(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Disponible en la próxima versión.')),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: Icon(icon, color: BrandColors.grey800),
      title: Text(label, style: Theme.of(context).textTheme.titleSmall),
      subtitle: subtitle == null || subtitle!.isEmpty
          ? null
          : Text(
              subtitle!,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: BrandColors.grey600),
            ),
      trailing: const Icon(Icons.chevron_right, color: BrandColors.grey400),
    );
  }
}
