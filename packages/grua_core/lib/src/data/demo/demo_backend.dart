import 'dart:async';
import 'dart:math' as math;

import '../../domain/enums.dart';
import '../../domain/failures.dart';
import '../../domain/models/app_user.dart';
import '../../domain/models/billing.dart';
import '../../domain/models/dispatch_models.dart';
import '../../domain/models/driver.dart';
import '../../domain/models/remote_config_models.dart';
import '../../domain/models/service.dart';
import '../../domain/models/truck.dart';
import '../../domain/value_objects.dart';
import '../../utils/money.dart';
import '../pricing.dart';

/// An in-memory stand-in for the whole backend.
///
/// This exists so the three apps can be built, demonstrated and widget-tested
/// before a Firebase project is provisioned, and so a reviewer can walk the
/// full request → dispatch → tow → pay flow on a plane. It deliberately
/// implements the *same* state machine and the *same* pricing rules as the
/// server, because a demo that behaves differently from production teaches
/// everyone the wrong thing.
///
/// What it does not do is enforce anything. Authorisation, concurrency and
/// money are the server's job; nothing here should ever be pointed at a real
/// customer.
class DemoBackend {
  DemoBackend({math.Random? random, DateTime Function()? clock})
      : _random = random ?? math.Random(7),
        _now = clock ?? DateTime.now;

  final math.Random _random;
  final DateTime Function() _now;

  final Map<String, AppUser> _users = {};
  final Map<String, Driver> _drivers = {};
  final Map<String, Truck> _trucks = {};
  final Map<String, Service> _services = {};
  final Map<String, List<ChatMessage>> _messages = {};
  final Map<String, List<ServiceEvent>> _events = {};
  final Map<String, ServiceTracking> _tracking = {};
  final Map<String, DriverLivePosition> _live = {};
  final Map<String, EarningsSummary> _earnings = {};
  final Map<String, List<EarningEntry>> _earningEntries = {};
  final Map<String, Invoice> _invoices = {};

  final PricingConfig _pricing = const PricingConfig();
  final DispatchConfig _dispatch = const DispatchConfig();
  final AppSettings _settings = const AppSettings();

  final _servicesController = StreamController<Map<String, Service>>.broadcast();
  final _driversController = StreamController<Map<String, Driver>>.broadcast();
  final _liveController = StreamController<Map<String, DriverLivePosition>>.broadcast();
  final _messagesController = StreamController<String>.broadcast();
  final _trackingController = StreamController<String>.broadcast();

  final List<Timer> _timers = [];
  var _seeded = false;
  var _serviceCounter = 430;

  /// The identity the demo signs in as. Swapped by the driver and admin apps.
  String currentUserId = 'demo-client-1';

  // -------------------------------------------------------------------------
  // Seed
  // -------------------------------------------------------------------------

