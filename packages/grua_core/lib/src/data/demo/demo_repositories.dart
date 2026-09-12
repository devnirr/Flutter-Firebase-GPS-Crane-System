// Every method in this file returns an already-built future from `_delayed` or
// a synchronous backend call. Awaiting each one before returning it would add a
// microtask and no meaning.
// ignore_for_file: async_return_with_no_await

import 'dart:async';
import 'dart:typed_data';

import '../../domain/enums.dart';
import '../../domain/failures.dart';
import '../../domain/models/app_user.dart';
import '../../domain/models/billing.dart';
import '../../domain/models/chat_prefs.dart';
import '../../domain/models/chat_request.dart';
import '../../domain/models/dispatch_models.dart';
import '../../domain/models/driver.dart';
import '../../domain/models/remote_config_models.dart';
import '../../domain/models/service.dart';
import '../../domain/models/truck.dart';
import '../../domain/repositories.dart';
import '../../domain/value_objects.dart';
import '../pricing.dart';
import 'demo_backend.dart';

/// Repository implementations backed by [DemoBackend].
///
/// Every one satisfies the same contract as its Firestore counterpart, so
/// swapping between demo and real is a single provider override and no screen
/// changes. Latency is simulated deliberately — a UI that has only ever seen
/// instant responses hides every missing loading state.

const _latency = Duration(milliseconds: 320);

Future<T> _delayed<T>(T value) =>
    Future<T>.delayed(_latency, () => value);

class DemoAuthRepository implements AuthRepository {
  DemoAuthRepository(this._backend, {this.role = UserRole.client}) {
    _controller.add(_backend.currentUserId);
  }

  final DemoBackend _backend;

  /// The claim this demo session presents. Swapped per app.
  final UserRole role;
  final _controller = StreamController<String?>.broadcast();

  String? _userId;
  String? _pendingPhone;

  @override
  String? get currentUserId => _userId;

  @override
  Stream<String?> watchUserId() async* {
    yield _userId;
    yield* _controller.stream;
  }

  @override
  Future<UserRole> currentRole({bool forceRefresh = false}) async => role;

  @override
  Future<Result<String>> startPhoneVerification(String e164Phone) async {
    _pendingPhone = e164Phone;
    // Any six digits are accepted in demo mode; the code is never sent.
    return _delayed(const Result.ok('demo-verification-id'));
  }

  @override
  Future<Result<void>> confirmSmsCode({
    required String verificationId,
    required String smsCode,
  }) async {
    if (smsCode.length != 6) {
      return _delayed(
        const Result.err(Failure(FailureCode.invalidInput,
            message: 'El código debe tener 6 dígitos.')),
      );
    }
    _userId = _backend.currentUserId;
    final existing = _backend.user(_userId!);
    if (existing != null && _pendingPhone != null) {
      _backend.upsertUser(existing.copyWith(phone: _pendingPhone!));
    }
    _controller.add(_userId);
    return _delayed(const Result.ok(null));
  }

  @override
  Future<Result<void>> signInWithEmail(String email, String password) async {
    if (password.length < 4) {
      return _delayed(
        const Result.err(Failure(FailureCode.invalidInput,
            message: 'Usuario o contraseña incorrectos.')),
      );
    }
    _userId = _backend.currentUserId;
    _controller.add(_userId);
    return _delayed(const Result.ok(null));
  }

  @override
  Future<Result<void>> sendPasswordReset(String email) async =>
      _delayed(const Result.ok(null));

  @override
  Future<Result<void>> changePassword(String newPassword) async =>
      _delayed(const Result.ok(null));

  @override
  Future<void> signOut() async {
    _userId = null;
    _controller.add(null);
  }

  void dispose() => unawaited(_controller.close());
}

class DemoUserRepository implements UserRepository {
  DemoUserRepository(this._backend);

  final DemoBackend _backend;

  @override
  // Keyed off userUpdates, not serviceUpdates: a profile edit has to be visible
  // on its own, without waiting for some unrelated service event to come along
  // and shake the stream.
  Stream<AppUser?> watchUser(String uid) =>
      _backend.userUpdates.map((users) => users[uid]).distinct();

  @override
  Stream<List<AppUser>> watchAllClients({int limit = 500}) =>
      _backend.userUpdates.map((users) {
        final clients = users.values
            .where((user) => user.role == UserRole.client)
            .toList()
          // Newest first, matching the Firestore ordering. Users seeded
          // without a createdAt sort last rather than crashing the sort.
          ..sort((a, b) {
            final left = a.createdAt;
            final right = b.createdAt;
            if (left == null || right == null) {
              return left == null ? (right == null ? 0 : 1) : -1;
            }
            return right.compareTo(left);
          });
        return clients.take(limit).toList();
      });

