import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../calls/call_controller.dart';
import '../domain/enums.dart';
import '../domain/failures.dart';
import '../domain/models/chat_prefs.dart';
import '../domain/models/chat_request.dart';
import '../domain/repositories.dart';
import '../media/photo_picker.dart';
import '../providers.dart';
import '../theme/brand.dart';
import '../theme/widgets/brand_widgets.dart';
import 'service_chat_screen.dart';

/// A conversation a customer opened from a nearby truck, before any job —
/// the same screen in both apps, from each side.
///
/// While the request waits, the customer sees that they are waiting (and can
/// withdraw), and the chofer sees who is asking with Aceptar / Rechazar. Once
/// accepted it is an ordinary chat until either side ends it or it closes on
/// its own; after that it stays readable.
class RequestChatScreen extends ConsumerStatefulWidget {
  const RequestChatScreen({
    required this.requestId,
    required this.role,
    super.key,
  });

  final String requestId;
  final UserRole role;

  @override
  ConsumerState<RequestChatScreen> createState() => _RequestChatScreenState();
}

class _RequestChatScreenState extends ConsumerState<RequestChatScreen> {
  /// Rebuilds when the request lapses or the conversation closes on its own,
  /// since nothing on the server rewrites the document at that moment.
  Timer? _deadline;
  var _busy = false;

  bool get _isDriver => widget.role == UserRole.driver;

  @override
  void dispose() {
    _deadline?.cancel();
    super.dispose();
  }

  void _armDeadline(ChatRequest request, ChatRequestPhase phase, DateTime now) {
    _deadline?.cancel();
    final due = switch (phase) {
      ChatRequestPhase.waiting => request.expiresAt,
      ChatRequestPhase.open => request.closesAt,
      ChatRequestPhase.over => null,
    };
    if (due == null) return;
    _deadline = Timer(due.difference(now) + const Duration(seconds: 1), () {
      if (mounted) setState(() {});
    });
  }