  void seed() {
    if (_seeded) return;
    _seeded = true;

    _users['demo-client-1'] = AppUser(
      id: 'demo-client-1',
      phone: '+18095551234',
      name: 'Ramón Peña',
      email: 'ramon@example.do',
      preferredPaymentMethod: PaymentMethod.cash,
      completedServices: 4,
      createdAt: _now().subtract(const Duration(days: 210)),
    );

    const truckSpecs = <(String, String, String, String, TruckType, int)>[
      ('truck-1', 'A123456', 'Ford', 'F-450', TruckType.plataforma, 4500),
      ('truck-2', 'A234567', 'Isuzu', 'NPR', TruckType.plataforma, 5000),
      ('truck-3', 'A345678', 'Chevrolet', 'Silverado 3500', TruckType.gancho, 3200),
      ('truck-4', 'A456789', 'Dodge', 'Ram 3500', TruckType.gancho, 3400),
      ('truck-5', 'A567890', 'Freightliner', 'M2 106', TruckType.pesada, 12000),
    ];

    const driverSpecs = <(String, String, String, String, DriverStatus)>[
      ('driver-1', 'Luis Fernández', '00112345678', '+18095550111', DriverStatus.active),
      ('driver-2', 'Máximo Ureña', '00223456789', '+18095550112', DriverStatus.active),
      ('driver-3', 'Wilkin Rosario', '00334567890', '+18095550113', DriverStatus.active),
      ('driver-4', 'Elvin Santana', '00445678901', '+18095550114', DriverStatus.active),
      ('driver-5', 'Junior Castillo', '00556789012', '+18295550115', DriverStatus.active),
      ('driver-6', 'Pedro Aybar', '00667890123', '+18295550116', DriverStatus.inactive),
    ];

    final positions = <LatLng>[
      const LatLng(18.4795, -69.9420), // Gazcue
      const LatLng(18.4712, -69.9061), // Naco
      const LatLng(18.4930, -69.8790), // Villa Mella side
      const LatLng(18.4520, -69.9550), // Zona Colonial edge
      const LatLng(19.4517, -70.6970), // Santiago
      const LatLng(18.6157, -68.7075), // Higüey
    ];

    for (var i = 0; i < truckSpecs.length; i++) {
      final (id, plate, make, model, type, capacity) = truckSpecs[i];
      _trucks[id] = Truck(
        id: id,
        plate: plate,
        make: make,
        model: model,
        year: 2019 + (i % 4),
        color: 'Blanco',
        type: type,
        capacityKg: capacity,
        assignedDriverId: 'driver-${i + 1}',
        assignedDriverName: driverSpecs[i].$2,
        insuranceExpiry: _now().add(Duration(days: 60 + i * 30)),
        marbeteExpiry: _now().add(Duration(days: 20 + i * 45)),
        completedServices: 40 + i * 13,
        createdAt: _now().subtract(const Duration(days: 400)),
      );
    }

    for (var i = 0; i < driverSpecs.length; i++) {
      final (id, name, cedula, phone, status) = driverSpecs[i];
      final truckId = i < truckSpecs.length ? truckSpecs[i].$1 : null;
      final truck = truckId == null ? null : _trucks[truckId];

      _drivers[id] = Driver(
        id: id,
        name: name,
        cedula: cedula,
        phone: phone,
        email: '${id.replaceAll('-', '')}@gruasrd.do',
        licenseNumber: '${100000 + i * 137}',
        licenseExpiry: _now().add(Duration(days: 180 + i * 40)),
        status: status,
        assignedTruckId: truckId,
        assignedTruckPlate: truck?.plate ?? '',
        truckType: truck?.type ?? TruckType.unknown,
        isOnline: status == DriverStatus.active && i < 5,
        rating: 4.4 + (i % 5) * 0.12,
        ratingCount: 30 + i * 11,
        completedServices: 40 + i * 13,
        offersSent: 100 + i * 20,
        offersAccepted: 78 + i * 16,
        cashOwedCents: i == 2 ? 420000 : (i * 35000),
        createdAt: _now().subtract(const Duration(days: 380)),
        lastOnlineAt: _now().subtract(Duration(minutes: i * 3)),
      );

      _live[id] = DriverLivePosition(
        driverId: id,
        lat: positions[i].latitude,
        lng: positions[i].longitude,
        heading: (i * 47) % 360,
        speedKmh: i.isEven ? 34 : 0,
        isOnline: status == DriverStatus.active && i < 5,
        truckType: truck?.type ?? TruckType.unknown,
        updatedAt: _now().millisecondsSinceEpoch,
      );

      _earnings[id] = EarningsSummary(
        driverId: id,
        todayGrossCents: 340000 + i * 45000,
        todayNetCents: 272000 + i * 36000,
        todayServices: 3 + (i % 3),
        weekGrossCents: 1850000 + i * 210000,
        weekNetCents: 1480000 + i * 168000,
        weekServices: 17 + i * 2,
        monthGrossCents: 7400000 + i * 640000,
        monthNetCents: 5920000 + i * 512000,
        monthServices: 62 + i * 5,
        lifetimeNetCents: 48000000 + i * 3200000,
        cashOwedCents: i == 2 ? 420000 : (i * 35000),
        last7DaysNetCents: [
          for (var d = 0; d < 7; d++) 180000 + _random.nextInt(220000),
        ],
        updatedAt: _now(),
      );
    }

    _seedHistoricalServices();
    _emitServices();
    _emitDrivers();
    _emitLive();
  }