  @override
  Future<Result<AppUser>> fetchUser(String uid) async {
    final user = _backend.user(uid);
    if (user == null) {
      return _delayed(const Result.err(Failure(FailureCode.notFound)));
    }
    return _delayed(Result.ok(user));
  }

  @override
  Future<Result<void>> updateProfile(
    String uid, {
    String? name,
    String? email,
    String? rnc,
    String? address,
    PaymentMethod? preferredPaymentMethod,
  }) async {
    final user = _backend.user(uid);
    if (user == null) {
      return _delayed(const Result.err(Failure(FailureCode.notFound)));
    }
    _backend.upsertUser(
      user.copyWith(
        name: name ?? user.name,
        email: email ?? user.email,
        rnc: rnc ?? user.rnc,
        address: address ?? user.address,
        preferredPaymentMethod:
            preferredPaymentMethod ?? user.preferredPaymentMethod,
      ),
    );
    return _delayed(const Result.ok(null));
  }

  // Saved vehicles live only for the life of the demo session, which is all
  // the demo backend promises for anything else either.
  final Map<String, Map<String, ServiceVehicle>> _vehicles = {};

  @override
  Stream<List<ServiceVehicle>> watchVehicles(String uid) =>
      Stream.value((_vehicles[uid] ?? {}).values.toList());

  @override
  Future<Result<void>> saveVehicle(
    String uid,
    ServiceVehicle vehicle, {
    String id = UserRepository.primaryVehicleId,
  }) async {
    (_vehicles[uid] ??= {})[id] = vehicle;
    return _delayed(const Result.ok(null));
  }

  @override
  Future<Result<void>> registerFcmToken(
    String uid,
    String token,
    String platform,
  ) async =>
      const Result.ok(null);

  @override
  Future<Result<void>> removeFcmToken(String uid, String token) async =>
      const Result.ok(null);
}

class DemoDriverRepository implements DriverRepository {
  DemoDriverRepository(this._backend);

  final DemoBackend _backend;

  @override
  Stream<Driver?> watchDriver(String uid) =>
      _backend.driverUpdates.map((all) => all[uid]);

  @override
  Stream<List<Driver>> watchAllDrivers({DriverStatus? status}) =>
      _backend.driverUpdates.map(
        (all) => all.values
            .where((d) => status == null || d.status == status)
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name)),
      );

  @override
  Future<Result<Driver>> fetchDriver(String uid) async {
    final driver = _backend.driver(uid);
    if (driver == null) {
      return _delayed(const Result.err(Failure(FailureCode.notFound)));
    }
    return _delayed(Result.ok(driver));
  }

  @override
  Stream<List<DriverDocument>> watchDocuments(String uid) =>
      Stream.value(const []);

  @override
  Future<void> publishLivePosition(DriverLivePosition position) async =>
      _backend.setLive(position);

  @override
  Stream<List<DriverLivePosition>> watchLivePositions() =>
      _backend.liveUpdates.map((all) => all.values.toList());

  @override
  Stream<void> holdAppPresence(String uid) => StreamController<void>(
        onListen: () => _backend.setAppOpen(uid, open: true),
        onCancel: () => _backend.setAppOpen(uid, open: false),
      ).stream;

  @override
  Future<void> clearAppPresence(String uid) async =>
      _backend.setAppOpen(uid, open: false);

  @override
  Stream<Set<String>> watchConnectedDriverIds() => _backend.appOpenUpdates;

  @override
  Future<Result<String>> uploadDocument({
    required String driverId,
    required DriverDocumentType type,
    required Uint8List bytes,
    required String fileName,
    required String contentType,
  }) =>
      // Nothing is stored: there is no bucket in demo mode. The path is shaped
      // like the real one so a screen showing it looks the same either way.
      _delayed(Result.ok('drivers/$driverId/docs/${type.wire}_$fileName'));

  @override
  Future<Result<String>> uploadDriverPhoto({
    required String driverId,
    required Uint8List bytes,
    required String contentType,
  }) {
    final path =
        'drivers/$driverId/avatar/photo_${DateTime.now().millisecondsSinceEpoch}';
    _backend.storeUpload(
      path,
      UriData.fromBytes(bytes, mimeType: contentType).toString(),
    );
    return _delayed(Result.ok(path));
  }
}

class DemoTruckRepository implements TruckRepository {
  DemoTruckRepository(this._backend);

  final DemoBackend _backend;

