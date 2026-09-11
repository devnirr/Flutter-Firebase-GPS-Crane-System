import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../router.dart';
import '../auth/app_presence.dart';

/// The Perfil tab: who the chofer is to the office, and the account's settings.
///
/// Nothing here is editable by the chofer. Every field on `drivers/{uid}` is
/// server-written — the truck, the status, the licence are the office's to
/// set — so this page shows them as they stand and says where to go to change
/// them.
class DriverProfileScreen extends ConsumerWidget {
  const DriverProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final driver = ref.watch(currentDriverProvider).value;
    final settings = ref.watch(appSettingsProvider).value;
    final blocker = ref.watch(locationBlockerProvider).value;
    final config = ref.watch(appConfigProvider);
    final text = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: BrandColors.offWhite,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Mi perfil'),
      ),
      body: driver == null
          ? const BrandLoader()
          : ListView(
              key: const Key('profile-list'),
              padding: const EdgeInsets.fromLTRB(
                Insets.lg,
                Insets.sm,
                Insets.lg,
                Insets.xxl,
              ),
              children: [
                _IdentityCard(driver: driver),
                const SizedBox(height: Insets.lg),
                FloatingCard(
                  padding: const EdgeInsets.symmetric(vertical: Insets.sm),
                  child: Column(
                    children: [
                      _Row(
                        icon: Icons.local_shipping_outlined,
                        label: 'Mi grúa',
                        subtitle: driver.assignedTruckId == null
                            ? 'Sin grúa asignada'
                            : [
                                if (driver.assignedTruckPlate.isNotEmpty)
                                  driver.assignedTruckPlate,
                                driver.truckType.label,
                              ].join(' · '),
                      ),
                      const Divider(indent: Insets.huge),
                      _Row(
                        icon: Icons.verified_user_outlined,
                        label: 'Estado de la cuenta',
                        subtitle: _statusLabel(driver.status),
                        subtitleColor: driver.status.canWork
                            ? BrandColors.success
                            : BrandColors.danger,
                      ),
                      if (driver.licenseNumber.isNotEmpty) ...[
                        const Divider(indent: Insets.huge),
                        _Row(
                          icon: Icons.badge_outlined,
                          label: 'Licencia',
                          subtitle: [
                            driver.licenseNumber,
                            if (driver.licenseExpiry != null)
                              'vence ${_date(driver.licenseExpiry!)}',
                          ].join(' · '),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: Insets.lg),
                FloatingCard(
                  padding: const EdgeInsets.symmetric(vertical: Insets.sm),
                  child: Column(
                    children: [
                      _Row(
                        icon: Icons.account_balance_wallet_outlined,
                        label: 'Mis ganancias',
                        subtitle: driver.cashOwedCents > 0
                            ? 'Efectivo por entregar: '
                                  '${driver.cashOwedCents.formatDOP}'
                            : 'Hoy, semana y mes',
                        onTap: () => context.push(Routes.earnings),
                      ),
                      const Divider(indent: Insets.huge),
                      _Row(
                        icon: blocker != null && blocker.isBlocking
                            ? Icons.location_off_outlined
                            : Icons.location_on_outlined,
                        label: 'Ubicación',
                        subtitle: blocker == null
                            ? ''
                            : blocker.isBlocking
                            ? blocker.message
                            : 'Activada',
                        subtitleColor: blocker != null && blocker.isBlocking
                            ? BrandColors.danger
                            : null,
                        onTap: blocker != null && blocker.isBlocking
                            ? () => _resolveLocation(ref, blocker)
                            : null,
                      ),
                      const Divider(indent: Insets.huge),
                      _Row(
                        icon: Icons.support_agent_outlined,
                        label: 'Soporte 24/7',
                        subtitle: settings?.supportPhone ?? '',
                        onTap: () =>
                            _callSupport(context, settings?.supportPhone ?? ''),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: Insets.xl),
                OutlinedButton.icon(
                  key: const Key('sign-out'),
                  onPressed: () => signOutDriver(ref),
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
                    'Grúas RD 24/7 · Chofer · ${config.flavor.wire}',
                    style: text.bodySmall?.copyWith(color: BrandColors.grey400),
                  ),
                ),
              ],
            ),
    );
  }

  static String _statusLabel(DriverStatus status) => switch (status) {
    DriverStatus.active => 'Activa',
    DriverStatus.inactive => 'En revisión por la oficina',
    DriverStatus.suspended => 'Suspendida',
    DriverStatus.unknown => 'Desconocido',
  };

  static String _date(DateTime date) {
    final local = date.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)}/${local.year}';
  }

  Future<void> _resolveLocation(WidgetRef ref, LocationBlocker blocker) async {
    final location = ref.read(locationServiceProvider);
    switch (blocker) {
      case LocationBlocker.serviceDisabled:
        await location.openLocationSettings();
      case LocationBlocker.deniedForever || LocationBlocker.needsAlways:
        await location.openAppSettings();
      case _:
        await location.request();
    }
    ref.invalidate(locationBlockerProvider);
  }

  Future<void> _callSupport(BuildContext context, String phone) async {
    final messenger = ScaffoldMessenger.of(context);
    final opened =
        phone.isNotEmpty && await launchUrl(Uri(scheme: 'tel', path: phone));
    if (!opened) {
      messenger.showSnackBar(
        const SnackBar(content: Text('No se pudo iniciar la llamada.')),
      );
    }
  }
}

/// Photo, name, contact and track record.
class _IdentityCard extends StatelessWidget {
  const _IdentityCard({required this.driver});

  final Driver driver;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final contact = driver.phone.isNotEmpty ? driver.phone : driver.email;

    return FloatingCard(
      child: Row(
        children: [
          DriverAvatar.of(driver, size: 56),
          const SizedBox(width: Insets.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(driver.name, style: text.titleMedium),
                if (contact.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    contact,
                    style: text.bodySmall?.copyWith(color: BrandColors.grey600),
                  ),
                ],
                const SizedBox(height: Insets.xs),
                Row(
                  children: [
                    const Icon(
                      Icons.star_rounded,
                      size: 16,
                      color: BrandColors.warning,
                    ),
                    const SizedBox(width: 2),
                    Flexible(
                      child: Text(
                        '${driver.rating.toStringAsFixed(1)} · '
                        '${driver.completedServices} servicios',
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(
                          color: BrandColors.grey800,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.label,
    this.subtitle = '',
    this.subtitleColor,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final Color? subtitleColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return ListTile(
      onTap: onTap,
      leading: Icon(icon, color: BrandColors.grey800),
      title: Text(label, style: text.titleSmall),
      subtitle: subtitle.isEmpty
          ? null
          : Text(
              subtitle,
              style: text.bodySmall?.copyWith(
                color: subtitleColor ?? BrandColors.grey600,
              ),
            ),
      trailing: onTap == null
          ? null
          : const Icon(Icons.chevron_right, color: BrandColors.grey400),
    );
  }
}