  void _seedHistoricalServices() {
    const routes = <(String, String, String, String, VehicleCondition)>[
      (
        'Av. 27 de Febrero, esq. Winston Churchill',
        'Taller Auto Récord, Av. Máximo Gómez',
        'Toyota Corolla',
        'Gris',
        VehicleCondition.noArranca,
      ),
      (
        'Autopista Duarte km 14',
        'Bonao, Av. Aniana Vargas',
        'Honda CR-V',
        'Negro',
        VehicleCondition.accidentado,
      ),
      (
        'Av. España, Boca Chica',
        'Santo Domingo Este, Av. San Vicente',
        'Hyundai Accent',
        'Blanco',
        VehicleCondition.gomaPinchada,
      ),
      (
        'Malecón, Av. George Washington',
        'Taller Hermanos Pérez, Villa Consuelo',
        'Nissan Frontier',
        'Azul',
        VehicleCondition.ruedasBloqueadas,
      ),
    ];

    for (var i = 0; i < routes.length; i++) {
      final (from, to, vehicle, color, condition) = routes[i];
      final completedAt = _now().subtract(Duration(days: i * 9 + 2, hours: i * 3));
      final id = 'svc-history-$i';
      final parts = vehicle.split(' ');
      final serviceVehicle = ServiceVehicle(
        make: parts.first,
        model: parts.skip(1).join(' '),
        plate: 'A${234567 + i * 1111}',
        color: color,
        year: 2015 + i,
        condition: condition,
      );
      final quote = Pricing.quoteFor(
        config: _pricing,
        truckType: serviceVehicle.inferredTruckType,
        distanceKm: 8.5 + i * 4.2,
        at: completedAt,
        chargeItbis: false,
      );

      _services[id] = Service(
        id: id,
        clientId: 'demo-client-1',
        clientName: 'Ramón Peña',
        clientPhone: '+18095551234',
        code: 'GR-${_dateCode(completedAt)}-0${400 + i}',
        status: ServiceStatus.closed,
        vehicle: serviceVehicle,
        truckTypeRequired: serviceVehicle.inferredTruckType,
        pickup: ServiceLocation(
          geo: LatLng(18.47 + i * 0.01, -69.93 - i * 0.01),
          address: from,
          reference: 'Frente al colmado',
        ),
        dropoff: ServiceLocation(
          geo: LatLng(18.50 + i * 0.01, -69.88 - i * 0.01),
          address: to,
        ),
        route: ServiceRoute(
          distanceMeters: ((8.5 + i * 4.2) * 1000).round(),
          durationSeconds: (18 + i * 7) * 60,
        ),
        quote: quote,
        finalQuote: quote,
        payment: ServicePayment(
          method: i.isEven ? PaymentMethod.cash : PaymentMethod.card,
          status: i.isEven ? PaymentStatus.cashCollected : PaymentStatus.captured,
          capturedCents: quote.totalCents,
          last4: i.isEven ? '' : '4242',
          brand: i.isEven ? '' : 'Visa',
        ),
        driverId: 'driver-${(i % 4) + 1}',
        driverName: _drivers['driver-${(i % 4) + 1}']?.name ?? '',
        driverPhone: _drivers['driver-${(i % 4) + 1}']?.phone ?? '',
        driverRating: 4.7,
        truckId: 'truck-${(i % 4) + 1}',
        truckPlate: _trucks['truck-${(i % 4) + 1}']?.plate ?? '',
        assignedAt: completedAt.subtract(const Duration(minutes: 42)),
        timeline: ServiceTimeline(
          createdAt: completedAt.subtract(const Duration(minutes: 45)),
          acceptedAt: completedAt.subtract(const Duration(minutes: 42)),
          arrivedAt: completedAt.subtract(const Duration(minutes: 28)),
          startedAt: completedAt.subtract(const Duration(minutes: 24)),
          completedAt: completedAt,
          closedAt: completedAt.add(const Duration(minutes: 1)),
        ),
        invoiceId: 'inv-$i',
        createdAt: completedAt.subtract(const Duration(minutes: 45)),
      );

      _invoices['inv-$i'] = Invoice(
        id: 'inv-$i',
        serviceId: id,
        clientId: 'demo-client-1',
        serviceCode: _services[id]!.code,
        ncf: 'B02${(120 + i).toString().padLeft(8, '0')}',
        clientName: 'Ramón Peña',
        lines: [
          for (final line in quote.breakdown)
            InvoiceLine(
              code: line.label.toLowerCase().replaceAll(' ', '_'),
              label: line.label,
              totalCents: line.cents,
            ),
        ],
        subtotalCents: quote.subtotalCents,
        itbisCents: quote.itbisCents,
        totalCents: quote.totalCents,
        paymentMethod: i.isEven ? PaymentMethod.cash : PaymentMethod.card,
        issuedAt: completedAt,
      );
    }
  }

