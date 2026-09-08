import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';
import 'location_publisher.dart';

/// The chofer's home: online switch, today's earnings, and the open work.
///
/// Going online is a checklist, not a boolean. A chofer who flips the switch
/// and then silently misses every offer because notifications are off is worse
/// than one who was told up front what is missing.
class DriverHomeScreen extends ConsumerWidget {
  const DriverHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final driver = ref.watch(currentDriverProvider).value;
    final earnings = ref.watch(driverEarningsProvider).value;
    final pending = ref.watch(activeServicesProvider).value ?? const [];

    // Watched, not read: this is what starts and stops position publishing,
    // and it must follow the chofer's online state rather than a button press.
    ref.watch(locationPublisherProvider);

    if (driver == null) return const Scaffold(body: BrandLoader());

    // Only unassigned work in this chofer's truck class is worth showing;
    // anything else is either somebody else's job or one they cannot take.
    final available = pending
        .where((s) => !s.hasDriver && s.truckTypeRequired == driver.truckType)
        .toList();

    return Scaffold(
      backgroundColor: BrandColors.offWhite,
      body: SafeArea(
        child: Column(
          children: [
            _Header(driver: driver, onEarnings: () => context.push(Routes.earnings)),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  Insets.lg,
                  0,
                  Insets.lg,
                  Insets.xxl,
                ),
                children: [
                  _OnlineCard(driver: driver),
                  const SizedBox(height: Insets.lg),
                  _TodayCard(
                    earnings: earnings,
                    onTap: () => context.push(Routes.earnings),
                  ),
                  const SizedBox(height: Insets.xl),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'PEDIDOS DISPONIBLES',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ),
                      Text(
                        '${available.length}',
                        style: Theme.of(context).textTheme.labelMedium?.copyWith(
                              color: BrandColors.grey600,
                            ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Insets.md),
                  if (!driver.isOnline)
                    const InlineNotice(
                      message: 'Ponte en línea para recibir pedidos.',
                      icon: Icons.wifi_off,
                    )
                  else if (available.isEmpty)
                    const _NoWorkCard()
                  else
                    for (final service in available)
                      Padding(
                        padding: const EdgeInsets.only(bottom: Insets.md),
                        child: _OrderCard(service: service),
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

class _Header extends ConsumerWidget {
  const _Header({required this.driver, required this.onEarnings});

  final Driver driver;
  final VoidCallback onEarnings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.md, Insets.lg, Insets.lg),
      child: Row(
        children: [
          const GruaLogo(size: 62, showWordmark: false),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(driver.shortName, style: text.titleMedium),
                Text(
                  [
                    if (driver.assignedTruckPlate.isNotEmpty)
                      driver.assignedTruckPlate,
                    driver.truckType.label,
                  ].join(' · '),
                  style: text.bodySmall?.copyWith(color: BrandColors.grey600),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onEarnings,
            icon: const Icon(Icons.account_balance_wallet_outlined),
          ),
          IconButton(
            onPressed: () => ref.read(authRepositoryProvider).signOut(),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
    );
  }
}

/// The online switch plus the reason it is unavailable, if it is.
class _OnlineCard extends ConsumerStatefulWidget {
  const _OnlineCard({required this.driver});

  final Driver driver;

  @override
  ConsumerState<_OnlineCard> createState() => _OnlineCardState();
}

class _OnlineCardState extends ConsumerState<_OnlineCard> {
  var _busy = false;

  Future<void> _toggle(bool value) async {
    if (_busy) return;
    setState(() => _busy = true);

    final result = await ref
        .read(driverRepositoryProvider)
        .setOnline(widget.driver.id, online: value);
    if (!mounted) return;
    setState(() => _busy = false);

    if (result case Err(:final failure)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(failure.userMessage)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final driver = widget.driver;
    final text = Theme.of(context).textTheme;
    final online = driver.isOnline;

    // Everything that must be true before dispatch can reach this chofer.
    final blockers = <String>[
      if (!driver.status.canWork) 'Tu cuenta no está activa',
      if (driver.assignedTruckId == null) 'No tienes una grúa asignada',
    ];

    return FloatingCard(
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: online ? BrandColors.success : BrandColors.grey400,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: Insets.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      online ? 'En línea' : 'Fuera de línea',
                      style: text.titleMedium,
                    ),
                    Text(
                      online
                          ? 'Estás recibiendo pedidos.'
                          : 'No recibirás pedidos.',
                      style: text.bodySmall
                          ?.copyWith(color: BrandColors.grey600),
                    ),
                  ],
                ),
              ),
              if (_busy)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2.2),
                )
              else
                Switch.adaptive(
                  value: online,
                  onChanged: blockers.isEmpty ? _toggle : null,
                ),
            ],
          ),
          if (blockers.isNotEmpty) ...[
            const SizedBox(height: Insets.md),
            InlineNotice(
              message: blockers.join(' · '),
              tone: NoticeTone.error,
            ),
          ],
          if (driver.cashOwedCents > 0) ...[
            const SizedBox(height: Insets.md),
            InlineNotice(
              message: 'Efectivo por entregar: '
                  '${driver.cashOwedCents.formatDOP}',
              icon: Icons.payments_outlined,
            ),
          ],
        ],
      ),
    );
  }
}

