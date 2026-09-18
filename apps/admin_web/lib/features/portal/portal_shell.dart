import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';
import '../shared/page_parts.dart';
import '../shell/theme_toggle.dart';

/// The panel as an insurance company sees it: its own tows and nothing else.
///
/// The same chrome as the office's — dark rail, white page — with the
/// company's name where the office sees its search box, so nobody at the
/// aseguradora wonders whose account they are in.
class PortalShell extends ConsumerWidget {
  const PortalShell({required this.child, required this.location, super.key});

  final Widget child;
  final String location;

  static const _minWidth = 1024.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (MediaQuery.sizeOf(context).width < _minWidth) {
      return const Scaffold(
        body: EmptyState(
          title: 'Pantalla muy pequeña',
          message:
              'El portal de aseguradoras necesita una pantalla de al menos '
              '1024 px de ancho. Ábrelo en una computadora.',
          icon: Icons.desktop_windows_outlined,
        ),
      );
    }

    final blocked = _blockedReason(ref);
    if (blocked != null) {
      return Scaffold(
        body: EmptyState(
          key: const Key('portal-blocked'),
          title: 'Sin acceso al portal',
          message: blocked,
          icon: Icons.lock_outline,
          actionLabel: 'Cerrar sesión',
          onAction: () => ref.read(authRepositoryProvider).signOut(),
        ),
      );
    }

    return Scaffold(
      body: Row(
        children: [
          _PortalSidebar(location: location),
          Expanded(
            child: Column(
              children: [
                const _PortalTopBar(),
                Expanded(child: child),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Why this person may not use the portal right now, or null if they may.
  ///
  /// The database refuses a suspended company's people and a deactivated
  /// person everything, their own records included, so a refused read means
  /// the same as a record that says so. Loading is not a refusal.
  static String? _blockedReason(WidgetRef ref) {
    const office = 'Comunícate con la oficina de GRÚAS RD.';
    final member = ref.watch(myInsurerMemberProvider);
    final insurer = ref.watch(myInsurerProvider);

    final company = insurer.isLoading ? null : insurer.value;
    if (company != null && !company.isActive) {
      return company.statusReason.isEmpty
          ? 'La cuenta de tu aseguradora está suspendida. $office'
          : 'La cuenta de tu aseguradora está suspendida: '
                '${company.statusReason}. $office';
    }
    if (!member.isLoading && !(member.value?.active ?? false)) {
      return 'Tu usuario está desactivado o tu aseguradora está suspendida. '
          '$office';
    }
    if (!insurer.isLoading && company == null) {
      return 'No pudimos abrir la cuenta de tu aseguradora. $office';
    }
    return null;
  }
}

class _PortalSidebar extends ConsumerWidget {
  const _PortalSidebar({required this.location});

  final String location;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final member = ref.watch(myInsurerMemberProvider).value;
    final items = <({String label, IconData icon, String route})>[
      (label: 'Inicio', icon: Icons.dashboard_outlined, route: Routes.portal),
      (
        label: 'Nuevo servicio',
        icon: Icons.add_circle_outline,
        route: Routes.portalNew,
      ),
      (
        label: 'Mapa en vivo',
        icon: Icons.map_outlined,
        route: Routes.portalMap,
      ),
      (
        label: 'Servicios',
        icon: Icons.list_alt_outlined,
        route: Routes.portalServices,
      ),
      if (member?.canManageMembers ?? false) ...[
        (
          label: 'Facturas',
          icon: Icons.request_quote_outlined,
          route: Routes.portalInvoices,
        ),
        (
          label: 'Usuarios',
          icon: Icons.people_outline,
          route: Routes.portalUsers,
        ),
      ],
      (
        label: 'Cambiar contraseña',
        icon: Icons.lock_outline,
        route: Routes.portalPassword,
      ),
    ];

    return Container(
      width: 232,
      color: context.palette.sidebar,
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'GRÚAS RD',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: BrandColors.white,
                              letterSpacing: 1.1,
                            ),
                      ),
                      Text(
                        'Aseguradoras',
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: BrandColors.grey400),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: Insets.sm),
          for (final item in items)
            _PortalNavItem(
              key: Key('portal-nav-${item.route}'),
              label: item.label,
              icon: item.icon,
              selected: _isSelected(item.route),
              onTap: () => context.go(item.route),
            ),
          const Spacer(),
          Divider(color: context.palette.sidebarHover, height: 1),
          _PortalNavItem(
            key: const Key('portal-sign-out'),
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
    if (route == Routes.portal) return location == Routes.portal;
    return location.startsWith(route);
  }
}

class _PortalNavItem extends StatelessWidget {
  const _PortalNavItem({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Material(
      color: selected ? palette.brand : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        hoverColor: palette.sidebarHover,
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
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: selected ? BrandColors.white : BrandColors.grey200,
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

class _PortalTopBar extends ConsumerWidget {
  const _PortalTopBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final insurer = ref.watch(myInsurerProvider).value;
    final member = ref.watch(myInsurerMemberProvider).value;

    return Container(
      height: 60,
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: Insets.xl),
      child: Row(
        children: [
          Icon(Icons.shield_outlined, color: palette.brand, size: 20),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Text(
              insurer?.name ?? '',
              key: const Key('portal-company-name'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.titleMedium,
            ),
          ),
          if (member != null) ...[
            // Flexible, not bare: a long name on a 1024-px screen must give
            // way to the controls beside it rather than push them off the bar.
            // Aligned right inside its share of the row: on its own the
            // column took only its text's width and left the rest of that
            // share empty to the right of the controls, stranding them near
            // the middle of a wide bar.
            Flexible(
              child: Align(
                alignment: Alignment.centerRight,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      member.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.titleSmall,
                    ),
                    Text(
                      member.role.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(color: palette.textMuted),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: Insets.md),
          ],
          const ThemeModeButton(),
          const SizedBox(width: Insets.sm),
          CircleAvatar(
            radius: 15,
            backgroundColor: palette.brandTint,
            child: Icon(Icons.person, size: 17, color: palette.brand),
          ),
        ],
      ),
    );
  }
}

/// A page title with its explanation under it, and an optional action.
class PortalHeader extends StatelessWidget {
  const PortalHeader({
    required this.title,
    required this.subtitle,
    this.action,
    super.key,
  });

  final String title;
  final String subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: text.headlineSmall),
              const SizedBox(height: Insets.xs),
              Text(
                subtitle,
                style: text.bodyMedium?.copyWith(color: palette.textMuted),
              ),
            ],
          ),
        ),
        if (action != null) ...[const SizedBox(width: Insets.lg), action!],
      ],
    );
  }
}