  @override
  // Live, like the Firestore listener, so a grúa added or edited in the panel
  // shows up without a reload.
  Stream<List<Truck>> watchTrucks({bool activeOnly = false}) =>
      _backend.truckUpdates.map(
        (all) => all.values.where((t) => !activeOnly || t.active).toList()
          ..sort((a, b) => a.plate.compareTo(b.plate)),
      );

  @override
  Stream<Truck?> watchTruck(String id) =>
      _backend.truckUpdates.map((all) => all[id]);

  @override
  Future<Result<Truck>> fetchTruck(String id) async {
    final truck = _backend.truck(id);
    if (truck == null) {
      return _delayed(const Result.err(Failure(FailureCode.notFound)));
    }
    return _delayed(Result.ok(truck));
  }
}

class DemoServiceRepository implements ServiceRepository {
  DemoServiceRepository(this._backend);

  final DemoBackend _backend;

  @override
  Stream<Service?> watchService(String id) =>
      _backend.serviceUpdates.map((all) => all[id]);

  @override
  Stream<Service?> watchActiveForClient(String clientId) =>
      _backend.serviceUpdates.map(
        (all) => all.values
            .where((s) => s.clientId == clientId && s.isActive)
            .fold<Service?>(null, (best, s) => best ?? s),
      );

  @override
  Stream<Service?> watchActiveForDriver(String driverId) =>
      _backend.serviceUpdates.map(
        (all) => all.values
            .where((s) => s.driverId == driverId && s.isActive)
            .fold<Service?>(null, (best, s) => best ?? s),
      );

  @override
  Stream<List<Service>> watchActiveServices() => _backend.serviceUpdates.map(
        (all) => all.values.where((s) => s.isActive).toList()
          ..sort((a, b) => (a.createdAt ?? DateTime(0))
              .compareTo(b.createdAt ?? DateTime(0))),
      );

  @override
  Stream<List<ServiceEvent>> watchEvents(String serviceId) =>
      _backend.serviceUpdates.map((_) => _backend.eventsFor(serviceId));

  @override
  Stream<ServiceTracking?> watchTracking(String serviceId) =>
      _backend.trackingFor(serviceId);

  @override
  Future<Result<PagedServices>> fetchServices({
    Set<ServiceStatus>? statuses,
    DateTime? from,
    DateTime? to,
    int limit = 50,
    Object? cursor,
  }) async {
    final all = _backend.allServices.where((s) {
      final at = s.createdAt;
      if (statuses != null && statuses.isNotEmpty && !statuses.contains(s.status)) {
        return false;
      }
      if (from != null && (at == null || at.isBefore(from))) return false;
      if (to != null && (at == null || !at.isBefore(to))) return false;
      return true;
    }).toList()
      ..sort((a, b) =>
          (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0)));

    final offset = cursor is int ? cursor : 0;
    final page = all.skip(offset).take(limit).toList();
    return _delayed(
      Result.ok(
        PagedServices(
          items: page,
          cursor: offset + page.length,
          hasMore: offset + page.length < all.length,
        ),
      ),
    );
  }

  @override
  Future<Result<Service?>> fetchServiceByCode(String code) async {
    final wanted = code.trim().toUpperCase();
    return _delayed(
      Result.ok(
        _backend.allServices.where((s) => s.code == wanted).firstOrNull,
      ),
    );
  }

  @override
  Future<Result<PagedServices>> fetchHistory({
    required String userId,
    required UserRole role,
    int limit = 20,
    Object? cursor,
  }) async {
    final all = _backend.allServices.where((s) {
      return role == UserRole.driver ? s.driverId == userId : s.clientId == userId;
    }).toList()
      ..sort((a, b) =>
          (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0)));

    final offset = cursor is int ? cursor : 0;
    final page = all.skip(offset).take(limit).toList();
    return _delayed(
      Result.ok(
        PagedServices(
          items: page,
          cursor: offset + page.length,
          hasMore: offset + page.length < all.length,
        ),
      ),
    );
  }
}

/// The demo cascade assigns a chofer directly instead of publishing an offer,
/// so there is never an incoming one to ring. The real implementation streams
/// `services/{id}/offers/{driverId}`.
class DemoOfferRepository implements OfferRepository {
  const DemoOfferRepository();

  @override
  Stream<Offer?> watchIncomingOffer(String driverId) => Stream.value(null);

  @override
  Stream<Offer?> watchOffer(String serviceId, String driverId) =>
      Stream.value(null);
}

class DemoChatRepository implements ChatRepository {
  DemoChatRepository(this._backend);

  final DemoBackend _backend;

