import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';

/// Paginated service history.
///
/// Pages rather than loading everything: a customer two years in would
/// otherwise pull thousands of documents to draw one list, and pay for it.
class HistoryController extends AsyncNotifier<PagedServices> {
  @override
  Future<PagedServices> build() => _fetch();

  Future<PagedServices> _fetch({Object? cursor}) async {
    final uid = ref.read(currentUserIdProvider);
    if (uid == null) return PagedServices.empty;

    final result = await ref.read(serviceRepositoryProvider).fetchHistory(
          userId: uid,
          role: UserRole.client,
          cursor: cursor,
        );

    // Rethrowing puts the Failure on AsyncError, where the screen renders its
    // es-DO message instead of a generic error string.
    if (result case Err(:final failure)) throw failure;
    return result.valueOrNull ?? PagedServices.empty;
  }

  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasMore || state.isLoading) return;

    final next = await _fetch(cursor: current.cursor);
    state = AsyncData(
      PagedServices(
        items: [...current.items, ...next.items],
        cursor: next.cursor,
        hasMore: next.hasMore,
      ),
    );
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_fetch);
  }
}

final AsyncNotifierProvider<HistoryController, PagedServices>
    historyControllerProvider =
    AsyncNotifierProvider<HistoryController, PagedServices>(
  HistoryController.new,
);

class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(historyControllerProvider);

    return Scaffold(
      backgroundColor: BrandColors.offWhite,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Mis servicios y facturas'),
      ),
      body: history.when(
        loading: () => const BrandLoader(),
        error: (error, _) => EmptyState(
          title: 'No pudimos cargar tu historial',
          message: error is Failure
              ? error.userMessage
              : 'Revisa tu conexión e intenta de nuevo.',
          icon: Icons.error_outline,
          tone: EmptyStateTone.error,
          actionLabel: 'Reintentar',
          onAction: () => ref.read(historyControllerProvider.notifier).refresh(),
        ),
        data: (page) {
          if (page.items.isEmpty) {
            return EmptyState(
              title: 'Todavía no tienes servicios',
              message: 'Cuando pidas tu primera grúa, la verás aquí junto con '
                  'su factura.',
              icon: Icons.receipt_long_outlined,
              actionLabel: 'Pedir una grúa',
              onAction: () => context.go(Routes.request),
            );
          }

          return RefreshIndicator(
            onRefresh: () =>
                ref.read(historyControllerProvider.notifier).refresh(),
            child: ListView.separated(
              padding: const EdgeInsets.all(Insets.lg),
              itemCount: page.items.length + (page.hasMore ? 1 : 0),
              separatorBuilder: (_, _) => const SizedBox(height: Insets.md),
              itemBuilder: (context, index) {
                if (index == page.items.length) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: Insets.lg),
                    child: OutlinedButton(
                      onPressed: () => ref
                          .read(historyControllerProvider.notifier)
                          .loadMore(),
                      child: const Text('Ver más'),
                    ),
                  );
                }
                return _HistoryTile(service: page.items[index]);
              },
            ),
          );
        },
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.service});

  final Service service;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final createdAt = service.createdAt;

    return FloatingCard(
      onTap: () => context.push(Routes.detailFor(service.id)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  service.code,
                  style: text.labelMedium?.copyWith(color: BrandColors.grey600),
                ),
              ),
              StatusChip(service.status, compact: true),
            ],
          ),
          const SizedBox(height: Insets.md),
          RouteSummary(
            pickup: service.pickup.displayAddress,
            dropoff: service.dropoff?.displayAddress,
          ),
          const SizedBox(height: Insets.md),
          const Divider(height: 1),
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
                createdAt == null ? '' : DoTime.relative(createdAt),
                style: text.bodySmall?.copyWith(color: BrandColors.grey600),
              ),
              const Spacer(),
              Text(service.totalCents.formatDOP, style: text.titleMedium),
            ],
          ),
        ],
      ),
    );
  }
}