  String _dateCode(DateTime at) {
    final yy = (at.year % 100).toString().padLeft(2, '0');
    final mm = at.month.toString().padLeft(2, '0');
    final dd = at.day.toString().padLeft(2, '0');
    return '$yy$mm$dd';
  }

  // -------------------------------------------------------------------------
  // Reads
  // -------------------------------------------------------------------------

  PricingConfig get pricing => _pricing;

  DispatchConfig get dispatch => _dispatch;

  AppSettings get settings => _settings;

  AppUser? user(String uid) => _users[uid];

  Driver? driver(String uid) => _drivers[uid];

  Truck? truck(String id) => _trucks[id];

  Service? service(String id) => _services[id];

  Invoice? invoice(String id) => _invoices[id];

  EarningsSummary? earnings(String driverId) => _earnings[driverId];

  List<EarningEntry> earningEntries(String driverId) =>
      List.unmodifiable(_earningEntries[driverId] ?? const []);

  List<Driver> get allDrivers => List.unmodifiable(_drivers.values);

  List<Truck> get allTrucks => List.unmodifiable(_trucks.values);

  List<DriverLivePosition> get allLive => List.unmodifiable(_live.values);

  List<Service> get allServices => List.unmodifiable(_services.values);

  Stream<Map<String, Service>> get serviceUpdates async* {
    yield Map.unmodifiable(_services);
    yield* _servicesController.stream;
  }

  Stream<Map<String, Driver>> get driverUpdates async* {
    yield Map.unmodifiable(_drivers);
    yield* _driversController.stream;
  }

  Stream<Map<String, DriverLivePosition>> get liveUpdates async* {
    yield Map.unmodifiable(_live);
    yield* _liveController.stream;
  }

  Stream<List<ChatMessage>> messagesFor(String serviceId) async* {
    yield List.unmodifiable(_messages[serviceId] ?? const []);
    yield* _messagesController.stream
        .where((id) => id == serviceId)
        .map((_) => List<ChatMessage>.unmodifiable(_messages[serviceId] ?? const []));
  }

  Stream<ServiceTracking?> trackingFor(String serviceId) async* {
    yield _tracking[serviceId];
    yield* _trackingController.stream
        .where((id) => id == serviceId)
        .map((_) => _tracking[serviceId]);
  }

  List<ServiceEvent> eventsFor(String serviceId) =>
      List.unmodifiable(_events[serviceId] ?? const []);

  // -------------------------------------------------------------------------
  // Writes
  // -------------------------------------------------------------------------

  void upsertUser(AppUser user) {
    _users[user.id] = user;
  }

  void setLive(DriverLivePosition position) {
    _live[position.driverId] = position;
    _emitLive();
  }

