import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

/// What a customer's notification is about, which decides its glyph and where
/// tapping it leads.
enum ClientNotificationKind {
  /// A message from the chofer of the tow in progress.
  chat,

  /// A message in a conversation opened from a truck on the map.
  requestMessage,

  /// The chofer answered a chat request: the conversation is open.
  requestAnswered,
}

@immutable
class ClientNotification {
  const ClientNotification({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.targetId,
    required this.at,
  });

  final String id;
  final ClientNotificationKind kind;
  final String title;
  final String body;

  /// The service for a job's chat, the request for the other two.
  final String targetId;
  final DateTime at;

  bool get isRequest => kind != ClientNotificationKind.chat;
}

typedef _Thread = ({
  String key,
  String driverName,
  String targetId,
  List<ChatMessage>? messages,
});

/// The tow in progress and its conversation. `messages` is null until the
/// thread has loaded.
final _jobThreadProvider = Provider<_Thread?>((ref) {
  final service = ref.watch(activeClientServiceProvider).value;
  if (service == null) return null;
  return (
    key: 'job:${service.id}',
    driverName: service.driverName,
    targetId: service.id,
    messages: ref.watch(serviceMessagesProvider(service.id)).value,
  );
});

/// Every conversation with a chofer who accepted a chat request.
final _requestThreadsProvider = Provider<List<_Thread>>((ref) {
  final requests = ref.watch(clientChatRequestsProvider).value ?? const [];
  return [
    for (final request in requests)
      if (request.status == ChatRequestStatus.accepted)
        (
          key: 'request:${request.id}',
          driverName: request.driverName,
          targetId: request.id,
          messages: ref.watch(chatRequestMessagesProvider(request.id)).value,
        ),
  ];
});

/// The customer's notifications, newest first.
///
/// The chofer's side has had these since the bell went in; this is the same
/// idea from the customer's chair, minus the bell — a customer has no list to
/// keep, only the banner that says a message arrived and takes them to it.
///
/// Built from streams the app already watches, so nothing costs an extra read.
/// What was already loaded counts as seen: this announces what *arrives*.
class ClientNotificationsController
    extends Notifier<List<ClientNotification>> {
  static const _limit = 30;

  final _seenMessages = <String>{};
  final _primedThreads = <String>{};
  final _answeredRequests = <String>{};
  var _requestsPrimed = false;

  @override
  List<ClientNotification> build() {
    // A different account starts with an empty list.
    ref.watch(currentUserIdProvider);
    _seenMessages.clear();
    _primedThreads.clear();
    _answeredRequests.clear();
    _requestsPrimed = false;

    ref
      ..listen<AsyncValue<List<ChatRequest>>>(
        clientChatRequestsProvider,
        (_, next) => _onRequests(next),
      )
      ..listen<_Thread?>(_jobThreadProvider, (_, next) => _onThreads([?next]))
      ..listen<List<_Thread>>(
        _requestThreadsProvider,
        (_, next) => _onThreads(next),
      );

    // Prime with what is already loaded. Nothing is announced from here, so
    // no state is set while building.
    _onRequests(ref.read(clientChatRequestsProvider));
    _onThreads([
      ?ref.read(_jobThreadProvider),
      ...ref.read(_requestThreadsProvider),
    ]);
    return const [];
  }

  /// A chofer answering is news in itself: the customer asked and has been
  /// waiting, and there is nothing else on their screen that says so.
  void _onRequests(AsyncValue<List<ChatRequest>> requests) {
    if (!requests.hasValue) return;
    final all = requests.value ?? const <ChatRequest>[];

    if (!_requestsPrimed) {
      _answeredRequests.addAll(
        all
            .where((r) => r.status == ChatRequestStatus.accepted)
            .map((r) => r.id),
      );
      _requestsPrimed = true;
      return;
    }

    for (final request in all) {
      if (request.status != ChatRequestStatus.accepted) continue;
      if (!_answeredRequests.add(request.id)) continue;
      final who = request.driverName.isEmpty
          ? 'El chofer'
          : request.driverName;
      _push(
        ClientNotification(
          id: 'request-answered-${request.id}',
          kind: ClientNotificationKind.requestAnswered,
          title: 'La grúa te respondió',
          body: '$who aceptó tu solicitud de chat',
          targetId: request.id,
          at: request.respondedAt ?? clock.now().toUtc(),
        ),
      );
    }
  }

  void _onThreads(List<_Thread> threads) {
    final uid = ref.read(currentUserIdProvider);
    if (uid == null) return;

    for (final thread in threads) {
      final messages = thread.messages;
      if (messages == null) continue;

      // The first load of a thread is what was already said.
      if (_primedThreads.add(thread.key)) {
        _seenMessages.addAll(messages.map((m) => '${thread.key}/${m.id}'));
        continue;
      }

      final isJob = thread.key.startsWith('job:');
      for (final message in messages) {
        if (!_seenMessages.add('${thread.key}/${message.id}')) continue;
        if (message.isMine(uid) || message.isRead) continue;
        _push(
          ClientNotification(
            id: '${thread.key}/${message.id}',
            kind: isJob
                ? ClientNotificationKind.chat
                : ClientNotificationKind.requestMessage,
            title: thread.driverName.isEmpty
                ? 'Mensaje del chofer'
                : 'Mensaje de ${thread.driverName}',
            // A photo with no words still has to say something.
            body: message.text.isEmpty && message.hasImage
                ? 'Te envió una foto'
                : message.text,
            targetId: thread.targetId,
            at: message.sentAt ?? clock.now().toUtc(),
          ),
        );
      }
    }
  }

  void _push(ClientNotification notification) {
    if (state.any((n) => n.id == notification.id)) return;
    state = [notification, ...state].take(_limit).toList();
  }
}

final clientNotificationsProvider =
    NotifierProvider<ClientNotificationsController, List<ClientNotification>>(
      ClientNotificationsController.new,
    );

/// The glyph on the banner, by what it announces.
class ClientNotificationGlyph extends StatelessWidget {
  const ClientNotificationGlyph({required this.kind, super.key});

  final ClientNotificationKind kind;

  @override
  Widget build(BuildContext context) {
    final (icon, color, background) = switch (kind) {
      ClientNotificationKind.requestAnswered => (
        Icons.local_shipping,
        BrandColors.success,
        BrandColors.successTint,
      ),
      _ => (Icons.chat_bubble, BrandColors.info, BrandColors.infoTint),
    };

    return NotificationGlyph(
      icon: icon,
      color: color,
      background: background,
    );
  }
}