  Future<void> _run(Future<Result<void>> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    final result = await action();
    if (!mounted) return;
    setState(() => _busy = false);
    if (result case Err(:final failure)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(failure.userMessage)),
      );
    }
  }

  Future<void> _respond({required bool accept}) => _run(
        () => ref
            .read(functionsGatewayProvider)
            .respondChatRequest(widget.requestId, accept: accept),
      );

  Future<void> _close() => _run(
        () => ref.read(functionsGatewayProvider).closeChatRequest(widget.requestId),
      );

  /// Rings the other person's app, voice or video, while the conversation is
  /// open. Before the chofer accepts and after it closes it says why instead:
  /// asking for the camera only to be refused by the server helps nobody.
  void _call({
    required ChatRequestPhase phase,
    required String peerName,
    required bool video,
  }) {
    if (phase != ChatRequestPhase.open) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            phase == ChatRequestPhase.waiting
                ? 'Podrán llamarse cuando el chofer acepte el chat.'
                : 'Esta conversación terminó.',
          ),
        ),
      );
      return;
    }
    unawaited(
      ref.read(callControllerProvider.notifier).call(
            chatRequestId: widget.requestId,
            peerName: peerName,
            video: video,
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final request = ref.watch(chatRequestProvider(widget.requestId)).value;
    final messages =
        ref.watch(chatRequestMessagesProvider(widget.requestId)).value ?? const [];
    final uid = ref.watch(currentUserIdProvider);

    if (request == null) {
      return Scaffold(
        backgroundColor: BrandColors.offWhite,
        appBar: AppBar(title: const Text('Chat')),
        body: const BrandLoader(),
      );
    }

    final now = DateTime.now().toUtc();
    final phase = request.phaseAt(now);
    _armDeadline(request, phase, now);

    // This person's own view of this conversation — cleared, deleted, blocked.
    final threadKey = requestThreadKey(widget.requestId);
    final prefs =
        ref.watch(chatThreadPrefsProvider(threadKey)).value ?? ChatThreadPrefs.none;
    final otherUid = _isDriver ? request.clientId : request.driverId;
    final blocked =
        ref.watch(blockedUsersProvider).value?.contains(otherUid) ?? false;
    final blockedByOther =
        ref.watch(blockedByProvider(otherUid)).value ?? false;

    final title = _isDriver
        ? (request.clientName.isEmpty ? 'Cliente' : request.clientName)
        : (request.driverName.isEmpty ? 'Chofer de la grúa' : request.driverName);

    return ChatThreadView(
      title: title,
      // Denormalised onto the request when the chofer accepts, so the customer
      // sees the face they picked off the map.
      photoUrl: _isDriver ? '' : request.driverPhotoUrl,
      // In-app calls, like a job's chat. There is no phone number to dial
      // before a job: the chofer stays anonymous until the tow is requested.
      onCall: () => _call(phase: phase, peerName: title, video: false),
      onVideoCall: () => _call(phase: phase, peerName: title, video: true),
      hiddenBefore: prefs.clearedAt,
      blocked: blocked,
      blockedByOther: blockedByOther,
      onSetBlocked: uid == null || otherUid.isEmpty
          ? null
          : ({required blocked}) => ref
                .read(chatPrefsRepositoryProvider)
                .setBlocked(uid: uid, otherUid: otherUid, blocked: blocked),
      onClearChat: uid == null
          ? null
          : () => ref
                .read(chatPrefsRepositoryProvider)
                .clearThread(uid: uid, threadKey: threadKey),
      onDeleteChat: uid == null
          ? null
          : () => ref
                .read(chatPrefsRepositoryProvider)
                .deleteThread(uid: uid, threadKey: threadKey),
      subtitle: switch (phase) {
        ChatRequestPhase.waiting =>
          _isDriver ? 'Quiere hablar contigo' : 'Esperando respuesta',
        ChatRequestPhase.open => 'Antes de pedir la grúa',
        ChatRequestPhase.over => 'Conversación cerrada',
      },
      messages: messages,
      myUid: uid,
      canWrite: phase == ChatRequestPhase.open,
      closedNotice: _closedNotice(request, phase),
      emptyMessage: switch (phase) {
        ChatRequestPhase.waiting => _isDriver
            ? 'Acepta para empezar a chatear.'
            : 'Cuando el chofer acepte, podrás escribirle aquí.',
        ChatRequestPhase.open => _isDriver
            ? 'Pregúntale al cliente qué necesita.'
            : 'Pregúntale al chofer lo que necesites antes de pedir la grúa.',
        ChatRequestPhase.over => 'No hubo mensajes.',
      },
      photoPicker: ref.watch(photoPickerProvider),
      otherTyping: ref
              .watch(otherTypingProvider(requestThreadKey(widget.requestId)))
              .value ??
          false,
      onTyping: uid == null
          ? null
          : (typing) => unawaited(
                ref.read(typingRepositoryProvider).setTyping(
                      threadKey: requestThreadKey(widget.requestId),
                      uid: uid,
                      typing: typing,
                    ),
              ),
      onSendImage: uid == null
          ? null
          : (photo, clientMsgId) async {
              final chat = ref.read(chatRequestRepositoryProvider);
              final upload = await chat.uploadImage(
                requestId: widget.requestId,
                bytes: photo.bytes,
                contentType: photo.contentType,
              );
              final url = upload.valueOrNull;
              if (url == null) {
                return Result.err(
                  upload.failureOrNull ?? const Failure(FailureCode.unknown),
                );
              }
              final sent = await chat.sendMessage(
                requestId: widget.requestId,
                senderId: uid,
                senderRole: widget.role,
                text: '',
                clientMsgId: clientMsgId,
                imageUrl: url,
              );
              return sent;
            },
      banner: phase != ChatRequestPhase.waiting
          ? null
          : _isDriver
              ? _AnswerBanner(
                  clientName: title,
                  busy: _busy,
                  onAccept: () => _respond(accept: true),
                  onDecline: () => _respond(accept: false),
                )
              : _WaitingBanner(busy: _busy, onCancel: _close),
      onSend: (text, clientMsgId) {
        if (uid == null) {
          return Future.value(
            const Result.err(Failure(FailureCode.unauthenticated)),
          );
        }
        return ref.read(chatRequestRepositoryProvider).sendMessage(
              requestId: widget.requestId,
              senderId: uid,
              senderRole: widget.role,
              text: text,
              clientMsgId: clientMsgId,
            );
      },
      onDeleteMessages: uid == null
          ? null
          : (ids) => ref.read(chatRequestRepositoryProvider).deleteMessages(
              requestId: widget.requestId,
              senderId: uid,
              messageIds: ids,
            ),
      onDownloadImages: openChatImages,
      onMarkRead: uid == null
          ? null
          : () => ref
              .read(chatRequestRepositoryProvider)
              .markRead(widget.requestId, uid),
    );
  }

  String _closedNotice(ChatRequest request, ChatRequestPhase phase) {
    if (phase == ChatRequestPhase.waiting) {
      return _isDriver
          ? 'Acepta la solicitud para responder.'
          : 'Podrás escribir cuando el chofer acepte.';
    }
    return switch (request.status) {
      ChatRequestStatus.declined => _isDriver
          ? 'Rechazaste esta solicitud.'
          : 'El chofer no puede chatear ahora. Prueba con otra grúa.',
      ChatRequestStatus.cancelled => _isDriver
          ? 'El cliente canceló la solicitud.'
          : 'Cancelaste esta solicitud.',
      ChatRequestStatus.pending => 'La solicitud venció sin respuesta.',
      _ => 'Esta conversación terminó.',
    };
  }
}

/// The chofer's side of a waiting request: who asks, and the two answers.
class _AnswerBanner extends StatelessWidget {
  const _AnswerBanner({
    required this.clientName,
    required this.busy,
    required this.onAccept,
    required this.onDecline,
  });

  final String clientName;
  final bool busy;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return FloatingCard(
      key: const Key('chat-request-answer'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('$clientName quiere chatear contigo', style: text.titleSmall),
          const SizedBox(height: Insets.xs),
          Text(
            'Es un cliente cerca de ti. Todavía no ha pedido la grúa.',
            style: text.bodySmall?.copyWith(color: BrandColors.grey600),
          ),
          const SizedBox(height: Insets.md),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  key: const Key('chat-request-decline'),
                  onPressed: busy ? null : onDecline,
                  child: const Text('RECHAZAR'),
                ),
              ),
              const SizedBox(width: Insets.md),
              Expanded(
                child: ElevatedButton(
                  key: const Key('chat-request-accept'),
                  onPressed: busy ? null : onAccept,
                  child: busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: BrandColors.white,
                          ),
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

/// The customer's side of a waiting request.
class _WaitingBanner extends StatelessWidget {
  const _WaitingBanner({required this.busy, required this.onCancel});

  final bool busy;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return FloatingCard(
      key: const Key('chat-request-waiting'),
      child: Row(
        children: [
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Esperando que el chofer acepte…', style: text.titleSmall),
                Text(
                  'Le avisamos al chofer de esta grúa. Tiene unos minutos '
                  'para responder.',
                  style: text.bodySmall?.copyWith(color: BrandColors.grey600),
                ),
              ],
            ),
          ),
          TextButton(
            key: const Key('chat-request-cancel'),
            onPressed: busy ? null : onCancel,
            child: const Text('Cancelar'),
          ),
        ],
      ),
    );
  }
}