  void setDriverOnline(String driverId, {required bool online}) {
    final driver = _drivers[driverId];
    if (driver == null) return;
    _drivers[driverId] = driver.copyWith(isOnline: online, lastOnlineAt: _now());
    final live = _live[driverId];
    if (live != null) {
      _live[driverId] = live.copyWith(
        isOnline: online,
        updatedAt: _now().millisecondsSinceEpoch,
      );
    }
    _emitDrivers();
    _emitLive();
  }

  void addMessage(String serviceId, ChatMessage message) {
    (_messages[serviceId] ??= []).add(message);
    _messagesController.add(serviceId);
  }

  /// Creates a service and starts the simulated dispatch cascade.
  Service createService({
    required String clientId,
    required ServiceLocation pickup,
    required ServiceLocation dropoff,
    required ServiceVehicle vehicle,
    required TruckType truckType,
    required PaymentMethod paymentMethod,
    required Quote quote,
    required ServiceRoute route,
  }) {
    final user = _users[clientId];
    final now = _now();
    final id = 'svc-${now.millisecondsSinceEpoch}';
    _serviceCounter++;

    final service = Service(
      id: id,
      clientId: clientId,
      clientName: user?.name ?? 'Cliente',
      clientPhone: user?.phone ?? '',
      code: 'GR-${_dateCode(now)}-0$_serviceCounter',
      status: ServiceStatus.pendingDispatch,
      vehicle: vehicle,
      truckTypeRequired: truckType,
      pickup: pickup,
      dropoff: dropoff,
      route: route,
      quote: quote,
      payment: ServicePayment(method: paymentMethod),
      timeline: ServiceTimeline(createdAt: now),
      createdAt: now,
    );

    _services[id] = service;
    _appendEvent(id, ServiceEventName.requestService, ServiceStatus.unknown,
        ServiceStatus.pendingDispatch, clientId, UserRole.client);
    if (user != null) _users[clientId] = user.copyWith(activeServiceId: id);
    _emitServices();

    _scheduleDispatch(id);
    return service;
  }

  /// Walks the service through the real state machine on a compressed clock, so
  /// a reviewer sees the whole flow in about a minute instead of forty.
  void _scheduleDispatch(String serviceId) {
    _after(const Duration(seconds: 6), () {
      final service = _services[serviceId];
      if (service == null || service.status != ServiceStatus.pendingDispatch) return;

      final candidate = _nearestIdleDriver(
        service.pickup.geo,
        service.truckTypeRequired,
      );
      if (candidate == null) {
        _transition(serviceId, ServiceStatus.needsManual,
            ServiceEventName.noDriversFound, 'system', UserRole.unknown);
        return;
      }

      final truck = _trucks[candidate.assignedTruckId ?? ''];
      final live = _live[candidate.id];
      final etaSeconds = live == null
          ? 600
          : (live.position.distanceKmTo(service.pickup.geo) / 28 * 3600).round();

      _services[serviceId] = service.copyWith(
        status: ServiceStatus.accepted,
        driverId: candidate.id,
        driverName: candidate.name,
        driverPhone: candidate.phone,
        driverRating: candidate.rating,
        truckId: truck?.id,
        truckPlate: truck?.displayPlate ?? '',
        truckLabel: truck?.displayName ?? '',
        assignedAt: _now(),
        timeline: service.timeline.copyWith(
          dispatchedAt: _now(),
          acceptedAt: _now(),
        ),
      );
      _drivers[candidate.id] = candidate.copyWith(currentServiceId: serviceId);
      if (live != null) {
        _live[candidate.id] = live.copyWith(
          state: DriverLiveState.onService,
          serviceId: serviceId,
        );
      }
      _tracking[serviceId] = ServiceTracking(
        serviceId: serviceId,
        position: live?.position ?? service.pickup.geo,
        driverId: candidate.id,
        etaSeconds: etaSeconds,
        updatedAt: _now(),
      );

      _appendEvent(serviceId, ServiceEventName.acceptService,
          ServiceStatus.pendingDispatch, ServiceStatus.accepted,
          candidate.id, UserRole.driver);
      _emitServices();
      _emitDrivers();
      _emitLive();
      _trackingController.add(serviceId);

      _driveToward(serviceId, service.pickup.geo, onArrive: () {
        _transition(serviceId, ServiceStatus.arrived,
            ServiceEventName.markArrived, candidate.id, UserRole.driver);
      });
    });
  }

