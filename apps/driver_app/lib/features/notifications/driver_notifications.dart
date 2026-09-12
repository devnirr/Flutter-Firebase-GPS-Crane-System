import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

import '../home/offer_card.dart';
import '../orders/orders_screen.dart';

/// What a notification is about, which decides its icon and where it leads.
enum DriverNotificationKind {
  /// A request the server is offering this chofer, and nobody else.
  offer,

  /// Open work in the chofer's truck class, on the Pedidos tab.
  order,

  /// A message from the customer of the job in progress.
  chat,

  /// A customer near the truck asking to talk, before any job.
  chatRequest,

  /// A message in a conversation opened from a chat request.
  requestMessage,
}

@immutable
class DriverNotification {
  const DriverNotification({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.targetId,
    required this.at,
    this.read = false,
  });

  final String id;
  final DriverNotificationKind kind;
  final String title;
  final String body;

  /// What it leads to: the service for an offer, an order or a job's chat;
  /// the chat request for the other two.
  final String targetId;
  final DateTime at;
  final bool read;

  DriverNotification markedRead() => DriverNotification(
    id: id,
    kind: kind,
    title: title,
    body: body,
    targetId: targetId,
    at: at,
    read: true,
  );
}

typedef _Thread = ({String key, String clientName, String targetId, List<ChatMessage>? messages});

/// The job in progress and its conversation, for spotting new messages.
/// `messages` is null until the thread has loaded.
final _jobThreadProvider = Provider<_Thread?>((ref) {
  final service = ref.watch(activeDriverServiceProvider).value;
  if (service == null) return null;
  return (
    key: 'job:${service.id}',
    clientName: service.clientName,
    targetId: service.id,
    messages: ref.watch(serviceMessagesProvider(service.id)).value,
  );
});

/// Every conversation opened from a chat request the chofer accepted.
final _requestThreadsProvider = Provider<List<_Thread>>((ref) {
  final requests = ref.watch(driverChatRequestsProvider).value ?? const [];
  return [
    for (final request in requests)
      if (request.status == ChatRequestStatus.accepted)
        (
          key: 'request:${request.id}',
          clientName: request.clientName,
          targetId: request.id,
          messages: ref.watch(chatRequestMessagesProvider(request.id)).value,
        ),
  ];
});

/// The chofer's notifications, newest first.
///
/// Built from the streams the app already listens to — the open offer, the
/// open work, chat requests and the customers' messages — so a notification
/// appears the moment the thing it announces does, with no extra reads. What
/// was already there when the app loaded counts as seen: this announces what
/// *arrives*, and the tabs' own badges cover what is waiting.
///
/// Held for the session. The push inbox at `users/{uid}/notifications`, for
/// what arrives while the app is closed, is the server's to write.
class DriverNotificationsController extends Notifier<List<DriverNotification>> {
  static const _limit = 50;

  final _seenOrders = <String>{};
  var _ordersPrimed = false;
  final _seenRequests = <String>{};
  var _requestsPrimed = false;
  final _seenMessages = <String>{};
  final _primedThreads = <String>{};

  @override
  List<DriverNotification> build() {
    // A different account starts with an empty list.
    ref.watch(currentUserIdProvider);
    _seenOrders.clear();
    _ordersPrimed = false;
    _seenRequests.clear();
    _requestsPrimed = false;
    _seenMessages.clear();
    _primedThreads.clear();

    ref
      ..listen<Offer?>(openOfferProvider, _onOffer)
      ..listen<AsyncValue<List<Service>>>(
        activeServicesProvider,
        (_, next) => _onOrders(next),
      )
      ..listen<AsyncValue<List<ChatRequest>>>(
        driverChatRequestsProvider,
        (_, next) => _onRequests(next),
      )
      ..listen<_Thread?>(_jobThreadProvider, (_, next) => _onThreads([?next]))
      ..listen<List<_Thread>>(_requestThreadsProvider, (_, next) => _onThreads(next));

    // Prime with what is already loaded. Nothing is announced from here, so
    // no state is set while building.
    _onOrders(ref.read(activeServicesProvider));
    _onRequests(ref.read(driverChatRequestsProvider));
    _onThreads([?ref.read(_jobThreadProvider), ...ref.read(_requestThreadsProvider)]);
    return const [];
  }