  @override
  Stream<List<ChatMessage>> watchMessages(String serviceId, {int limit = 100}) =>
      _backend.messagesFor(serviceId);

  @override
  Future<Result<void>> sendMessage({
    required String serviceId,
    required String senderId,
    required UserRole senderRole,
    required String text,
    required String clientMsgId,
    String imageUrl = '',
  }) async {
    final trimmed = text.trim();
    if ((trimmed.isEmpty && imageUrl.isEmpty) || trimmed.length > 1000) {
      return const Result.err(Failure(FailureCode.invalidInput));
    }
    _backend.addMessage(
      serviceId,
      ChatMessage(
        id: clientMsgId,
        senderId: senderId,
        senderRole: senderRole,
        text: trimmed,
        imageUrl: imageUrl,
        clientMsgId: clientMsgId,
        sentAt: DateTime.now().toUtc(),
      ),
    );
    return const Result.ok(null);
  }

  @override
  Future<Result<void>> deleteMessages({
    required String serviceId,
    required String senderId,
    required List<String> messageIds,
  }) async {
    _backend.retractMessages(serviceId, messageIds);
    return const Result.ok(null);
  }

  @override
  // No bucket in demo mode, so the photo travels as a data URI — the same
  // trick the chofer's profile photo uses.
  Future<Result<String>> uploadImage({
    required String serviceId,
    required Uint8List bytes,
    required String contentType,
  }) =>
      _delayed(
        Result.ok(UriData.fromBytes(bytes, mimeType: contentType).toString()),
      );

  @override
  Future<Result<void>> markRead(String serviceId, String readerId) async {
    _backend.markMessagesRead(serviceId, readerId);
    return const Result.ok(null);
  }
}

class DemoChatRequestRepository implements ChatRequestRepository {
  DemoChatRequestRepository(this._backend);

  final DemoBackend _backend;

  @override
  Stream<List<ChatRequest>> watchForDriver(String driverId, {int limit = 20}) =>
      _backend
          .chatRequestsWhere((r) => r.driverId == driverId)
          .map((all) => all.take(limit).toList());

  @override
  Stream<List<ChatRequest>> watchForClient(String clientId, {int limit = 10}) =>
      _backend
          .chatRequestsWhere((r) => r.clientId == clientId)
          .map((all) => all.take(limit).toList());

  @override
  Stream<ChatRequest?> watchRequest(String requestId) =>
      _backend.chatRequestUpdates(requestId);

  @override
  Stream<List<ChatMessage>> watchMessages(String requestId, {int limit = 100}) =>
      _backend.chatRequestMessagesFor(requestId);

  @override
  Future<Result<void>> sendMessage({
    required String requestId,
    required String senderId,
    required UserRole senderRole,
    required String text,
    required String clientMsgId,
    String imageUrl = '',
  }) async {
    final trimmed = text.trim();
    if ((trimmed.isEmpty && imageUrl.isEmpty) || trimmed.length > 1000) {
      return const Result.err(Failure(FailureCode.invalidInput));
    }
    // What the rules enforce: a party, while the chofer has it open.
    final request = _backend.chatRequest(requestId);
    final open = request != null &&
        (request.clientId == senderId || request.driverId == senderId) &&
        request.phaseAt(DateTime.now().toUtc()) == ChatRequestPhase.open;
    if (!open) {
      return const Result.err(
        Failure(
          FailureCode.permissionDenied,
          message: 'Esta conversación está cerrada.',
        ),
      );
    }

    _backend.addChatRequestMessage(
      requestId,
      ChatMessage(
        id: clientMsgId,
        senderId: senderId,
        senderRole: senderRole,
        text: trimmed,
        imageUrl: imageUrl,
        clientMsgId: clientMsgId,
        sentAt: DateTime.now().toUtc(),
      ),
    );
    return const Result.ok(null);
  }

  @override
  Future<Result<void>> deleteMessages({
    required String requestId,
    required String senderId,
    required List<String> messageIds,
  }) async {
    _backend.retractChatRequestMessages(requestId, messageIds);
    return const Result.ok(null);
  }

  @override
  Future<Result<String>> uploadImage({
    required String requestId,
    required Uint8List bytes,
    required String contentType,
  }) =>
      _delayed(
        Result.ok(UriData.fromBytes(bytes, mimeType: contentType).toString()),
      );

  @override
  Future<Result<void>> markRead(String requestId, String readerId) async {
    _backend.markChatRequestMessagesRead(requestId, readerId);
    return const Result.ok(null);
  }
}

class DemoTypingRepository implements TypingRepository {
  DemoTypingRepository(this._backend);

  final DemoBackend _backend;

