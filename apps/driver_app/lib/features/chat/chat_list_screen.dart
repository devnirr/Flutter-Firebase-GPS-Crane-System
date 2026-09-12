import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';

/// The chofer's recent jobs, newest first, for the list of past conversations.
///
/// One page only: a conversation is worth reopening for a day or two, not a
/// year. Re-read whenever the current job changes, so a finished one moves
/// down into this list without a manual refresh.
final recentDriverServicesProvider = FutureProvider<List<Service>>((ref) async {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return const [];
  ref.watch(activeDriverServiceProvider.select((s) => s.value?.id));

  final result = await ref
      .read(serviceRepositoryProvider)
      .fetchHistory(userId: uid, role: UserRole.driver);
  // Rethrown so the screen renders the Failure's es-DO message.
  if (result case Err(:final failure)) throw failure;
  return result.valueOrNull?.items ?? const [];
});

/// What chat requests add to the Chat tab's count: each one still waiting for
/// an answer, and each unread message in a conversation that is open.
final chatRequestAttentionProvider = Provider<int>((ref) {
  final now = clock.now().toUtc();
  final requests = ref.watch(driverChatRequestsProvider).value ?? const [];
  var count = 0;
  for (final request in requests) {
    switch (request.phaseAt(now)) {
      case ChatRequestPhase.waiting:
        count++;
      case ChatRequestPhase.open:
        count += ref.watch(unreadChatRequestMessageCountProvider(request.id));
      case ChatRequestPhase.over:
        break;
    }
  }
  return count;
});

/// The Chat tab.
///
/// The conversation that matters is the one with the customer of the job in
/// progress, so it sits alone at the top. Earlier jobs follow, read-only —
/// the rules close a chat when its job ends, but "what did she say the gate
/// code was" is still worth being able to look up.
class ChatListScreen extends ConsumerWidget {
  const ChatListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(activeDriverServiceProvider).value;
    final recent = ref.watch(recentDriverServicesProvider);
    // Customers near the truck who asked to talk — waiting for an answer, or
    // already talking. Finished ones drop off.
    final now = clock.now().toUtc();
    // Conversations this chofer deleted stay off the list until somebody
    // writes in them again, and a blocked customer's do not come back at all.
    final blocked = ref.watch(blockedUsersProvider).value ?? const <String>{};
    final requests = [
      for (final request
          in ref.watch(driverChatRequestsProvider).value ?? const <ChatRequest>[])
        if (request.phaseAt(now) != ChatRequestPhase.over &&
            !blocked.contains(request.clientId) &&
            !ref.watch(chatThreadHiddenProvider(requestThreadKey(request.id))))
          request,
    ];
    final showActive = active != null &&
        active.canChat &&
        !ref.watch(chatThreadHiddenProvider(jobThreadKey(active.id)));

    return Scaffold(
      backgroundColor: BrandColors.offWhite,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Mensajes'),
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(recentDriverServicesProvider.future),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            Insets.lg,
            Insets.sm,
            Insets.lg,
            Insets.xxl,
          ),
          children: [
            if (requests.isNotEmpty) ...[
              const FieldLabel('Solicitudes de chat'),
              const SizedBox(height: Insets.sm),
              for (final request in requests)
                Padding(
                  padding: const EdgeInsets.only(bottom: Insets.sm),
                  child: _RequestConversation(request: request),
                ),
              const SizedBox(height: Insets.lg),
            ],
            const FieldLabel('Servicio en curso'),
            const SizedBox(height: Insets.sm),
            if (showActive)
              _ActiveConversation(service: active)
            else
              const _NoConversationCard(),
            const SizedBox(height: Insets.xl),
            const FieldLabel('Servicios anteriores'),
            const SizedBox(height: Insets.sm),
            ...recent.when(
              loading: () => const [
                Padding(
                  padding: EdgeInsets.all(Insets.xl),
                  child: Center(
                    child: CircularProgressIndicator(strokeWidth: 2.4),
                  ),
                ),
              ],
              error: (error, _) => [
                InlineNotice(
                  message: error is Failure
                      ? error.userMessage
                      : 'No pudimos cargar tus servicios anteriores.',
                  tone: NoticeTone.error,
                  icon: Icons.cloud_off_outlined,
                  actionLabel: 'Reintentar',
                  onAction: () => ref.invalidate(recentDriverServicesProvider),
                ),
              ],
              data: (services) {
                final past = [
                  for (final service in services)
                    if (service.id != active?.id &&
                        !ref.watch(
                          chatThreadHiddenProvider(jobThreadKey(service.id)),
                        ))
                      service,
                ];
                if (past.isEmpty) {
                  return [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: Insets.lg),
                      child: Text(
                        'Todavía no tienes servicios anteriores.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(color: BrandColors.grey600),
                      ),
                    ),
                  ];
                }
                return [
                  for (final service in past)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Insets.sm),
                      child: _PastConversation(service: service),
                    ),
                ];
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// The open conversation: who, the last thing said, and what is unread.
class _ActiveConversation extends ConsumerWidget {
  const _ActiveConversation({required this.service});