  void _onOffer(Offer? previous, Offer? next) {
    if (next == null || next.serviceId == previous?.serviceId) return;
    _push(
      DriverNotification(
        id: 'offer-${next.serviceId}',
        kind: DriverNotificationKind.offer,
        title: 'Nueva solicitud de servicio',
        body: [
          if (next.vehicleLabel.isNotEmpty) next.vehicleLabel,
          if (next.pickupAddress.isNotEmpty) next.pickupAddress,
          '${next.netEarningsCents.formatDOP} para ti',
        ].join(' · '),
        targetId: next.serviceId,
        at: clock.now().toUtc(),
      ),
    );
  }

  void _onOrders(AsyncValue<List<Service>> services) {
    if (!services.hasValue) return;
    final available = ref.read(availableOrdersProvider);

    if (!_ordersPrimed) {
      _seenOrders.addAll(available.map((s) => s.id));
      _ordersPrimed = true;
      return;
    }

    // Offline, open work is not the chofer's to take; it is marked seen so
    // going online later does not replay it.
    final online = ref.read(currentDriverProvider).value?.isOnline ?? false;
    for (final service in available) {
      if (!_seenOrders.add(service.id) || !online) continue;
      _push(
        DriverNotification(
          id: 'order-${service.id}',
          kind: DriverNotificationKind.order,
          title: 'Nuevo pedido disponible',
          body:
              '${service.vehicle.displayName} · '
              '${service.pickup.displayAddress}',
          targetId: service.id,
          at: clock.now().toUtc(),
        ),
      );
    }
  }

  void _onRequests(AsyncValue<List<ChatRequest>> requests) {
    if (!requests.hasValue) return;
    final all = requests.value ?? const <ChatRequest>[];

    if (!_requestsPrimed) {
      _seenRequests.addAll(all.map((r) => r.id));
      _requestsPrimed = true;
      return;
    }

    final now = clock.now().toUtc();
    for (final request in all) {
      if (!_seenRequests.add(request.id)) continue;
      if (request.phaseAt(now) != ChatRequestPhase.waiting) continue;
      final who = request.clientName.isEmpty ? 'Un cliente' : request.clientName;
      _push(
        DriverNotification(
          id: 'chat-request-${request.id}',
          kind: DriverNotificationKind.chatRequest,
          title: 'Solicitud de chat',
          body: '$who quiere hablar contigo',
          targetId: request.id,
          at: request.createdAt ?? now,
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
          DriverNotification(
            id: '${thread.key}/${message.id}',
            kind: isJob
                ? DriverNotificationKind.chat
                : DriverNotificationKind.requestMessage,
            title: thread.clientName.isEmpty
                ? 'Mensaje de tu cliente'
                : 'Mensaje de ${thread.clientName}',
            body: message.text,
            targetId: thread.targetId,
            at: message.sentAt ?? clock.now().toUtc(),
          ),
        );
      }
    }
  }

  void _push(DriverNotification notification) {
    if (state.any((n) => n.id == notification.id)) return;
    state = [notification, ...state].take(_limit).toList();
  }

  void markRead(String id) {
    if (!state.any((n) => n.id == id && !n.read)) return;
    state = state.map((n) => n.id == id ? n.markedRead() : n).toList();
  }

  /// Clears everything one conversation put under the bell.
  ///
  /// Reading a message in the chat is reading it. Leaving the bell counting it
  /// afterwards is a badge the chofer cannot get rid of by doing the obvious
  /// thing, which is the complaint that put this here.
  void markThreadRead(String targetId) {
    if (!state.any((n) => n.targetId == targetId && !n.read)) return;
    state = state
        .map((n) => n.targetId == targetId ? n.markedRead() : n)
        .toList();
  }

  void markAllRead() {
    if (state.every((n) => n.read)) return;
    state = state.map((n) => n.markedRead()).toList();
  }
}

final driverNotificationsProvider =
    NotifierProvider<DriverNotificationsController, List<DriverNotification>>(
      DriverNotificationsController.new,
    );

/// The count on the bell.
final unreadNotificationCountProvider = Provider<int>(
  (ref) => ref.watch(driverNotificationsProvider).where((n) => !n.read).length,
);
