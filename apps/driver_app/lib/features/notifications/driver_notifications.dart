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
}

@immutable
class DriverNotification {
  const DriverNotification({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.serviceId,
    required this.at,
    this.read = false,
  });

  final String id;
  final DriverNotificationKind kind;
  final String title;
  final String body;
  final String serviceId;
  final DateTime at;
  final bool read;

  DriverNotification markedRead() => DriverNotification(
    id: id,
    kind: kind,
    title: title,
    body: body,
    serviceId: serviceId,
    at: at,
    read: true,
  );
}

/// The job in progress and its conversation, for spotting new messages.
/// `messages` is null until the thread has loaded.
final _activeChatProvider =
    Provider<({Service? service, List<ChatMessage>? messages})>((ref) {
      final service = ref.watch(activeDriverServiceProvider).value;
      if (service == null) return (service: null, messages: null);
      return (
        service: service,
        messages: ref.watch(serviceMessagesProvider(service.id)).value,
      );
    });

/// The chofer's notifications, newest first.
///
/// Built from the streams the app already listens to — the open offer, the
/// open work, the customer's messages — so a notification appears the moment
/// the thing it announces does, with no extra reads. What was already there
/// when the app loaded counts as seen: this announces what *arrives*, and the
/// tabs' own badges cover what is waiting.
///
/// Held for the session. The push inbox at `users/{uid}/notifications`, for
/// what arrives while the app is closed, is the server's to write.
class DriverNotificationsController extends Notifier<List<DriverNotification>> {
  static const _limit = 50;

  final _seenOrders = <String>{};
  var _ordersPrimed = false;
  final _seenMessages = <String>{};
  final _chatPrimedFor = <String>{};

  @override
  List<DriverNotification> build() {
    // A different account starts with an empty list.
    ref.watch(currentUserIdProvider);
    _seenOrders.clear();
    _ordersPrimed = false;
    _seenMessages.clear();
    _chatPrimedFor.clear();

    ref
      ..listen<Offer?>(openOfferProvider, _onOffer)
      ..listen<AsyncValue<List<Service>>>(
        activeServicesProvider,
        (_, next) => _onOrders(next),
      )
      ..listen(_activeChatProvider, (_, next) => _onChat(next));

    // Prime with what is already loaded. Nothing is announced from here, so
    // no state is set while building.
    _onOrders(ref.read(activeServicesProvider));
    _onChat(ref.read(_activeChatProvider));
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
        serviceId: next.serviceId,
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
          serviceId: service.id,
          at: clock.now().toUtc(),
        ),
      );
    }
  }

  void _onChat(({Service? service, List<ChatMessage>? messages}) chat) {
    final service = chat.service;
    final messages = chat.messages;
    final uid = ref.read(currentUserIdProvider);
    if (service == null || messages == null || uid == null) return;

    if (_chatPrimedFor.add(service.id)) {
      _seenMessages.addAll(messages.map((m) => '${service.id}/${m.id}'));
      return;
    }

    for (final message in messages) {
      if (!_seenMessages.add('${service.id}/${message.id}')) continue;
      if (message.isMine(uid) || message.isRead) continue;
      _push(
        DriverNotification(
          id: 'chat-${service.id}-${message.id}',
          kind: DriverNotificationKind.chat,
          title: service.clientName.isEmpty
              ? 'Mensaje de tu cliente'
              : 'Mensaje de ${service.clientName}',
          body: message.text,
          serviceId: service.id,
          at: message.sentAt ?? clock.now().toUtc(),
        ),
      );
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