  final Service service;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final uid = ref.watch(currentUserIdProvider);
    final messages =
        ref.watch(serviceMessagesProvider(service.id)).value ?? const [];
    final unread = ref.watch(unreadMessageCountProvider(service.id));
    final last = messages.isEmpty ? null : messages.last;

    final preview = last == null
        ? 'Escríbele al cliente si necesitas alguna indicación.'
        : '${uid != null && last.isMine(uid) ? 'Tú: ' : ''}${last.text}';

    return FloatingCard(
      key: const Key('active-conversation'),
      onTap: () => context.push(Routes.chatFor(service.id)),
      child: Row(
        children: [
          _Initial(name: service.clientName, highlighted: true),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  service.clientName.isEmpty ? 'Cliente' : service.clientName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleSmall,
                ),
                const SizedBox(height: 2),
                Text(
                  preview,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(
                    color: unread > 0 ? BrandColors.ink : BrandColors.grey600,
                    fontWeight: unread > 0 ? FontWeight.w600 : null,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: Insets.sm),
          if (unread > 0)
            Badge.count(
              count: unread,
              backgroundColor: BrandColors.red,
              textColor: BrandColors.white,
            )
          else
            const Icon(Icons.chevron_right, color: BrandColors.grey400),
        ],
      ),
    );
  }
}

/// A finished job's conversation, opened read-only.
class _PastConversation extends StatelessWidget {
  const _PastConversation({required this.service});

  final Service service;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final createdAt = service.createdAt;

    return FloatingCard(
      onTap: () => context.push(Routes.chatFor(service.id)),
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.lg,
        vertical: Insets.md,
      ),
      child: Row(
        children: [
          _Initial(name: service.clientName),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  service.clientName.isEmpty ? 'Cliente' : service.clientName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleSmall,
                ),
                Text(
                  [
                    service.code,
                    if (createdAt != null) DoTime.relative(createdAt),
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(color: BrandColors.grey600),
                ),
              ],
            ),
          ),
          const SizedBox(width: Insets.sm),
          StatusChip(service.status, compact: true),
        ],
      ),
    );
  }
}

class _NoConversationCard extends StatelessWidget {
  const _NoConversationCard();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return FloatingCard(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.lg,
        vertical: Insets.xl,
      ),
      child: Column(
        children: [
          const Icon(
            Icons.chat_bubble_outline,
            size: 30,
            color: BrandColors.grey400,
          ),
          const SizedBox(height: Insets.md),
          Text('Sin conversación activa', style: text.titleSmall),
          const SizedBox(height: Insets.xs),
          Text(
            'El chat con el cliente se abre cuando aceptas un servicio.',
            textAlign: TextAlign.center,
            style: text.bodySmall?.copyWith(color: BrandColors.grey600),
          ),
        ],
      ),
    );
  }
}

/// A customer who asked from the map: waiting for an answer, or talking.
class _RequestConversation extends ConsumerWidget {
  const _RequestConversation({required this.request});

  final ChatRequest request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final waiting =
        request.phaseAt(clock.now().toUtc()) == ChatRequestPhase.waiting;
    final uid = ref.watch(currentUserIdProvider);
    final messages =
        ref.watch(chatRequestMessagesProvider(request.id)).value ?? const [];
    final unread = ref.watch(unreadChatRequestMessageCountProvider(request.id));
    final last = messages.isEmpty ? null : messages.last;

    final subtitle = waiting
        ? 'Quiere hablar contigo · todavía no pide la grúa'
        : last == null
        ? 'Conversación abierta'
        : '${uid != null && last.isMine(uid) ? 'Tú: ' : ''}${last.text}';

    return FloatingCard(
      key: Key('chat-request-${request.id}'),
      onTap: () => context.push(Routes.chatRequestFor(request.id)),
      child: Row(
        children: [
          _Initial(name: request.clientName, highlighted: true),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  request.clientName.isEmpty ? 'Cliente' : request.clientName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleSmall,
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(
                    color: waiting || unread > 0
                        ? BrandColors.ink
                        : BrandColors.grey600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: Insets.sm),
          if (waiting)
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.sm,
                vertical: Insets.xxs,
              ),
              decoration: const BoxDecoration(
                color: BrandColors.red,
                borderRadius: Corners.brSm,
              ),
              child: Text(
                'Nueva',
                style: text.labelSmall?.copyWith(color: BrandColors.white),
              ),
            )
          else if (unread > 0)
            Badge.count(
              count: unread,
              backgroundColor: BrandColors.red,
              textColor: BrandColors.white,
            )
          else
            const Icon(Icons.chevron_right, color: BrandColors.grey400),
        ],
      ),
    );
  }
}

/// The customer's initial in a circle — red for the live conversation.
class _Initial extends StatelessWidget {
  const _Initial({required this.name, this.highlighted = false});

  final String name;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final trimmed = name.trim();
    return CircleAvatar(
      radius: 22,
      backgroundColor: highlighted ? BrandColors.redTint : BrandColors.grey100,
      child: Text(
        trimmed.isEmpty ? '?' : trimmed[0].toUpperCase(),
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          color: highlighted ? BrandColors.red : BrandColors.grey600,
        ),
      ),
    );
  }
}