  @override
  Stream<Set<String>> watchTyping(String threadKey) =>
      _backend.typingFor(threadKey);

  @override
  Future<void> setTyping({
    required String threadKey,
    required String uid,
    required bool typing,
  }) async =>
      _backend.setTyping(threadKey: threadKey, uid: uid, typing: typing);
}

class DemoChatPrefsRepository implements ChatPrefsRepository {
  DemoChatPrefsRepository(this._backend);

  final DemoBackend _backend;

  @override
  Stream<ChatThreadPrefs> watchThread({
    required String uid,
    required String threadKey,
  }) =>
      _backend
          .chatPrefsFor(uid)
          .map((prefs) => prefs[threadKey] ?? ChatThreadPrefs.none);

  @override
  Stream<Map<String, ChatThreadPrefs>> watchThreads(String uid) =>
      _backend.chatPrefsFor(uid);

  @override
  Stream<Set<String>> watchBlocked(String uid) => _backend.blockedFor(uid);

  @override
  Stream<bool> watchBlockedBy({
    required String uid,
    required String otherUid,
  }) =>
      _backend.blockedFor(otherUid).map((blocked) => blocked.contains(uid));

  @override
  Future<Result<void>> clearThread({
    required String uid,
    required String threadKey,
  }) async {
    _backend.clearChatThread(uid, threadKey);
    return const Result.ok(null);
  }

  @override
  Future<Result<void>> deleteThread({
    required String uid,
    required String threadKey,
  }) async {
    _backend.clearChatThread(uid, threadKey, alsoFromList: true);
    return const Result.ok(null);
  }

  @override
  Future<Result<void>> setBlocked({
    required String uid,
    required String otherUid,
    required bool blocked,
  }) async {
    _backend.setBlocked(uid, otherUid, blocked: blocked);
    return const Result.ok(null);
  }
}

class DemoEarningsRepository implements EarningsRepository {
  DemoEarningsRepository(this._backend);

  final DemoBackend _backend;

  @override
  Stream<EarningsSummary?> watchSummary(String driverId) =>
      _backend.serviceUpdates
          .map((_) => _backend.earnings(driverId))
          .startWith(_backend.earnings(driverId));

  @override
  Future<Result<List<EarningEntry>>> fetchEntries({
    required String driverId,
    required DateTime from,
    required DateTime to,
  }) async =>
      _delayed(
        Result.ok(
          _backend
              .earningEntries(driverId)
              .where((e) =>
                  e.completedAt != null &&
                  e.completedAt!.isAfter(from) &&
                  e.completedAt!.isBefore(to))
              .toList(),
        ),
      );
}

class DemoInvoiceRepository implements InvoiceRepository {
  DemoInvoiceRepository(this._backend);

  final DemoBackend _backend;

  @override
  Future<Result<Invoice>> fetchInvoice(String invoiceId) async {
    final invoice = _backend.invoice(invoiceId);
    if (invoice == null) {
      return _delayed(const Result.err(Failure(FailureCode.notFound)));
    }
    return _delayed(Result.ok(invoice));
  }

  @override
  Future<Result<String>> downloadUrl(String invoiceId) async => _delayed(
        const Result.err(
          Failure(
            FailureCode.unknown,
            message: 'Las facturas en PDF no están disponibles en modo demo.',
          ),
        ),
      );
}

class DemoConfigRepository implements ConfigRepository {
  DemoConfigRepository(this._backend);

  final DemoBackend _backend;

  @override
  Stream<PricingConfig> watchPricing() => Stream.value(_backend.pricing);

  @override
  Stream<DispatchConfig> watchDispatch() => Stream.value(_backend.dispatch);

  @override
  Stream<AppSettings> watchAppSettings() => Stream.value(_backend.settings);

  @override
  Future<AppSettings> currentAppSettings() async => _backend.settings;
}

/// How the demo writes a [NearbyTruck.ref]: the driver id, unsealed.
const _demoRefPrefix = 'demo:';

/// Simulates the callables, including the guards that matter for the UI.
class DemoFunctionsGateway implements FunctionsGateway {
  DemoFunctionsGateway(this._backend);

  final DemoBackend _backend;

  @override
  // The demo backend hands out a fully-formed customer at startup, so there is
  // never a missing document to create.
  Future<Result<void>> ensureProfile({String locale = 'es_DO'}) async =>
      const Result.ok(null);

  @override
  // The demo session already presents whichever role the app asked for.
  Future<Result<void>> bootstrapFirstAdmin() async => const Result.ok(null);

