// Every method in this file returns an already-built future from `_delayed` or
// a synchronous backend call. Awaiting each one before returning it would add a
// microtask and no meaning.
// ignore_for_file: async_return_with_no_await

import 'dart:async';

import '../../domain/enums.dart';
import '../../domain/failures.dart';
import '../../domain/models/app_user.dart';
import '../../domain/models/billing.dart';
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
  Stream<AppUser?> watchUser(String uid) => _backend.serviceUpdates
      .map((_) => _backend.user(uid))
      .distinct()
      .startWith(_backend.user(uid));

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
        preferredPaymentMethod:
            preferredPaymentMethod ?? user.preferredPaymentMethod,
      ),
    );
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
  Future<Result<void>> setOnline(String uid, {required bool online}) async {
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
  Stream<List<DriverLivePosition>> watchLivePositions() =>
      _backend.liveUpdates.map((all) => all.values.toList());
}

class DemoTruckRepository implements TruckRepository {
  DemoTruckRepository(this._backend);

  final DemoBackend _backend;

  @override
  Stream<List<Truck>> watchTrucks({bool activeOnly = false}) => Stream.value(
        _backend.allTrucks.where((t) => !activeOnly || t.active).toList(),
      );

  @override
  Stream<Truck?> watchTruck(String id) => Stream.value(_backend.truck(id));

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
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || trimmed.length > 1000) {
      return const Result.err(Failure(FailureCode.invalidInput));
    }
    _backend.addMessage(
      serviceId,
      ChatMessage(
        id: clientMsgId,
        senderId: senderId,
        senderRole: senderRole,
        text: trimmed,
        clientMsgId: clientMsgId,
        sentAt: DateTime.now().toUtc(),
      ),
    );
    return const Result.ok(null);
  }

  @override
  Future<Result<void>> markRead(String serviceId, String readerId) async =>
      const Result.ok(null);
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

/// Simulates the callables, including the guards that matter for the UI.
class DemoFunctionsGateway implements FunctionsGateway {
  DemoFunctionsGateway(this._backend);

  final DemoBackend _backend;

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