  /// Glides the tracked position toward a target, emitting updates the way the
  /// RTDB mirror would.
  void _driveToward(String serviceId, LatLng target, {required VoidCallback onArrive}) {
    const steps = 12;
    var step = 0;
    final start = _tracking[serviceId]?.position ?? target;

    final timer = Timer.periodic(const Duration(milliseconds: 1500), (t) {
      step++;
      final service = _services[serviceId];
      if (service == null || service.isTerminal) {
        t.cancel();
        return;
      }
      final progress = step / steps;
      final position = start.lerp(target, progress.clamp(0.0, 1.0));
      final remainingMeters = position.distanceTo(target).round();

      _tracking[serviceId] = (_tracking[serviceId] ??
              ServiceTracking(serviceId: serviceId, position: position))
          .copyWith(
        position: position,
        heading: start.bearingTo(target),
        speedKmh: 34,
        remainingMeters: remainingMeters,
        etaSeconds: (remainingMeters / 1000 / 28 * 3600).round(),
        updatedAt: _now(),
      );
      final driverId = service.driverId;
      if (driverId != null) {
        final live = _live[driverId];
        if (live != null) {
          _live[driverId] = live.copyWith(
            lat: position.latitude,
            lng: position.longitude,
            heading: start.bearingTo(target),
            updatedAt: _now().millisecondsSinceEpoch,
          );
        }
      }
      _trackingController.add(serviceId);
      _emitLive();

      if (step >= steps) {
        t.cancel();
        onArrive();
      }
    });
    _timers.add(timer);
  }

  Driver? _nearestIdleDriver(LatLng pickup, TruckType type) {
    final candidates = _drivers.values.where((d) {
      final live = _live[d.id];
      return d.status.canWork &&
          d.isOnline &&
          !d.isBusy &&
          d.truckType == type &&
          live != null &&
          live.isOnline;
    }).toList();

    if (candidates.isEmpty) return null;
    candidates.sort((a, b) {
      final da = _live[a.id]!.position.distanceTo(pickup);
      final db = _live[b.id]!.position.distanceTo(pickup);
      return da.compareTo(db);
    });
    return candidates.first;
  }

  /// Applies a status change the way `applyTransition` does server-side.
  Result<void> transition(
    String serviceId,
    ServiceStatus to,
    ServiceEventName event,
    String actorId,
    UserRole actorRole,
  ) {
    final service = _services[serviceId];
    if (service == null) {
      return const Err(Failure(FailureCode.notFound));
    }
    _transition(serviceId, to, event, actorId, actorRole);
    return const Ok(null);
  }