  @override
  // Mirrors the `nearbyTrucks` callable: free, online trucks inside the
  // circle, nearest first, at the same ~110 m grain.
  Future<Result<List<NearbyTruck>>> nearbyTrucks({
    required LatLng center,
    required double radiusKm,
  }) async {
    double coarse(double v) => (v * 1000).roundToDouble() / 1000;
    final trucks = [
      for (final p in _backend.allLive)
        if (p.isOnline &&
            p.state == DriverLiveState.idle &&
            p.position.distanceTo(center) <= radiusKm * 1000)
          NearbyTruck(
            position: LatLng(coarse(p.lat), coarse(p.lng)),
            truckType: p.truckType,
            distanceMeters: p.position.distanceTo(center).round(),
            heading: p.heading,
            // Demo mode has no secret to seal with, and nobody to hide from.
            ref: '$_demoRefPrefix${p.driverId}',
          ),
    ]..sort((a, b) => a.distanceMeters.compareTo(b.distanceMeters));
    return _delayed(Result.ok(trucks.take(30).toList()));
  }

  @override
  // Mirrors `requestChat`: the ref names the chofer, unsealed in the demo.
  Future<Result<String>> requestChat(String truckRef) async {
    if (!truckRef.startsWith(_demoRefPrefix)) {
      return _delayed(
        const Result.err(Failure(FailureCode.chatRequestUnavailable)),
      );
    }
    return _delayed(
      _backend.createChatRequest(
        clientId: _backend.currentUserId,
        driverId: truckRef.substring(_demoRefPrefix.length),
      ),
    );
  }

  @override
  Future<Result<void>> respondChatRequest(
    String requestId, {
    required bool accept,
  }) async =>
      _delayed(
        _backend.respondChatRequest(
          requestId,
          _backend.currentUserId,
          accept: accept,
        ),
      );

  @override
  Future<Result<void>> closeChatRequest(String requestId) async => _delayed(
        _backend.closeChatRequest(requestId, _backend.currentUserId),
      );

  @override
  Future<Result<QuoteResult>> quoteService({
    required ServiceLocation pickup,
    required ServiceLocation dropoff,
    required ServiceVehicle vehicle,
    TruckType? truckTypeOverride,
  }) async {
    if (!_backend.settings.isCovered(pickup.geo)) {
      return _delayed(const Result.err(Failure(FailureCode.outsideCoverage)));
    }

    final truckType = truckTypeOverride ?? vehicle.inferredTruckType;
    // Straight-line distance with a 1.35 detour factor stands in for the
    // Routes API, which the real implementation calls server-side.
    final distanceKm = pickup.geo.distanceKmTo(dropoff.geo) * 1.35;
    final now = DateTime.now().toUtc();

    final quote = Pricing.quoteFor(
      config: _backend.pricing,
      truckType: truckType,
      distanceKm: distanceKm,
      at: now,
      chargeItbis: false,
    );

    return _delayed(
      Result.ok(
        QuoteResult(
          quote: quote,
          route: ServiceRoute(
            distanceMeters: (distanceKm * 1000).round(),
            durationSeconds: (distanceKm / 28 * 3600).round(),
            provider: 'demo',
            fetchedAt: now,
          ),
          expiresAt: now.add(const Duration(minutes: 10)),
          signature: 'demo-signature',
          truckType: truckType,
        ),
      ),
    );
  }

  @override
  Future<Result<String>> requestService({
    required ServiceLocation pickup,
    required ServiceLocation dropoff,
    required ServiceVehicle vehicle,
    required TruckType truckType,
    required PaymentMethod paymentMethod,
    required String quoteSignature,
    required DateTime quoteExpiresAt,
    String? paymentMethodId,
    String? notes,
    String? preferredTruckRef,
  }) async {
    final clientId = _backend.currentUserId;
    final existing = _backend.user(clientId)?.activeServiceId;
    if (existing != null) {
      return _delayed(
        Result.err(
          Failure(FailureCode.alreadyHasActiveService, details: existing),
        ),
      );
    }

    final quoteResult = await quoteService(
      pickup: pickup,
      dropoff: dropoff,
      vehicle: vehicle,
      truckTypeOverride: truckType,
    );

    return quoteResult.fold(
      (quote) {
        final service = _backend.createService(
          clientId: clientId,
          pickup: pickup,
          dropoff: dropoff,
          vehicle: vehicle,
          truckType: truckType,
          paymentMethod: paymentMethod,
          quote: quote.quote,
          route: quote.route,
          preferredDriverId: preferredTruckRef != null &&
                  preferredTruckRef.startsWith(_demoRefPrefix)
              ? preferredTruckRef.substring(_demoRefPrefix.length)
              : null,
        );
        return Result.ok(service.id);
      },
      Result.err,
    );
  }

