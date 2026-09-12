import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/enums.dart';
import '../domain/failures.dart';
import '../domain/models/dispatch_models.dart';
import '../domain/repositories.dart';
import '../media/photo_picker.dart';
import '../providers.dart';
import '../theme/brand.dart';
import '../theme/widgets/brand_widgets.dart';
import '../utils/date_time_do.dart';

/// Chat between the customer and the assigned chofer of a job, in both apps.
///
/// Messages are written straight to Firestore rather than through a callable,
/// so they land instantly; the rules restrict who may post and a trigger sends
/// the push. Quick replies exist because at least one side is driving.
///
/// [role] is who is holding the phone: it decides whose name is in the title,
/// which quick replies are offered, and the role stamped on each message.
class ServiceChatScreen extends ConsumerWidget {
  const ServiceChatScreen({
    required this.serviceId,
    required this.role,
    super.key,
  });

  final String serviceId;
  final UserRole role;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDriver = role == UserRole.driver;
    final uid = ref.watch(currentUserIdProvider);
    final service = ref.watch(serviceByIdProvider(serviceId)).value;
    final messages =
        ref.watch(serviceMessagesProvider(serviceId)).value ?? const [];

    // The person on the other end of the conversation.
    final otherName =
        (isDriver ? service?.clientName : service?.driverName) ?? '';

    return ChatThreadView(
      title: otherName.isNotEmpty
          ? otherName
          : (isDriver ? 'Cliente' : 'Chofer'),
      subtitle: service?.status.label,
      messages: messages,
      myUid: uid,
      canWrite: service?.canChat ?? false,
      closedNotice: 'El chat se cierra cuando termina el servicio.',
      emptyMessage: isDriver
          ? 'Escríbele al cliente si necesitas alguna indicación para '
              'encontrarlo.'
          : 'Escríbele al chofer si necesitas darle alguna indicación.',
      photoPicker: ref.watch(photoPickerProvider),
      otherTyping:
          ref.watch(otherTypingProvider(jobThreadKey(serviceId))).value ?? false,
      onTyping: uid == null
          ? null
          : (typing) => unawaited(
                ref.read(typingRepositoryProvider).setTyping(
                      threadKey: jobThreadKey(serviceId),
                      uid: uid,
                      typing: typing,
                    ),
              ),
      onSendImage: uid == null
          ? null
          : (photo, clientMsgId) async {
              final chat = ref.read(chatRepositoryProvider);
              final upload = await chat.uploadImage(
                serviceId: serviceId,
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
                serviceId: serviceId,
                senderId: uid,
                senderRole: role,
                text: '',
                clientMsgId: clientMsgId,
                imageUrl: url,
              );
              return sent;
            },
      onSend: (text, clientMsgId) {
        if (uid == null) {
          return Future.value(
            const Result.err(Failure(FailureCode.unauthenticated)),
          );
        }
        return ref.read(chatRepositoryProvider).sendMessage(
              serviceId: serviceId,
              senderId: uid,
              senderRole: role,
              text: text,
              clientMsgId: clientMsgId,
            );
      },
      onMarkRead: uid == null
          ? null
          : () => ref.read(chatRepositoryProvider).markRead(serviceId, uid),
    );
  }
}

/// A conversation on screen: bubbles, quick replies and the composer.
///
/// Shared by a job's chat and a chat request's, which differ only in where
/// the messages live and when writing is allowed. Having the thread open is
/// what reading it means, so the other side's messages are marked read as
/// they arrive — that is what clears the badges elsewhere.
class ChatThreadView extends StatefulWidget {
  const ChatThreadView({
    required this.title,
    required this.messages,
    required this.myUid,
    required this.canWrite,
    required this.closedNotice,
    required this.emptyMessage,
    required this.onSend,
    this.subtitle,
    this.onMarkRead,
    this.banner,
    this.actions = const [],
    this.photoPicker,
    this.onSendImage,
    this.otherTyping = false,
    this.onTyping,
    super.key,
  });

  final String title;
  final String? subtitle;
  final List<ChatMessage> messages;
  final String? myUid;

  /// Whether the composer shows. When not, [closedNotice] says why.
  final bool canWrite;
  final String closedNotice;
  final String emptyMessage;
  final Future<Result<void>> Function(String text, String clientMsgId) onSend;
  final Future<Object?> Function()? onMarkRead;

  /// Shown above the messages — an answer to give, or one being waited for.
  final Widget? banner;
  final List<Widget> actions;

  /// How a photo comes off the phone. With [onSendImage], puts a clip on the
  /// composer; without either, the conversation is words only.
  final PhotoPicker? photoPicker;
  final Future<Result<void>> Function(PickedPhoto photo, String clientMsgId)?
      onSendImage;

  /// The other side is typing right now: says so in place of the subtitle.
  final bool otherTyping;

  /// Called as this side starts and stops typing. Throttled here, so it is
  /// safe to write straight to the backend from it.
  final ValueChanged<bool>? onTyping;

