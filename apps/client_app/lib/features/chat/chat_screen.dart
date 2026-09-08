import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

/// Chat between the customer and the assigned chofer.
///
/// Messages are written straight to Firestore rather than through a callable,
/// so they land instantly; the rules restrict who may post and a trigger sends
/// the push. Quick replies exist because the person on the other end is driving.
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({required this.serviceId, super.key});

  final String serviceId;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  var _sending = false;

  static const _quickReplies = [
    'Ya estoy en el lugar',
    '¿Cuánto falta?',
    'Estoy en el carro rojo',
    'Gracias, te espero',
  ];

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send(String text) async {
    final trimmed = text.trim();
    final uid = ref.read(currentUserIdProvider);
    if (trimmed.isEmpty || uid == null || _sending) return;

    setState(() => _sending = true);
    _controller.clear();

    final result = await ref.read(chatRepositoryProvider).sendMessage(
          serviceId: widget.serviceId,
          senderId: uid,
          senderRole: UserRole.client,
          text: trimmed,
          // Lets an optimistic bubble reconcile with the server echo, and stops
          // a retry on bad signal from duplicating the message.
          clientMsgId: 'c-${DateTime.now().microsecondsSinceEpoch}',
        );

    if (!mounted) return;
    setState(() => _sending = false);

    result.fold(
      (_) => _scrollToBottom(),
      (failure) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(failure.userMessage)),
      ),
    );
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: Motion.normal,
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final uid = ref.watch(currentUserIdProvider);
    final service = ref.watch(serviceByIdProvider(widget.serviceId)).value;
    final messages =
        ref.watch(serviceMessagesProvider(widget.serviceId)).value ?? const [];

    return Scaffold(
      backgroundColor: BrandColors.offWhite,
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.pop()),
        title: Column(
          children: [
            Text(
              service?.driverName.isNotEmpty ?? false
                  ? service!.driverName
                  : 'Chofer',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (service != null)
              Text(
                service.status.label,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: BrandColors.grey600),
              ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? const EmptyState(
                    title: 'Sin mensajes',
                    message: 'Escríbele al chofer si necesitas darle alguna '
                        'indicación.',
                    icon: Icons.chat_bubble_outline,
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(Insets.lg),
                    itemCount: messages.length,
                    itemBuilder: (context, index) => _Bubble(
                      message: messages[index],
                      isMine: uid != null && messages[index].isMine(uid),
                    ),
                  ),
          ),
          if (service?.canChat ?? false) ...[
            SizedBox(
              height: 44,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
                itemCount: _quickReplies.length,
                separatorBuilder: (_, _) => const SizedBox(width: Insets.sm),
                itemBuilder: (context, index) => ActionChip(
                  label: Text(_quickReplies[index]),
                  onPressed: () => _send(_quickReplies[index]),
                ),
              ),
            ),
            _Composer(
              controller: _controller,
              sending: _sending,
              onSend: () => _send(_controller.text),
            ),
          ] else
            const _ChatClosedNotice(),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.isMine});

  final ChatMessage message;
  final bool isMine;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.76,
        ),
        margin: const EdgeInsets.only(bottom: Insets.sm),
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.lg,
          vertical: Insets.md,
        ),
        decoration: BoxDecoration(
          color: isMine ? BrandColors.red : BrandColors.white,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(Corners.md),
            topRight: const Radius.circular(Corners.md),
            bottomLeft: Radius.circular(isMine ? Corners.md : Corners.xs),
            bottomRight: Radius.circular(isMine ? Corners.xs : Corners.md),
          ),
          boxShadow: isMine ? null : Shadows.card,
        ),
        child: Column(
          crossAxisAlignment:
              isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(
              message.text,
              style: text.bodyMedium?.copyWith(
                color: isMine ? BrandColors.white : BrandColors.ink,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              message.isPending
                  ? 'Enviando…'
                  : DoTime.time(message.sentAt ?? DateTime.now().toUtc()),
              style: text.bodySmall?.copyWith(
                fontSize: 10,
                color: isMine ? Colors.white70 : BrandColors.grey400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.sending,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: BrandColors.white,
      padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.md, Insets.lg, 0),
      child: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 4,
                maxLength: 1000,
                textCapitalization: TextCapitalization.sentences,
                onSubmitted: (_) => onSend(),
                decoration: const InputDecoration(
                  hintText: 'Escribe un mensaje…',
                  counterText: '',
                  fillColor: BrandColors.offWhite,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: Insets.lg,
                    vertical: Insets.md,
                  ),
                ),
              ),
            ),
            const SizedBox(width: Insets.sm),
            IconButton.filled(
              onPressed: sending ? null : onSend,
              style: IconButton.styleFrom(
                backgroundColor: BrandColors.red,
                minimumSize: const Size(48, 48),
              ),
              icon: sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: BrandColors.white,
                      ),
                    )
                  : const Icon(Icons.send, color: BrandColors.white),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatClosedNotice extends StatelessWidget {
  const _ChatClosedNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: BrandColors.white,
      padding: const EdgeInsets.all(Insets.lg),
      child: SafeArea(
        child: Text(
          'El chat se cierra cuando termina el servicio.',
          textAlign: TextAlign.center,
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: BrandColors.grey600),
        ),
      ),
    );
  }
}