  @override
  Future<Result<void>> cancelService({
    required String serviceId,
    required String reason,
  }) async {
    final service = _backend.service(serviceId);
    if (service == null) {
      return const Result.err(Failure(FailureCode.notFound));
    }
    if (!service.status.isCancellableByClient) {
      return const Result.err(Failure(FailureCode.invalidTransition));
    }
    return _delayed(
      _backend.transition(
        serviceId,
        ServiceStatus.cancelled,
        ServiceEventName.cancelService,
        service.clientId,
        UserRole.client,
      ),
    );
  }

  @override
  // Mirrors the `setOnline` callable, acting as the signed-in chofer.
  Future<Result<void>> setOnline({required bool online}) async {
    final uid = _backend.currentUserId;
    final driver = _backend.driver(uid);
    if (driver == null) {
      return const Result.err(Failure(FailureCode.notFound));
    }
    if (online && !driver.canGoOnline) {
      return const Result.err(Failure(FailureCode.driverInactive));
    }
    if (!online && driver.isBusy) {
      return const Result.err(
        Failure(
          FailureCode.driverBusy,
          message:
              'No puedes ponerte fuera de línea con un servicio en curso.',
        ),
      );
    }
    _backend.setDriverOnline(uid, online: online);
    return const Result.ok(null);
  }

  @override
  Future<Result<void>> acceptService(String serviceId) async => _delayed(
        _backend.transition(
          serviceId,
          ServiceStatus.accepted,
          ServiceEventName.acceptService,
          _backend.currentUserId,
          UserRole.driver,
        ),
      );

  @override
  Future<Result<void>> rejectService(
    String serviceId, {
    DriverCancelReason? reason,
  }) async =>
      const Result.ok(null);

  @override
  Future<Result<void>> markArrived({
    required String serviceId,
    required LatLng position,
  }) async {
    final service = _backend.service(serviceId);
    if (service == null) {
      return const Result.err(Failure(FailureCode.notFound));
    }
    final metres = position.distanceTo(service.pickup.geo);
    final limit = _backend.dispatch.arrivalRadiusM;
    if (metres > limit) {
      return Result.err(
        Failure(
          FailureCode.outOfRange,
          message: 'Estás a ${(metres / 1000).toStringAsFixed(1)} km '
              'del punto de recogida.',
          details: metres,
        ),
      );
    }
    return _delayed(
      _backend.transition(serviceId, ServiceStatus.arrived,
          ServiceEventName.markArrived, _backend.currentUserId, UserRole.driver),
    );
  }

  @override
  Future<Result<void>> startService({
    required String serviceId,
    required List<String> photoPaths,
  }) async {
    final service = _backend.service(serviceId);
    if (service == null) {
      return const Result.err(Failure(FailureCode.notFound));
    }
    if (service.payment.blocksStart) {
      return const Result.err(Failure(FailureCode.blockedPayment));
    }
    return _delayed(
      _backend.transition(serviceId, ServiceStatus.inProgress,
          ServiceEventName.startService, _backend.currentUserId, UserRole.driver),
    );
  }

  @override
  Future<Result<void>> completeService({
    required String serviceId,
    required LatLng position,
    required List<String> photoPaths,
    String? notes,
  }) async =>
      _delayed(
        _backend.transition(
          serviceId,
          ServiceStatus.completed,
          ServiceEventName.completeService,
          _backend.currentUserId,
          UserRole.driver,
        ),
      );

  @override
  Future<Result<void>> confirmCashCollected({
    required String serviceId,
    required int amountCents,
    String? discrepancyReason,
  }) async =>
      _delayed(
        _backend.transition(
          serviceId,
          ServiceStatus.closed,
          ServiceEventName.confirmCashCollected,
          _backend.currentUserId,
          UserRole.driver,
        ),
      );

  @override
  Future<Result<void>> cancelByDriver({
    required String serviceId,
    required DriverCancelReason reason,
  }) async =>
      _delayed(
        _backend.transition(
          serviceId,
          ServiceStatus.cancelled,
          ServiceEventName.cancelByDriver,
          _backend.currentUserId,
          UserRole.driver,
        ),
      );

  @override
  Future<Result<void>> rateService({
    required String serviceId,
    required int stars,
    String? comment,
  }) async =>
      const Result.ok(null);