class _TodayCard extends StatelessWidget {
  const _TodayCard({required this.earnings, required this.onTap});

  final EarningsSummary? earnings;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return FloatingCard(
      onTap: onTap,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const FieldLabel('Hoy'),
                const SizedBox(height: Insets.xs),
                Text(
                  (earnings?.todayNetCents ?? 0).formatDOP,
                  style: text.headlineMedium?.copyWith(color: BrandColors.red),
                ),
                Text(
                  '${earnings?.todayServices ?? 0} servicios',
                  style: text.bodySmall?.copyWith(color: BrandColors.grey600),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, color: BrandColors.grey400),
        ],
      ),
    );
  }
}

class _NoWorkCard extends StatelessWidget {
  const _NoWorkCard();

  @override
  Widget build(BuildContext context) {
    return FloatingCard(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.lg,
        vertical: Insets.xxl,
      ),
      child: Column(
        children: [
          const Icon(Icons.hourglass_empty, size: 30, color: BrandColors.grey400),
          const SizedBox(height: Insets.md),
          Text(
            'No hay pedidos ahora mismo',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: Insets.xs),
          Text(
            'Te avisamos apenas entre uno para tu tipo de grúa.',
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: BrandColors.grey600),
          ),
        ],
      ),
    );
  }
}

/// One open job, with Aceptar / Rechazar as in the mockup.
class _OrderCard extends ConsumerStatefulWidget {
  const _OrderCard({required this.service});

  final Service service;

  @override
  ConsumerState<_OrderCard> createState() => _OrderCardState();
}

class _OrderCardState extends ConsumerState<_OrderCard> {
  var _busy = false;

  Future<void> _accept() async {
    if (_busy) return;
    setState(() => _busy = true);

    final result = await ref
        .read(functionsGatewayProvider)
        .acceptService(widget.service.id);
    if (!mounted) return;
    setState(() => _busy = false);

    // Each failure code gets its own message: "otro chofer lo tomó" and "la
    // oferta expiró" are the same HTTP status and completely different news.
    if (result case Err(:final failure)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(failure.userMessage)),
      );
    }
  }

  Future<void> _reject() async {
    if (_busy) return;
    setState(() => _busy = true);
    await ref
        .read(functionsGatewayProvider)
        .rejectService(widget.service.id, reason: DriverCancelReason.other);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    final text = Theme.of(context).textTheme;
    final pricing = ref.watch(pricingConfigProvider).value;

    // Show take-home, not gross. A chofer who has to work out the commission
    // in their head at the roadside declines.
    final net = pricing == null
        ? service.totalCents
        : service.totalCents -
            Pricing.commissionCents(
              config: pricing,
              grossCents: service.totalCents,
            );

    return FloatingCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(Insets.lg),
            child: Column(
              children: [
                Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: const BoxDecoration(
                        color: BrandColors.redTint,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.directions_car,
                        size: 20,
                        color: BrandColors.red,
                      ),
                    ),
                    const SizedBox(width: Insets.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(service.vehicle.displayName, style: text.titleSmall),
                          Text(
                            service.vehicle.condition.label,
                            style: text.bodySmall
                                ?.copyWith(color: BrandColors.grey600),
                          ),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(net.formatDOP, style: text.titleMedium),
                        Text(
                          'para ti',
                          style: text.bodySmall
                              ?.copyWith(color: BrandColors.grey600),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: Insets.lg),
                RouteSummary(
                  pickup: service.pickup.displayAddress,
                  pickupReference: service.pickup.reference,
                  dropoff: service.dropoff?.displayAddress,
                ),
                const SizedBox(height: Insets.md),
                Row(
                  children: [
                    Icon(
                      service.payment.isCash
                          ? Icons.payments_outlined
                          : Icons.credit_card,
                      size: 16,
                      color: BrandColors.grey600,
                    ),
                    const SizedBox(width: Insets.xs),
                    Text(
                      service.payment.method.label,
                      style: text.bodySmall
                          ?.copyWith(color: BrandColors.grey600),
                    ),
                    const Spacer(),
                    Text(
                      service.route.distanceLabel,
                      style: text.bodySmall
                          ?.copyWith(color: BrandColors.grey600),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: _busy ? null : _reject,
                  style: TextButton.styleFrom(
                    foregroundColor: BrandColors.grey600,
                    padding: const EdgeInsets.symmetric(vertical: Insets.lg),
                    shape: const RoundedRectangleBorder(),
                  ),
                  child: const Text('Rechazar'),
                ),
              ),
              Container(width: 1, height: 40, color: BrandColors.grey100),
              Expanded(
                child: TextButton(
                  onPressed: _busy ? null : _accept,
                  style: TextButton.styleFrom(
                    foregroundColor: BrandColors.red,
                    padding: const EdgeInsets.symmetric(vertical: Insets.lg),
                    shape: const RoundedRectangleBorder(),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2.2),
                        )
                      : const Text('ACEPTAR'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