/// One number on the portal's pages.
///
/// The panel's own [StatTile] underneath, so the company sees the same figures
/// the office does, built the same way.
class PortalKpi extends StatelessWidget {
  const PortalKpi({
    required this.label,
    required this.value,
    required this.icon,
    this.detail,
    this.color,
    this.width = 250,
    super.key,
  });

  final String label;
  final String value;
  final IconData icon;
  final String? detail;
  final Color? color;

  /// Fixed for a free-standing row of tiles; null inside a [StatRow], which
  /// shares the width out and gives every tile the same height.
  final double? width;

  @override
  Widget build(BuildContext context) {
    final tile = StatTile(
      icon: icon,
      label: label,
      value: value,
      detail: detail ?? '',
      color: color,
    );
    return width == null ? tile : SizedBox(width: width, child: tile);
  }
}

/// One tow in a portal list: the claim first, because that is the number the
/// company files it under; then what it cost and where it stands, and a
/// chevron because the row opens it.
class PortalServiceTile extends StatelessWidget {
  const PortalServiceTile({
    required this.service,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(vertical: Insets.md),
    super.key,
  });

  final Service service;
  final VoidCallback? onTap;

  /// Vertical only inside a card that pads its own content; a [ListCard],
  /// whose rows run edge to edge, passes the horizontal part too.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final s = service;
    final claim = s.insurance?.claimNumber ?? '';
    final price = portalPriceOf(s);
    final at = s.createdAt ?? s.timeline.createdAt;
    // The icon takes the state's colour, so a list reads at a glance: blue on
    // the road, green done, grey cancelled.
    final tone = switch (s.status) {
      ServiceStatus.completed || ServiceStatus.closed => palette.success,
      ServiceStatus.cancelled => palette.textFaint,
      _ => palette.info,
    };

    return InkWell(
      key: Key('portal-service-${s.id}'),
      onTap: onTap,
      child: Padding(
        padding: padding,
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: tone.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.local_shipping_outlined, size: 20, color: tone),
            ),
            const SizedBox(width: Insets.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    [
                      if (claim.isNotEmpty) 'Siniestro $claim' else s.code,
                      if (s.vehicle.plate.isNotEmpty) s.vehicle.plate,
                      if ((s.insurance?.insuredName ?? '').isNotEmpty)
                        s.insurance!.insuredName,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleSmall,
                  ),
                  const SizedBox(height: 1),
                  Text(
                    [
                      if (claim.isNotEmpty) s.code,
                      if (at != null) DoTime.dateAndTime(at),
                      s.pickup.displayAddress,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(color: palette.textMuted),
                  ),
                ],
              ),
            ),
            if (price != null) ...[
              const SizedBox(width: Insets.md),
              Text(price.formatDOP, style: text.titleSmall),
            ],
            const SizedBox(width: Insets.md),
            // A fixed slot, so the chips stack in a column however long the
            // word in each one is.
            SizedBox(
              width: 128,
              child: Align(
                alignment: Alignment.centerRight,
                child: StatusChip(
                  s.status,
                  compact: true,
                  label: s.status.officeLabel,
                ),
              ),
            ),
            if (onTap != null) ...[
              const SizedBox(width: Insets.sm),
              Icon(Icons.chevron_right, size: 20, color: palette.textFaint),
            ],
          ],
        ),
      ),
    );
  }
}

/// What a tow adds to the company's invoice before ITBIS, or null while it
/// adds nothing yet (in flight, or cancelled free).
int? portalPriceOf(Service s) {
  if (s.status == ServiceStatus.completed || s.status == ServiceStatus.closed) {
    return s.billing?.subtotalCents ?? s.quote.subtotalCents;
  }
  if (s.status == ServiceStatus.cancelled &&
      (s.cancellation?.hasFee ?? false)) {
    return s.cancellation!.feeCents;
  }
  return null;
}