  @override
  Future<Result<CreatedDriver>> createDriver(NewDriver driver) async {
    final created = _backend.createDriver(
      name: driver.name,
      cedula: driver.cedula,
      phone: driver.phone,
      email: driver.email,
      licenseNumber: driver.licenseNumber,
      licenseExpiry: driver.licenseExpiry,
      truckId: driver.truckId,
      zones: driver.zones,
      companyName: driver.companyName,
      rnc: driver.rnc,
    );

    if (created == null) {
      return _delayed(
        const Result.err(
          Failure(
            FailureCode.invalidInput,
            message: 'Ya existe un chofer con esa cédula.',
          ),
        ),
      );
    }

    return _delayed(
      Result.ok(
        CreatedDriver(
          driverId: created.id,
          // Fixed rather than random so a demo walkthrough is reproducible.
          temporaryPassword: 'GruaDemo2026!',
        ),
      ),
    );
  }

  @override
  Future<Result<String>> registerDriver(DriverSignUp signUp) async {
    final created = _backend.createDriver(
      name: signUp.name,
      cedula: signUp.cedula,
      phone: signUp.phone,
      email: signUp.email,
      licenseNumber: signUp.licenseNumber,
      licenseExpiry: signUp.licenseExpiry,
      companyName: signUp.companyName,
      rnc: signUp.rnc,
      selfRegistered: true,
    );

    if (created == null) {
      return _delayed(
        const Result.err(
          Failure(
            FailureCode.invalidInput,
            message: 'Ya existe un chofer con esa cédula.',
          ),
        ),
      );
    }

    // The next email sign-in is this new account, as it would be against Auth.
    _backend.currentUserId = created.id;
    return _delayed(Result.ok(created.id));
  }

  @override
  Future<Result<void>> updateDriver(String driverId, DriverUpdate update) {
    final refusal = _backend.updateDriver(
      driverId,
      name: update.name,
      phone: update.phone,
      email: update.email,
      licenseNumber: update.licenseNumber,
      licenseExpiry: update.licenseExpiry,
      truckId: update.truckId,
      zones: update.zones,
      companyName: update.companyName,
      rnc: update.rnc,
    );
    return _delayed(_refusedOr(refusal));
  }

  @override
  Future<Result<void>> archiveDriver(String driverId) =>
      _delayed(_refusedOr(_backend.archiveDriver(driverId)));

  @override
  Future<Result<String>> createTruck(TruckDetails details) =>
      _delayed(_backend.createTruck(details));

  @override
  Future<Result<void>> updateTruck(String truckId, TruckDetails details) =>
      _delayed(_failedOr(_backend.updateTruck(truckId, details)));

  @override
  Future<Result<void>> archiveTruck(String truckId) =>
      _delayed(_failedOr(_backend.archiveTruck(truckId)));

  Result<void> _failedOr(Failure? failure) => failure == null
      ? const Result<void>.ok(null)
      : Result<void>.err(failure);

  @override
  Future<Result<void>> setDriverStatus({
    required String driverId,
    required DriverStatus status,
    String reason = '',
  }) =>
      _delayed(
        _refusedOr(_backend.setDriverStatus(driverId, status, reason: reason)),
      );

  /// The backend's refusal as the failure the real callable would return.
  Result<void> _refusedOr(String? refusal) => refusal == null
      ? const Result<void>.ok(null)
      : Result<void>.err(Failure(FailureCode.invalidInput, message: refusal));

  @override
  Future<Result<void>> attachDriverDocument({
    required String driverId,
    required DriverDocumentType type,
    required String storagePath,
    required String fileName,
    required String contentType,
    required int sizeBytes,
    DateTime? expiresAt,
  }) async =>
      _delayed(const Result.ok(null));

  @override
  Future<Result<String>> setDriverPhoto({
    required String driverId,
    required String storagePath,
  }) {
    final url = _backend.setDriverPhoto(driverId, storagePath);
    return _delayed(
      url == null
          ? const Result<String>.err(
              Failure(FailureCode.invalidInput, message: 'La foto no se encontró.'),
            )
          : Result<String>.ok(url),
    );
  }

  @override
  Future<Result<String>> invoiceDownloadUrl(String invoiceId) async => _delayed(
        const Result.err(
          Failure(
            FailureCode.unknown,
            message: 'Las facturas en PDF no están disponibles en modo demo.',
          ),
        ),
      );

  @override
  Future<Result<void>> publishEta({
    required String serviceId,
    required int etaSeconds,
    required int remainingMeters,
  }) async =>
      const Result.ok(null);
}

extension _StartWith<T> on Stream<T> {
  /// Emits [value] immediately, then the source. Saves every consumer from
  /// rendering an empty first frame while the first snapshot is in flight.
  Stream<T> startWith(T value) async* {
    yield value;
    yield* this;
  }
}