  @override
  State<ChatThreadView> createState() => _ChatThreadViewState();
}

class _ChatThreadViewState extends State<ChatThreadView> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  var _sending = false;

  /// A markRead is in flight; the stream echoes each stamp, and without this
  /// every echo would start another one.
  var _markingRead = false;

  /// When this side last said it was typing, and the timer that takes it back.
  ///
  /// Typing is announced at most every [_typingPing] and withdrawn after
  /// [_typingIdle] of quiet, so a long message costs a handful of writes
  /// rather than one per keystroke.
  static const _typingPing = Duration(seconds: 4);
  static const _typingIdle = Duration(seconds: 3);
  DateTime? _typingSince;
  Timer? _typingStop;

  @override
  void initState() {
    super.initState();
    _scheduleMarkRead();
  }

  @override
  void didUpdateWidget(ChatThreadView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.messages, widget.messages)) _scheduleMarkRead();
  }

  @override
  void dispose() {
    // Leaving the screen is not typing. Said before the state goes, so the
    // other side's indicator does not hang on an empty conversation.
    _typingStop?.cancel();
    if (_typingSince != null) widget.onTyping?.call(false);
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onComposerChanged(String value) {
    if (widget.onTyping == null) return;
    if (value.trim().isEmpty) {
      _stopTyping();
      return;
    }

    final now = DateTime.now();
    if (_typingSince == null || now.difference(_typingSince!) > _typingPing) {
      _typingSince = now;
      widget.onTyping?.call(true);
    }
    _typingStop?.cancel();
    _typingStop = Timer(_typingIdle, _stopTyping);
  }

  void _stopTyping() {
    _typingStop?.cancel();
    _typingStop = null;
    if (_typingSince == null) return;
    _typingSince = null;
    widget.onTyping?.call(false);
  }

  void _scheduleMarkRead() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _markingRead) return;
      final uid = widget.myUid;
      final markRead = widget.onMarkRead;
      if (uid == null || markRead == null) return;
      if (!widget.messages.any((m) => !m.isMine(uid) && !m.isRead)) return;

      _markingRead = true;
      unawaited(markRead().whenComplete(() => _markingRead = false));
    });
  }

  Future<void> _send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _sending) return;

    setState(() => _sending = true);
    _controller.clear();
    // A sent message is the end of typing it.
    _stopTyping();

    // Lets an optimistic bubble reconcile with the server echo, and stops a
    // retry on bad signal from duplicating the message.
    final clientMsgId =
        '${widget.myUid ?? 'anon'}-${DateTime.now().microsecondsSinceEpoch}';
    final result = await widget.onSend(trimmed, clientMsgId);

    if (!mounted) return;
    setState(() => _sending = false);

    result.fold(
      (_) => _scrollToBottom(),
      (failure) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(failure.userMessage)),
      ),
    );
  }

  /// Camera or gallery, then upload and send. The bubble appears when the
  /// photo is in the bucket, so nothing half-sent shows in the conversation.
  Future<void> _attach() async {
    final picker = widget.photoPicker;
    final send = widget.onSendImage;
    if (picker == null || send == null || _sending) return;

    final source = await askPhotoSource(context);
    if (source == null || !mounted) return;
    final photo = await picker(source);
    if (photo == null || !mounted) return;

    // The ceiling storage.rules puts on a chat photo, said here rather than as
    // a refused upload after the wait.
    if (photo.bytes.lengthInBytes > 5 * 1024 * 1024) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('La foto pesa ${photo.sizeLabel}. Máximo 5 MB.'),
        ),
      );
      return;
    }

    setState(() => _sending = true);
    final result = await send(
      photo,
      '${widget.myUid ?? 'anon'}-${DateTime.now().microsecondsSinceEpoch}',
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
    final uid = widget.myUid;
    final messages = widget.messages;
    final subtitle = widget.subtitle;

    return Scaffold(
      backgroundColor: BrandColors.offWhite,
      appBar: AppBar(
        title: Column(
          children: [
            Text(widget.title, style: Theme.of(context).textTheme.titleMedium),
            if (subtitle != null && subtitle.isNotEmpty)
              Text(
                subtitle,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: BrandColors.grey600),
              ),
          ],
        ),
        actions: widget.actions,
      ),
      body: Column(
        children: [
          if (widget.banner != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Insets.lg,
                Insets.md,
                Insets.lg,
                0,
              ),
              child: widget.banner,
            ),
          Expanded(
            child: messages.isEmpty
                ? EmptyState(
                    title: 'Sin mensajes',
                    message: widget.emptyMessage,
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
          if (widget.canWrite) ...[
            if (widget.otherTyping) const _TypingLine(),
            _Composer(
              controller: _controller,
              sending: _sending,
              onSend: () => _send(_controller.text),
              onAttach: widget.photoPicker == null || widget.onSendImage == null
                  ? null
                  : _attach,
              onChanged: widget.onTyping == null ? null : _onComposerChanged,
            ),
          ] else
            _ChatClosedNotice(text: widget.closedNotice),
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
            if (message.hasImage) ...[
              _ChatImage(url: message.imageUrl),
              if (message.text.isNotEmpty) const SizedBox(height: Insets.sm),
            ],
            if (message.text.isNotEmpty)
              Text(
                message.text,
                style: text.bodyMedium?.copyWith(
                  color: isMine ? BrandColors.white : BrandColors.ink,
                ),
              ),
            const SizedBox(height: 3),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  message.isPending
                      ? 'Enviando…'
                      : DoTime.time(message.sentAt ?? DateTime.now().toUtc()),
                  style: text.bodySmall?.copyWith(
                    fontSize: 10,
                    color: isMine ? Colors.white70 : BrandColors.grey400,
                  ),
                ),
                // Only on your own messages: the other side's tell you nothing.
                if (isMine) ...[
                  const SizedBox(width: Insets.xs),
                  _DeliveryTick(message: message),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Where a message of yours has got to: waiting to leave the phone, on the
/// server, or seen by the other side.
///
/// One grey-white check means the server has it. Two blue checks mean it was
/// read — the same shorthand every messaging app has taught people to expect,
/// which is why it needs no legend.
class _DeliveryTick extends StatelessWidget {
  const _DeliveryTick({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    if (message.isPending) {
      return const Icon(
        Icons.schedule,
        key: Key('tick-pending'),
        size: 13,
        color: Colors.white70,
      );
    }
    if (!message.isRead) {
      return const Icon(
        Icons.check,
        key: Key('tick-sent'),
        size: 14,
        color: Colors.white70,
      );
    }
    return const Icon(
      Icons.done_all,
      key: Key('tick-read'),
      size: 14,
      color: BrandColors.readTick,
    );
  }
}

/// "Escribiendo…", right above the box — where the words are about to land,
/// rather than up beside the name where a glance does not go.
class _TypingLine extends StatelessWidget {
  const _TypingLine();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: BrandColors.white,
      padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.sm, Insets.lg, 0),
      child: Text(
        'Escribiendo…',
        key: const Key('typing-indicator'),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: BrandColors.success,
              fontWeight: FontWeight.w600,
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
    this.onAttach,
    this.onChanged,
  });

  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;
  final VoidCallback? onAttach;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: BrandColors.white,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Insets.sm,
            Insets.md,
            Insets.lg,
            Insets.md,
          ),
          child: Row(
            children: [
              if (onAttach != null)
                IconButton(
                  key: const Key('chat-attach'),
                  tooltip: 'Enviar una foto',
                  onPressed: sending ? null : onAttach,
                  icon: const Icon(
                    Icons.attach_file,
                    color: BrandColors.grey600,
                  ),
                ),
              Expanded(
                child: TextField(
                  controller: controller,
                  minLines: 1,
                  maxLines: 4,
                  maxLength: 1000,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: onChanged,
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
      ),
    );
  }
}

/// A photo in a bubble, opening full-screen on a tap.
///
/// Two sources, as everywhere else that shows an uploaded image: a real
/// download URL in production, and a data URI in demo mode, which has no
/// bucket to upload to.
class _ChatImage extends StatelessWidget {
  const _ChatImage({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => unawaited(
        showDialog<void>(
          context: context,
          builder: (context) => _ImageViewer(url: url),
        ),
      ),
      child: ClipRRect(
        borderRadius: Corners.brSm,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 240),
          child: chatImage(url, fit: BoxFit.cover),
        ),
      ),
    );
  }
}

class _ImageViewer extends StatelessWidget {
  const _ImageViewer({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              maxScale: 5,
              child: Center(child: chatImage(url, fit: BoxFit.contain)),
            ),
          ),
          SafeArea(
            child: IconButton(
              tooltip: 'Cerrar',
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close, color: BrandColors.white),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown in place of a photo that will not load or decode.
const _brokenImage = Padding(
  padding: EdgeInsets.all(Insets.lg),
  child: Icon(Icons.broken_image_outlined, color: BrandColors.grey400),
);

/// Renders a chat photo from a download URL or a demo data URI.
Widget chatImage(String url, {BoxFit fit = BoxFit.cover}) {
  Widget broken(BuildContext _, Object _, StackTrace? _) => _brokenImage;

  // Demo mode has no bucket, so its photos travel as data URIs.
  if (url.startsWith('data:')) {
    final bytes = Uri.tryParse(url)?.data?.contentAsBytes();
    if (bytes == null) return _brokenImage;
    return Image.memory(bytes, fit: fit, errorBuilder: broken);
  }
  return Image.network(
    url,
    fit: fit,
    // The web renderer decodes images itself, which needs CORS headers the
    // bucket does not send by default; an <img> element needs none.
    webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
    errorBuilder: broken,
  );
}

class _ChatClosedNotice extends StatelessWidget {
  const _ChatClosedNotice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: BrandColors.white,
      padding: const EdgeInsets.all(Insets.lg),
      child: SafeArea(
        child: Text(
          text,
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
