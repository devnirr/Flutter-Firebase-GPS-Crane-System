import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';

/// The panel chrome: dark sidebar, top bar, content.
///
/// A dispatcher sits in this screen for a whole shift, so it is built for
/// density and glanceability rather than for a first impression. Below 1024 px
/// it says so plainly instead of reflowing into something unusable — a live
/// operations map on a phone is a worse tool than an honest message.
class AdminShell extends ConsumerWidget {
  const AdminShell({required this.child, required this.location, super.key});

  final Widget child;
  final String location;

  static const _minWidth = 1024.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (MediaQuery.sizeOf(context).width < _minWidth) {
      return const Scaffold(
        body: EmptyState(
          title: 'Pantalla muy pequeña',
          message: 'El panel de operaciones necesita una pantalla de al menos '
              '1024 px de ancho. Ábrelo en una computadora.',
          icon: Icons.desktop_windows_outlined,
        ),
      );
    }

    return Scaffold(
      body: Row(
        children: [
          _Sidebar(location: location),
          Expanded(
            child: Column(
              children: [
                const _TopBar(),
                Expanded(child: child),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Sidebar extends ConsumerWidget {
  const _Sidebar({required this.location});

  final String location;

  static const _items = <({String label, IconData icon, String route})>[
    (label: 'Operaciones', icon: Icons.map_outlined, route: Routes.operations),
    (label: 'Servicios', icon: Icons.list_alt_outlined, route: Routes.services),
    (label: 'Clientes', icon: Icons.people_outline, route: Routes.clients),
    (label: 'Choferes', icon: Icons.badge_outlined, route: Routes.drivers),
    (label: 'Grúas', icon: Icons.local_shipping_outlined, route: Routes.trucks),
    (label: 'Reportes', icon: Icons.insights_outlined, route: Routes.reports),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      width: 232,
      color: BrandColors.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Insets.lg,
              Insets.xl,
              Insets.lg,
              Insets.lg,
            ),
            child: Row(
              children: [
                const GruaLogo(size: 52),
                const SizedBox(width: Insets.md),
                Expanded(
                  child: Text(
                    'GRÚAS RD',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: BrandColors.white,
                          letterSpacing: 1.1,
                        ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: Insets.sm),
          for (final item in _items)
            _NavItem(
              label: item.label,
              icon: item.icon,
              selected: _isSelected(item.route),
              onTap: () => context.go(item.route),
            ),
          const Spacer(),
          const Divider(color: BrandColors.sidebarHover, height: 1),
          _NavItem(
            label: 'Cerrar sesión',
            icon: Icons.logout,
            selected: false,
            onTap: () => ref.read(authRepositoryProvider).signOut(),
          ),
          const SizedBox(height: Insets.md),
        ],
      ),
    );
  }

  bool _isSelected(String route) {
    if (route == Routes.operations) return location == Routes.operations;
    return location.startsWith(route);
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? BrandColors.red : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        hoverColor: BrandColors.sidebarHover,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.lg,
            vertical: Insets.md,
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 19,
                color: selected ? BrandColors.white : BrandColors.grey400,
              ),
              const SizedBox(width: Insets.md),
              // Expanded, not bare: the rail is a fixed 232 px and a longer
              // label or a larger text scale otherwise overflows the row.
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color:
                            selected ? BrandColors.white : BrandColors.grey200,
                      ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopBar extends ConsumerWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final services = ref.watch(activeServicesProvider).value ?? const [];
    final text = Theme.of(context).textTheme;

    // The one thing a dispatcher must never miss: the cascade gave up and a
    // customer is waiting on a human.
    final needsManual =
        services.where((s) => s.status == ServiceStatus.needsManual).length;

    return Container(
      height: 60,
      decoration: const BoxDecoration(
        color: BrandColors.white,
        border: Border(bottom: BorderSide(color: BrandColors.grey200)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: Insets.xl),
      child: Row(
        children: [
          SizedBox(
            width: 320,
            height: 38,
            child: TextField(
              // Every one of those identifies a service, so the answer is the
              // Servicios page with the search already applied.
              textInputAction: TextInputAction.search,
              onSubmitted: (value) {
                final query = value.trim();
                if (query.isNotEmpty) context.go(Routes.servicesSearch(query));
              },
              decoration: InputDecoration(
                hintText: 'Buscar código, teléfono, chofer o placa…',
                prefixIcon: const Icon(Icons.search, size: 18),
                fillColor: BrandColors.offWhite,
                contentPadding: EdgeInsets.zero,
                border: const OutlineInputBorder(
                  borderRadius: Corners.brSm,
                  borderSide: BorderSide.none,
                ),
                enabledBorder: const OutlineInputBorder(
                  borderRadius: Corners.brSm,
                  borderSide: BorderSide.none,
                ),
                hintStyle: text.bodySmall?.copyWith(color: BrandColors.grey400),
              ),
            ),
          ),
          const Spacer(),
          Badge(
            isLabelVisible: needsManual > 0,
            label: Text('$needsManual'),
            backgroundColor: BrandColors.danger,
            child: IconButton(
              onPressed: () => context.go(Routes.operations),
              tooltip: needsManual > 0
                  ? '$needsManual servicio(s) esperando asignación'
                  : 'Sin alertas',
              icon: const Icon(Icons.notifications_none),
            ),
          ),
          const SizedBox(width: Insets.md),
          const CircleAvatar(
            radius: 15,
            backgroundColor: BrandColors.redTint,
            child: Icon(Icons.person, size: 17, color: BrandColors.red),
          ),
        ],
      ),
    );
  }
}