  void _transition(
    String serviceId,
    ServiceStatus to,
    ServiceEventName event,
    String actorId,
    UserRole actorRole,
  ) {
    final service = _services[serviceId];
    if (service == null) return;
    final now = _now();
    final from = service.status;

    var timeline = service.timeline;
    timeline = switch (to) {
      ServiceStatus.arrived => timeline.copyWith(arrivedAt: now),
      ServiceStatus.inProgress => timeline.copyWith(startedAt: now),
      ServiceStatus.completed => timeline.copyWith(completedAt: now),
      ServiceStatus.closed => timeline.copyWith(closedAt: now),
      ServiceStatus.cancelled => timeline.copyWith(cancelledAt: now),
      _ => timeline,
    };

    var updated = service.copyWith(status: to, timeline: timeline, updatedAt: now);

    if (to == ServiceStatus.completed) {
      updated = updated.copyWith(
        finalQuote: service.quote,
        payment: service.payment.copyWith(
          status: service.payment.isCash
              ? PaymentStatus.cashPending
              : PaymentStatus.captured,
          capturedCents:
              service.payment.isCash ? 0 : service.quote.totalCents,
          capturedAt: service.payment.isCash ? null : now,
        ),
      );
      _recordEarnings(updated);
    }

    if (to.isTerminal) {
      final driverId = service.driverId;
      if (driverId != null) {
        final driver = _drivers[driverId];
        if (driver != null) {
          _drivers[driverId] = driver.copyWith(currentServiceId: null);
        }
        final live = _live[driverId];
        if (live != null) {
          _live[driverId] =
              live.copyWith(state: DriverLiveState.idle, serviceId: null);
        }
      }
      final client = _users[service.clientId];
      if (client != null) {
        _users[service.clientId] = client.copyWith(activeServiceId: null);
      }
    }

    _services[serviceId] = updated;
    _appendEvent(serviceId, event, from, to, actorId, actorRole);
    _emitServices();
    _emitDrivers();
    _emitLive();

    // On start, run the second leg to the destination so the client's map keeps
    // moving all the way through the tow.
    if (to == ServiceStatus.inProgress) {
      final dropoff = updated.dropoff?.geo;
      if (dropoff != null) {
        _driveToward(serviceId, dropoff, onArrive: () {});
      }
    }
  }

  void _recordEarnings(Service service) {
    final driverId = service.driverId;
    if (driverId == null) return;
    final gross = service.effectiveQuote.totalCents;
    final commission = Money.bps(gross, _pricing.commissionBps);

    final entry = EarningEntry(
      serviceId: service.id,
      driverId: driverId,
      serviceCode: service.code,
      grossCents: gross,
      commissionCents: commission,
      netCents: gross - commission,
      method: service.payment.method,
      pickupAddress: service.pickup.address,
      dropoffAddress: service.dropoff?.address ?? '',
      completedAt: _now(),
    );

    (_earningEntries[driverId] ??= [])
      ..removeWhere((e) => e.serviceId == service.id)
      ..insert(0, entry);

    final summary = _earnings[driverId];
    if (summary != null) {
      _earnings[driverId] = summary.copyWith(
        todayGrossCents: summary.todayGrossCents + gross,
        todayNetCents: summary.todayNetCents + entry.netCents,
        todayServices: summary.todayServices + 1,
        weekGrossCents: summary.weekGrossCents + gross,
        weekNetCents: summary.weekNetCents + entry.netCents,
        weekServices: summary.weekServices + 1,
        monthGrossCents: summary.monthGrossCents + gross,
        monthNetCents: summary.monthNetCents + entry.netCents,
        monthServices: summary.monthServices + 1,
        cashOwedCents: entry.driverOwesCompany
            ? summary.cashOwedCents + commission
            : summary.cashOwedCents,
        updatedAt: _now(),
      );
    }
  }

  void _appendEvent(
    String serviceId,
    ServiceEventName event,
    ServiceStatus from,
    ServiceStatus to,
    String actorId,
    UserRole actorRole,
  ) {
    (_events[serviceId] ??= []).add(
      ServiceEvent(
        id: 'evt-${_events[serviceId]?.length ?? 0}',
        event: event,
        from: from,
        to: to,
        actorId: actorId,
        actorRole: actorRole,
        at: _now(),
      ),
    );
  }

  void _after(Duration delay, void Function() action) {
    _timers.add(Timer(delay, action));
  }

  void _emitServices() => _servicesController.add(Map.unmodifiable(_services));

  void _emitDrivers() => _driversController.add(Map.unmodifiable(_drivers));

  void _emitLive() => _liveController.add(Map.unmodifiable(_live));

  void dispose() {
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    unawaited(_servicesController.close());
    unawaited(_driversController.close());
    unawaited(_liveController.close());
    unawaited(_messagesController.close());
    unawaited(_trackingController.close());
  }
}

typedef VoidCallback = void Function();
