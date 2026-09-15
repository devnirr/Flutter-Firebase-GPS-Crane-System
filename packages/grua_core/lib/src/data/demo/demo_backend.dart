import 'dart:async';
import 'dart:math' as math;

import '../../calls/voice_call.dart';
import '../../domain/enums.dart';
import '../../domain/failures.dart';
import '../../domain/models/app_user.dart';
import '../../domain/models/billing.dart';
import '../../domain/models/chat_prefs.dart';
import '../../domain/models/chat_request.dart';
import '../../domain/models/dispatch_models.dart';
import '../../domain/models/driver.dart';
import '../../domain/models/payments.dart';
import '../../domain/models/remote_config_models.dart';
import '../../domain/models/service.dart';
import '../../domain/models/truck.dart';
import '../../domain/repositories.dart';
import '../../domain/value_objects.dart';
import '../../utils/do_validators.dart';
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
  DemoBackend({
    math.Random? random,
    DateTime Function()? clock,
    this.dispatchDelay = const Duration(seconds: 6),
    this.driveStep = const Duration(milliseconds: 1500),
  })  : _random = random ?? math.Random(7),
        _now = clock ?? DateTime.now;

  final math.Random _random;
  final DateTime Function() _now;

  /// How long the simulated cascade takes to assign a chofer. Six seconds in
  /// the app so a reviewer sees the "buscando grúa" state; near-zero in tests,
  /// which should not spend real time waiting on a fake dispatcher.
  final Duration dispatchDelay;

  /// Interval between simulated GPS fixes while a truck is moving.
  final Duration driveStep;

  final Map<String, AppUser> _users = {};
  final Map<String, Driver> _drivers = {};
  final Map<String, Truck> _trucks = {};
  final Map<String, Service> _services = {};
  final Map<String, List<ChatMessage>> _messages = {};
  final Map<String, ChatRequest> _chatRequests = {};
  final Map<String, List<ChatMessage>> _chatRequestMessages = {};
  var _chatRequestCounter = 0;
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
  final _trucksController = StreamController<Map<String, Truck>>.broadcast();
  final _liveController = StreamController<Map<String, DriverLivePosition>>.broadcast();
  final Set<String> _appOpen = {};
  final _appOpenController = StreamController<Set<String>>.broadcast();
  final _usersController = StreamController<Map<String, AppUser>>.broadcast();
  final _messagesController = StreamController<String>.broadcast();
  final _trackingController = StreamController<String>.broadcast();
  final _chatRequestsController = StreamController<void>.broadcast();
  final _chatRequestMessagesController = StreamController<String>.broadcast();

  /// Who is typing where: `threadKey` → uid → when the last keystroke landed.
  final Map<String, Map<String, DateTime>> _typing = {};
  final _typingController = StreamController<String>.broadcast();

  /// What each person did to their own conversations: uid → thread key → the
  /// clear and delete stamps. Nobody else's screen ever sees it.
  final Map<String, Map<String, ChatThreadPrefs>> _chatPrefs = {};

  /// Who each person blocked: uid → the uids they will not hear from.
  final Map<String, Set<String>> _blocked = {};
  final _chatPrefsController = StreamController<String>.broadcast();

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

    // `demo-client-1` is the account the client app signs in as; the rest are
    // here so the customer roster in the panel has something to show.
    const clientSpecs =
        <(String, String, String, String, String, PaymentMethod, int, int)>[
      (
        'demo-client-1',
        'Ramón Peña',
        '+18095551234',
        'ramon@example.do',
        '',
        PaymentMethod.cash,
        4,
        210,
      ),
      (
        'demo-client-2',
        'Yokasta Almonte',
        '+18095552345',
        'yokasta@example.do',
        '',
        PaymentMethod.card,
        11,
        140,
      ),
      (
        'demo-client-3',
        'Autorepuestos del Este SRL',
        '+18092223456',
        'flota@autorepuestosdeleste.do',
        '131246789',
        PaymentMethod.card,
        26,
        95,
      ),
      (
        'demo-client-4',
        'Franklin Ureña',
        '+18293334567',
        '',
        '',
        PaymentMethod.cash,
        1,
        22,
      ),
      (
        'demo-client-5',
        'Deiby Mercedes',
        '+18494445678',
        'deiby@example.do',
        '',
        PaymentMethod.cash,
        0,
        3,
      ),
    ];

    for (final (id, name, phone, email, rnc, payment, completed, ageDays)
        in clientSpecs) {
      _users[id] = AppUser(
        id: id,
        phone: phone,
        name: name,
        email: email,
        rnc: rnc,
        preferredPaymentMethod: payment,
        completedServices: completed,
        createdAt: _now().subtract(Duration(days: ageDays)),
      );
    }

    // One blocked account, so the panel's blocked state is visible in demo
    // mode instead of only ever appearing in production.
    _users['demo-client-4'] = _users['demo-client-4']!.copyWith(
      blocked: true,
      blockedReason: r'Servicio sin pagar en efectivo (RD$3,200)',
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
    // What each chofer holds agrees with the cash jobs seeded for them, so the
    // office's Efectivo screen and its corte add up from the first launch.
    for (final entry in _drivers.entries.toList()) {
      final held = uncountedCash(entry.key)
          .fold(0, (sum, s) => sum + s.payment.capturedCents);
      _drivers[entry.key] = entry.value.copyWith(cashOnHandCents: held);
    }
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
      // Spaced a week apart, so the oldest is 23 days old whatever the hour.
      // The office's "últimos 30 días" starts at the beginning of today minus
      // 29 days, so a fixture built from `now` alone fell outside that window
      // in the small hours and the Servicios list quietly lost a row.
      final completedAt = _now().subtract(Duration(days: i * 7 + 2, hours: i * 3));
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
        vehicleType: serviceVehicle.type,
        distance: TripDistance.city(8.5 + i * 4.2, includedKm: _pricing.includedKm),
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

  Stream<Map<String, AppUser>> get userUpdates async* {
    yield Map.unmodifiable(_users);
    yield* _usersController.stream;
  }

  Stream<Map<String, Driver>> get driverUpdates async* {
    yield Map.unmodifiable(_drivers);
    yield* _driversController.stream;
  }

  Stream<Map<String, Truck>> get truckUpdates async* {
    yield Map.unmodifiable(_trucks);
    yield* _trucksController.stream;
  }

  Stream<Map<String, DriverLivePosition>> get liveUpdates async* {
    yield Map.unmodifiable(_live);
    yield* _liveController.stream;
  }

  /// Stands in for `/presence`: the choferes with the app open right now.
  Stream<Set<String>> get appOpenUpdates async* {
    yield Set.unmodifiable(_appOpen);
    yield* _appOpenController.stream;
  }

  bool isAppOpen(String driverId) => _appOpen.contains(driverId);

  void setAppOpen(String driverId, {required bool open}) {
    final changed = open ? _appOpen.add(driverId) : _appOpen.remove(driverId);
    if (changed) _appOpenController.add(Set.unmodifiable(_appOpen));

    // Mirrors `followAppPresence`: closing the app takes the chofer offline,
    // unless they are holding a job the customer is watching.
    if (!open && changed) {
      final driver = _drivers[driverId];
      if (driver != null && driver.isOnline && !driver.isBusy) {
        setDriverOnline(driverId, online: false);
      }
    }
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
    _emitUsers();
  }

  /// Opens a chofer account the way `createDriver` does server-side, minus the
  /// Auth user there is no such thing as here.
  ///
  /// Returns null when the cédula is already on file: the real callable refuses
  /// a duplicate rather than creating a second account for the same person, and
  /// the panel is built against that refusal.
  ///
  /// [selfRegistered] is the driver app's sign-up: the same inactive account,
  /// but opened by the chofer rather than by whoever the demo is acting as.
  Driver? createDriver({
    required String name,
    required String cedula,
    required String phone,
    required String email,
    required String licenseNumber,
    required DateTime licenseExpiry,
    String? truckId,
    List<String> zones = const [],
    String companyName = '',
    String rnc = '',
    bool selfRegistered = false,
  }) {
    final digits = cedula.replaceAll(RegExp(r'\D'), '');
    if (_drivers.values.any((d) => d.cedula == digits)) return null;

    final id = 'driver-${_drivers.length + 1}-${_now().millisecondsSinceEpoch}';
    final truck = truckId == null ? null : _trucks[truckId];

    final driver = Driver(
      id: id,
      name: name,
      cedula: digits,
      phone: phone,
      email: email,
      licenseNumber: licenseNumber,
      licenseExpiry: licenseExpiry,
      // Inactive until the documents are looked at, exactly as the server does.
      status: DriverStatus.inactive,
      statusReason: selfRegistered
          ? 'Registro desde la app: documentos pendientes de verificación'
          : 'Documentos pendientes de verificación',
      assignedTruckId: truckId,
      assignedTruckPlate: truck?.plate ?? '',
      truckType: truck?.type ?? TruckType.unknown,
      zones: zones,
      companyName: companyName,
      rnc: rnc,
      ratingCount: 0,
      completedServices: 0,
      // A chofer who signed up chose their own password and opened the
      // account themselves; one the office opened carries a temporary one.
      mustChangePassword: !selfRegistered,
      createdBy: selfRegistered ? id : currentUserId,
      createdAt: _now(),
      updatedAt: _now(),
    );

    _drivers[id] = driver;
    if (truck != null) {
      _trucks[truckId!] = truck.copyWith(
        assignedDriverId: id,
        assignedDriverName: name,
        updatedAt: _now(),
      );
      _emitTrucks();
    }
    _emitDrivers();
    return driver;
  }

  /// Mirrors the `updateDriver` callable. Returns the refusal, or null.
  String? updateDriver(
    String driverId, {
    required String name,
    required String phone,
    required String email,
    required String licenseNumber,
    required DateTime licenseExpiry,
    String? truckId,
    List<String> zones = const [],
    String companyName = '',
    String rnc = '',
  }) {
    final driver = _drivers[driverId];
    if (driver == null || driver.archived) return 'Chofer no encontrado.';

    final truckChanged = driver.assignedTruckId != truckId;
    if (truckChanged && driver.isBusy) {
      return 'Este chofer tiene un servicio en curso. '
          'Cambia la grúa cuando termine.';
    }
    final next = truckId == null ? null : _trucks[truckId];
    if (truckId != null && next == null) return 'Grúa no encontrada.';
    if (truckChanged &&
        next?.assignedDriverId != null &&
        next!.assignedDriverId != driverId) {
      return 'Esa grúa ya está asignada a otro chofer.';
    }
    // Auth refuses a second account on the same email; so does this.
    if (_drivers.values.any(
      (d) => d.id != driverId && d.email.toLowerCase() == email.toLowerCase(),
    )) {
      return 'Ya existe una cuenta con ese correo.';
    }

    final previousId = driver.assignedTruckId;
    if (truckChanged && previousId != null) {
      final previous = _trucks[previousId];
      if (previous != null) {
        _trucks[previousId] = previous.copyWith(
          assignedDriverId: null,
          assignedDriverName: '',
          updatedAt: _now(),
        );
      }
    }
    if (next != null) {
      _trucks[truckId!] = next.copyWith(
        assignedDriverId: driverId,
        assignedDriverName: name,
        updatedAt: _now(),
      );
    }

    _drivers[driverId] = driver.copyWith(
      name: name,
      phone: phone,
      email: email,
      licenseNumber: licenseNumber,
      licenseExpiry: licenseExpiry,
      zones: zones,
      companyName: companyName,
      rnc: rnc,
      assignedTruckId: truckId,
      assignedTruckPlate: next?.plate ?? '',
      truckType: next?.type ?? TruckType.unknown,
      isOnline: truckId != null && driver.isOnline,
      updatedAt: _now(),
    );
    _emitDrivers();
    _emitTrucks();
    return null;
  }

  /// Mirrors the `archiveDriver` callable. Returns the refusal, or null.
  String? archiveDriver(String driverId) {
    final driver = _drivers[driverId];
    if (driver == null) return 'Chofer no encontrado.';
    if (driver.archived) return null;
    if (driver.isBusy) {
      return 'Este chofer tiene un servicio en curso. Elimínalo cuando termine.';
    }

    final truckId = driver.assignedTruckId;
    final truck = truckId == null ? null : _trucks[truckId];
    if (truck != null) {
      _trucks[truckId!] = truck.copyWith(
        assignedDriverId: null,
        assignedDriverName: '',
        updatedAt: _now(),
      );
    }

    _drivers[driverId] = driver.copyWith(
      archived: true,
      status: DriverStatus.inactive,
      statusReason: 'Eliminado por la oficina',
      isOnline: false,
      assignedTruckId: null,
      assignedTruckPlate: '',
      truckType: TruckType.unknown,
      updatedAt: _now(),
    );
    _live.remove(driverId);
    _emitDrivers();
    _emitTrucks();
    _emitLive();
    return null;
  }

  // -------------------------------------------------------------------------
  // Fleet — mirrors callables/trucks.ts
  // -------------------------------------------------------------------------

  var _truckCounter = 100;

  /// The live truck the plate [key] belongs to, if any. Archived trucks free
  /// their plate, exactly as `trucks_by_plate` does.
  Truck? _truckWithPlate(String key) => _trucks.values
      .where((t) => !t.archived && DoValidators.plateKey(t.plate) == key)
      .firstOrNull;

  /// Mirrors the `createTruck` callable. Returns the new truck's id, or the
  /// refusal as a [Failure].
  Result<String> createTruck(TruckDetails details) {
    final refusal = _truckRefusal(details);
    if (refusal != null) return Result.err(refusal);

    final key = DoValidators.plateKey(details.plate);
    if (_truckWithPlate(key) != null) {
      return const Result.err(
        Failure(
          FailureCode.invalidInput,
          message: 'Ya existe una grúa con esa placa.',
        ),
      );
    }

    final id = 'truck-${_truckCounter++}';
    _trucks[id] = Truck(
      id: id,
      plate: key,
      make: details.make,
      model: details.model,
      year: details.year,
      color: details.color,
      type: details.type,
      capacityKg: details.capacityKg,
      registrationNumber: details.registrationNumber,
      insurancePolicy: details.insurancePolicy,
      insuranceExpiry: details.insuranceExpiry,
      marbeteExpiry: details.marbeteExpiry,
      createdBy: currentUserId,
      createdAt: _now(),
      updatedAt: _now(),
    );
    _emitTrucks();
    return Result.ok(id);
  }

  /// Mirrors the `updateTruck` callable. Returns the refusal, or null.
  Failure? updateTruck(String truckId, TruckDetails details) {
    final truck = _trucks[truckId];
    if (truck == null || truck.archived) {
      return const Failure(FailureCode.notFound, message: 'Grúa no encontrada.');
    }
    final refusal = _truckRefusal(details);
    if (refusal != null) return refusal;

    final key = DoValidators.plateKey(details.plate);
    final plateChanged = DoValidators.plateKey(truck.plate) != key;
    final typeChanged = truck.type != details.type;
    final holder = _truckWithPlate(key);
    if (plateChanged && holder != null && holder.id != truckId) {
      return const Failure(
        FailureCode.invalidInput,
        message: 'Ya existe una grúa con esa placa.',
      );
    }

    final driverId = truck.assignedDriverId;
    final driver = driverId == null ? null : _drivers[driverId];
    if (driver != null && (plateChanged || typeChanged) && driver.isBusy) {
      return const Failure(
        FailureCode.driverBusy,
        message: 'El chofer de esta grúa tiene un servicio en curso. '
            'Cambia la placa o el tipo cuando termine.',
      );
    }
    if (driver != null && typeChanged && driver.isOnline) {
      return const Failure(
        FailureCode.driverBusy,
        message: 'El chofer de esta grúa está en línea. '
            'Cambia el tipo cuando se desconecte.',
      );
    }

    _trucks[truckId] = truck.copyWith(
      plate: key,
      make: details.make,
      model: details.model,
      year: details.year,
      color: details.color,
      type: details.type,
      capacityKg: details.capacityKg,
      registrationNumber: details.registrationNumber,
      insurancePolicy: details.insurancePolicy,
      insuranceExpiry: details.insuranceExpiry,
      marbeteExpiry: details.marbeteExpiry,
      updatedAt: _now(),
    );
    if (driver != null && (plateChanged || typeChanged)) {
      _drivers[driverId!] = driver.copyWith(
        assignedTruckPlate: key,
        truckType: details.type,
        updatedAt: _now(),
      );
      _emitDrivers();
    }
    _emitTrucks();
    return null;
  }

  /// Mirrors the `archiveTruck` callable. Returns the refusal, or null.
  Failure? archiveTruck(String truckId) {
    final truck = _trucks[truckId];
    if (truck == null) {
      return const Failure(FailureCode.notFound, message: 'Grúa no encontrada.');
    }
    if (truck.archived) return null;

    final driverId = truck.assignedDriverId;
    final driver = driverId == null ? null : _drivers[driverId];
    if (driver != null && driver.isBusy) {
      return const Failure(
        FailureCode.driverBusy,
        message: 'El chofer de esta grúa tiene un servicio en curso. '
            'Elimínala cuando termine.',
      );
    }

    _trucks[truckId] = truck.copyWith(
      archived: true,
      active: false,
      inactiveReason: 'Eliminada por la oficina',
      assignedDriverId: null,
      assignedDriverName: '',
      updatedAt: _now(),
    );
    if (driver != null && driver.assignedTruckId == truckId) {
      _drivers[driverId!] = driver.copyWith(
        assignedTruckId: null,
        assignedTruckPlate: '',
        truckType: TruckType.unknown,
        isOnline: false,
        updatedAt: _now(),
      );
      final live = _live[driverId];
      if (live != null) {
        _live[driverId] = live.copyWith(
          isOnline: false,
          updatedAt: _now().millisecondsSinceEpoch,
        );
        _emitLive();
      }
      _emitDrivers();
    }
    _emitTrucks();
    return null;
  }

  /// The field checks `truckFields` applies on the server.
  Failure? _truckRefusal(TruckDetails details) {
    final plateError = DoValidators.plate(details.plate);
    if (plateError != null) {
      return Failure(FailureCode.invalidInput, message: plateError);
    }
    if (!details.type.isDispatchable ||
        details.capacityKg <= 0 ||
        details.make.trim().isEmpty ||
        details.model.trim().isEmpty) {
      return const Failure(
        FailureCode.invalidInput,
        message: 'Revisa los datos de la grúa.',
      );
    }
    return null;
  }

  /// Mirrors the `setDriverStatus` callable. Returns the refusal, or null.
  String? setDriverStatus(
    String driverId,
    DriverStatus status, {
    String reason = '',
  }) {
    final driver = _drivers[driverId];
    if (driver == null) return 'Chofer no encontrado.';
    if (driver.archived) return 'Este chofer fue eliminado.';
    if (status == DriverStatus.unknown) return 'Datos inválidos.';

    final stopping = !status.canWork;
    if (stopping && driver.isBusy) {
      return 'Este chofer tiene un servicio en curso. Reasígnalo primero.';
    }

    _drivers[driverId] = driver.copyWith(
      status: status,
      statusReason: reason,
      isOnline: !stopping && driver.isOnline,
      updatedAt: _now(),
    );
    if (stopping) {
      final live = _live[driverId];
      if (live != null) {
        _live[driverId] = live.copyWith(
          isOnline: false,
          updatedAt: _now().millisecondsSinceEpoch,
        );
      }
      _emitLive();
    }
    _emitDrivers();
    return null;
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

  /// Demo mode has no bucket, so an uploaded photo is kept here as a data URI
  /// and handed back as its "download URL".
  final _uploads = <String, String>{};

  void storeUpload(String path, String dataUri) => _uploads[path] = dataUri;

  /// Mirrors the `setDriverPhoto` callable. Returns the URL, or null when
  /// nothing was uploaded at [path] or the chofer does not exist.
  String? setDriverPhoto(String driverId, String path) {
    final driver = _drivers[driverId];
    final url = _uploads[path];
    if (driver == null || url == null) return null;
    _drivers[driverId] = driver.copyWith(photoUrl: url, updatedAt: _now());
    _emitDrivers();
    return url;
  }

  void addMessage(String serviceId, ChatMessage message) {
    (_messages[serviceId] ??= []).add(message);
    _messagesController.add(serviceId);
  }

  /// Mirrors `ChatRepository.markRead`: stamps every message the other party
  /// sent that [readerId] had not seen yet. Their own are left alone.
  void markMessagesRead(String serviceId, String readerId) {
    final messages = _messages[serviceId];
    if (messages == null) return;

    var changed = false;
    for (var i = 0; i < messages.length; i++) {
      final message = messages[i];
      if (message.senderId == readerId || message.isRead) continue;
      messages[i] = message.copyWith(readAt: _now());
      changed = true;
    }
    if (changed) _messagesController.add(serviceId);
  }

  // -------------------------------------------------------------------------
  // Chat requests — mirrors requestChat / respondChatRequest / closeChatRequest
  // -------------------------------------------------------------------------

  /// How long a chofer has to answer, and how long an accepted conversation
  /// stays open — the values the callables use.
  static const chatRequestTtl = Duration(minutes: 5);
  static const chatRequestOpenFor = Duration(hours: 2);

  List<ChatRequest> get allChatRequests => _chatRequestsWhere((_) => true);

  ChatRequest? chatRequest(String id) => _chatRequests[id];

  List<ChatRequest> _chatRequestsWhere(bool Function(ChatRequest) test) =>
      List.unmodifiable(
        _chatRequests.values.where(test).toList()
          ..sort(
            (a, b) => (b.createdAt ?? DateTime(0))
                .compareTo(a.createdAt ?? DateTime(0)),
          ),
      );

  Stream<List<ChatRequest>> chatRequestsWhere(
    bool Function(ChatRequest) test,
  ) async* {
    yield _chatRequestsWhere(test);
    yield* _chatRequestsController.stream.map((_) => _chatRequestsWhere(test));
  }

  Stream<ChatRequest?> chatRequestUpdates(String id) async* {
    yield _chatRequests[id];
    yield* _chatRequestsController.stream.map((_) => _chatRequests[id]);
  }

  Stream<List<ChatMessage>> chatRequestMessagesFor(String id) async* {
    yield List.unmodifiable(_chatRequestMessages[id] ?? const []);
    yield* _chatRequestMessagesController.stream
        .where((changed) => changed == id)
        .map((_) => List<ChatMessage>.unmodifiable(
              _chatRequestMessages[id] ?? const [],
            ));
  }

  /// Opens a request from [clientId] to [driverId], or returns the one already
  /// waiting or open between them. Refused when the chofer cannot take work.
  Result<String> createChatRequest({
    required String clientId,
    required String driverId,
  }) {
    final driver = _drivers[driverId];
    final online =
        (driver?.isOnline ?? false) || (_live[driverId]?.isOnline ?? false);
    if (driver == null || !driver.status.canWork || driver.isBusy || !online) {
      return const Result.err(Failure(FailureCode.chatRequestUnavailable));
    }

    final now = _now();
    for (final existing in _chatRequests.values) {
      if (existing.clientId == clientId &&
          existing.driverId == driverId &&
          existing.phaseAt(now) != ChatRequestPhase.over) {
        return Result.ok(existing.id);
      }
    }

    final id = 'chat-req-${++_chatRequestCounter}';
    _chatRequests[id] = ChatRequest(
      id: id,
      clientId: clientId,
      clientName: _users[clientId]?.shortName ?? 'Cliente',
      driverId: driverId,
      createdAt: now,
      expiresAt: now.add(chatRequestTtl),
    );
    _chatRequestsController.add(null);
    return Result.ok(id);
  }

  Result<void> respondChatRequest(
    String id,
    String driverId, {
    required bool accept,
  }) {
    final request = _chatRequests[id];
    if (request == null || request.driverId != driverId) {
      return const Result.err(Failure(FailureCode.notFound));
    }
    final now = _now();
    if (request.phaseAt(now) != ChatRequestPhase.waiting) {
      return const Result.err(Failure(FailureCode.chatRequestExpired));
    }

    _chatRequests[id] = accept
        ? request.copyWith(
            status: ChatRequestStatus.accepted,
            driverName: _drivers[driverId]?.shortName ?? 'Chofer',
            driverPhotoUrl: _drivers[driverId]?.photoUrl ?? '',
            respondedAt: now,
            closesAt: now.add(chatRequestOpenFor),
          )
        : request.copyWith(status: ChatRequestStatus.declined, respondedAt: now);
    _chatRequestsController.add(null);
    return const Result.ok(null);
  }

  // -------------------------------------------------------------------------
  // Voice calls — mirrors functions/src/callables/calls.ts
  // -------------------------------------------------------------------------

  final Map<String, VoiceCall> _calls = {};
  final _callsController = StreamController<void>.broadcast();
  var _callCounter = 0;

  List<VoiceCall> get allCalls => List.unmodifiable(_calls.values);

  VoiceCall? call(String id) => _calls[id];

  Stream<VoiceCall?> incomingCallFor(String uid) async* {
    VoiceCall? ringing() => _calls.values
        .where((c) => c.calleeId == uid && c.state == CallState.ringing)
        .fold<VoiceCall?>(null, (latest, c) => latest ?? c);
    yield ringing();
    yield* _callsController.stream.map((_) => ringing());
  }

  Stream<VoiceCall?> callUpdates(String id) async* {
    yield _calls[id];
    yield* _callsController.stream.map((_) => _calls[id]);
  }

  void _emitCalls() => _callsController.add(null);

  /// Rings the other party on a service. Refused the same ways the callable is.
  Result<CallJoin> startCall(
    String serviceId,
    String callerId, {
    bool video = false,
  }) {
    final service = _services[serviceId];
    if (service == null) {
      return const Err(Failure(FailureCode.notFound));
    }
    final isClient = callerId == service.clientId;
    if (!isClient && callerId != service.driverId) {
      return const Err(Failure(FailureCode.permissionDenied));
    }
    if (!service.canCall) {
      return const Err(
        Failure(
          FailureCode.invalidTransition,
          message: 'Solo puedes llamar mientras el servicio está en curso.',
        ),
      );
    }
    final busy = _calls.values.any(
      (c) =>
          c.serviceId == serviceId &&
          (c.state == CallState.ringing || c.state == CallState.accepted),
    );
    if (busy) {
      return const Err(
        Failure(
          FailureCode.invalidTransition,
          message: 'Ya hay una llamada en curso.',
        ),
      );
    }

    final id = 'call-${++_callCounter}';
    final clientName = service.clientName.isEmpty ? 'Cliente' : service.clientName;
    final driverName = service.driverName.isEmpty ? 'Chofer' : service.driverName;
    _calls[id] = VoiceCall(
      id: id,
      serviceId: serviceId,
      state: CallState.ringing,
      callerId: callerId,
      callerName: isClient ? clientName : driverName,
      calleeId: isClient ? service.driverId! : service.clientId,
      calleeName: isClient ? driverName : clientName,
      video: video,
      createdAt: _now(),
    );
    _emitCalls();
    return Ok(
      CallJoin(
        callId: id,
        peerName: isClient ? driverName : clientName,
        url: '',
        token: '',
        video: video,
      ),
    );
  }

  /// Rings the other side of an open pre-job conversation. Refused the same
  /// ways the callable is.
  Result<CallJoin> startChatRequestCall(
    String requestId,
    String callerId, {
    bool video = false,
  }) {
    final request = _chatRequests[requestId];
    if (request == null) return const Err(Failure(FailureCode.notFound));
    final isClient = callerId == request.clientId;
    if (!isClient && callerId != request.driverId) {
      return const Err(Failure(FailureCode.permissionDenied));
    }
    if (request.phaseAt(_now()) != ChatRequestPhase.open) {
      return const Err(
        Failure(
          FailureCode.invalidTransition,
          message: 'Solo puedes llamar mientras la conversación está abierta.',
        ),
      );
    }
    final busy = _calls.values.any(
      (c) =>
          c.chatRequestId == requestId &&
          (c.state == CallState.ringing || c.state == CallState.accepted),
    );
    if (busy) {
      return const Err(
        Failure(
          FailureCode.invalidTransition,
          message: 'Ya hay una llamada en curso.',
        ),
      );
    }

    final id = 'call-${++_callCounter}';
    final clientName = request.clientName.isEmpty ? 'Cliente' : request.clientName;
    final driverName = request.driverName.isEmpty ? 'Chofer' : request.driverName;
    _calls[id] = VoiceCall(
      id: id,
      serviceId: '',
      chatRequestId: requestId,
      state: CallState.ringing,
      callerId: callerId,
      callerName: isClient ? clientName : driverName,
      calleeId: isClient ? request.driverId : request.clientId,
      calleeName: isClient ? driverName : clientName,
      video: video,
      createdAt: _now(),
    );
    _emitCalls();
    return Ok(
      CallJoin(
        callId: id,
        peerName: isClient ? driverName : clientName,
        url: '',
        token: '',
        video: video,
      ),
    );
  }

  Result<CallJoin> answerCall(String callId, String uid) {
    final call = _calls[callId];
    if (call == null) return const Err(Failure(FailureCode.notFound));
    if (uid != call.calleeId) {
      return const Err(
        Failure(FailureCode.permissionDenied, message: 'Esta llamada no es para ti.'),
      );
    }
    if (call.state != CallState.ringing) {
      return const Err(
        Failure(FailureCode.invalidTransition, message: 'La llamada ya terminó.'),
      );
    }
    _calls[callId] = call.copyWith(state: CallState.accepted, answeredAt: _now());
    _emitCalls();
    return Ok(
      CallJoin(
        callId: callId,
        peerName: call.callerName,
        url: '',
        token: '',
        video: call.video,
      ),
    );
  }

  Result<void> endCall(String callId, String uid, EndCallReason reason) {
    final call = _calls[callId];
    if (call == null) return const Err(Failure(FailureCode.notFound));
    if (uid != call.callerId && uid != call.calleeId) {
      return const Err(Failure(FailureCode.permissionDenied));
    }
    // Idempotent, like the callable.
    if (call.state.isOver) return const Ok(null);

    final next = call.state == CallState.accepted
        ? CallState.ended
        : uid == call.calleeId
            ? CallState.declined
            : reason == EndCallReason.missed
                ? CallState.missed
                : CallState.cancelled;
    _calls[callId] = call.copyWith(state: next);
    _emitCalls();
    return const Ok(null);
  }

  Result<void> closeChatRequest(String id, String callerId) {
    final request = _chatRequests[id];
    final byClient = request?.clientId == callerId;
    if (request == null || (!byClient && request.driverId != callerId)) {
      return const Result.err(Failure(FailureCode.notFound));
    }

    final next = switch (request.phaseAt(_now())) {
      ChatRequestPhase.waiting =>
        byClient ? ChatRequestStatus.cancelled : ChatRequestStatus.declined,
      ChatRequestPhase.open => ChatRequestStatus.closed,
      ChatRequestPhase.over => null,
    };
    if (next != null) {
      _chatRequests[id] = request.copyWith(status: next);
      _chatRequestsController.add(null);
    }
    return const Result.ok(null);
  }

  void addChatRequestMessage(String id, ChatMessage message) {
    (_chatRequestMessages[id] ??= []).add(message);
    _chatRequestMessagesController.add(id);
  }

  void markChatRequestMessagesRead(String id, String readerId) {
    final messages = _chatRequestMessages[id];
    if (messages == null) return;

    var changed = false;
    for (var i = 0; i < messages.length; i++) {
      final message = messages[i];
      if (message.senderId == readerId || message.isRead) continue;
      messages[i] = message.copyWith(readAt: _now());
      changed = true;
    }
    if (changed) _chatRequestMessagesController.add(id);
  }

  /// Retracts messages in a job's chat, the way the rules let either party:
  /// the words and the photo go, a tombstone stays.
  void retractMessages(String serviceId, List<String> ids) {
    if (_retract(_messages[serviceId], ids)) {
      _messagesController.add(serviceId);
    }
  }

  /// The same, in a conversation opened from the map.
  void retractChatRequestMessages(String requestId, List<String> ids) {
    if (_retract(_chatRequestMessages[requestId], ids)) {
      _chatRequestMessagesController.add(requestId);
    }
  }

  bool _retract(List<ChatMessage>? messages, List<String> ids) {
    if (messages == null) return false;
    final wanted = ids.toSet();
    var changed = false;
    for (var i = 0; i < messages.length; i++) {
      final message = messages[i];
      // Only once: a tombstone has nothing left to clear.
      if (!wanted.contains(message.id) || message.isDeleted) continue;
      messages[i] = message.copyWith(
        text: '',
        imageUrl: '',
        deletedAt: _now(),
      );
      changed = true;
    }
    return changed;
  }

  /// How long one keystroke keeps the indicator alive, as in the real one.
  static const _typingFreshness = Duration(seconds: 8);

  /// Who is typing in one conversation. A flag nobody refreshed ages out, so a
  /// phone that died mid-word does not say "escribiendo…" forever.
  Stream<Set<String>> typingFor(String threadKey) async* {
    yield _typingNow(threadKey);
    yield* _typingController.stream
        .where((changed) => changed == threadKey)
        .map((_) => _typingNow(threadKey));
  }

  Set<String> _typingNow(String threadKey) {
    final entries = _typing[threadKey];
    if (entries == null) return const {};
    final now = _now();
    return {
      for (final entry in entries.entries)
        if (now.difference(entry.value) < _typingFreshness) entry.key,
    };
  }

  void setTyping({
    required String threadKey,
    required String uid,
    required bool typing,
  }) {
    final entries = _typing.putIfAbsent(threadKey, () => {});
    if (typing) {
      entries[uid] = _now();
    } else {
      entries.remove(uid);
    }
    _typingController.add(threadKey);
  }

  // -------------------------------------------------------------------------
  // Each person's own view of their conversations
  // -------------------------------------------------------------------------

  Stream<Map<String, ChatThreadPrefs>> chatPrefsFor(String uid) async* {
    yield _prefsOf(uid);
    yield* _chatPrefsController.stream
        .where((changed) => changed == uid)
        .map((_) => _prefsOf(uid));
  }

  Stream<Set<String>> blockedFor(String uid) async* {
    yield {...?_blocked[uid]};
    yield* _chatPrefsController.stream
        .where((changed) => changed == uid)
        .map((_) => {...?_blocked[uid]});
  }

  Map<String, ChatThreadPrefs> _prefsOf(String uid) => {...?_chatPrefs[uid]};

  /// Hides what has been said so far, and the conversation itself when
  /// [alsoFromList] — the difference between "vaciar" and "eliminar".
  void clearChatThread(
    String uid,
    String threadKey, {
    bool alsoFromList = false,
  }) {
    final now = _now();
    _chatPrefs.putIfAbsent(uid, () => {})[threadKey] = ChatThreadPrefs(
      clearedAt: now,
      deletedAt: alsoFromList ? now : _chatPrefs[uid]?[threadKey]?.deletedAt,
    );
    _chatPrefsController.add(uid);
  }

  void setBlocked(String uid, String otherUid, {required bool blocked}) {
    final list = _blocked.putIfAbsent(uid, () => {});
    if (blocked) {
      list.add(otherUid);
    } else {
      list.remove(otherUid);
    }
    _chatPrefsController.add(uid);
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
    String? preferredDriverId,
  }) {
    final user = _users[clientId];
    final now = _now();
    final id = 'svc-${now.millisecondsSinceEpoch}';
    _serviceCounter++;

    // A heavy job waits for the operator, exactly as `requestService` does it.
    final heavy = vehicle.type.isHeavy;
    final status = heavy ? ServiceStatus.needsManual : ServiceStatus.pendingDispatch;

    final service = Service(
      id: id,
      clientId: clientId,
      clientName: user?.name ?? 'Cliente',
      clientPhone: user?.phone ?? '',
      code: 'GR-${_dateCode(now)}-0$_serviceCounter',
      status: status,
      operatorReview: heavy
          ? OperatorReview(isRequired: true, estimatedTotalCents: quote.totalCents)
          : null,
      dispatch: heavy
          ? const DispatchState(
              lastReason: 'Vehículo pesado: confirma disponibilidad y precio '
                  'final con el cliente.',
            )
          : const DispatchState(),
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
        status, clientId, UserRole.client);
    if (user != null) _users[clientId] = user.copyWith(activeServiceId: id);
    _emitServices();

    if (!heavy) _scheduleDispatch(id, preferredDriverId: preferredDriverId);
    return service;
  }

  /// Mirrors `confirmHeavyService`: the operator's price goes on the quote,
  /// and only then does the job look for a grúa. Returns the refusal, or null.
  String? confirmHeavyService({
    required String serviceId,
    required int totalCents,
    String note = '',
  }) {
    final service = _services[serviceId];
    if (service == null) return 'Este servicio ya no existe.';
    final review = service.operatorReview;
    if (review == null ||
        !review.isPending ||
        service.status != ServiceStatus.needsManual) {
      return 'Este servicio no tiene un precio por confirmar.';
    }
    if (totalCents < 10000) return 'Revisa el precio e intenta de nuevo.';

    final now = _now();
    _services[serviceId] = service.copyWith(
      status: ServiceStatus.pendingDispatch,
      quote: Pricing.confirmed(service.quote, totalCents),
      operatorReview: review.copyWith(
        state: OperatorReviewState.confirmed,
        confirmedTotalCents: totalCents,
        confirmedBy: currentUserId,
        confirmedAt: now,
        note: note,
      ),
      dispatch: service.dispatch.copyWith(lastReason: ''),
      updatedAt: now,
    );
    _appendEvent(serviceId, ServiceEventName.confirmHeavyService,
        ServiceStatus.needsManual, ServiceStatus.pendingDispatch, currentUserId,
        UserRole.admin);
    _emitServices();
    _scheduleDispatch(serviceId);
    return null;
  }

  /// Walks the service through the real state machine on a compressed clock, so
  /// a reviewer sees the whole flow in about a minute instead of forty.
  ///
  /// [preferredDriverId] — the truck picked on the map — goes first when it
  /// can take the job, exactly as `dispatchNext` does it.
  void _scheduleDispatch(String serviceId, {String? preferredDriverId}) {
    _after(dispatchDelay, () {
      final service = _services[serviceId];
      if (service == null || service.status != ServiceStatus.pendingDispatch) return;

      final candidate = _availableDriver(
            preferredDriverId,
            service.truckTypeRequired,
          ) ??
          _nearestIdleDriver(
            service.pickup.geo,
            service.truckTypeRequired,
          );
      if (candidate == null) {
        _transition(serviceId, ServiceStatus.needsManual,
            ServiceEventName.noDriversFound, 'system', UserRole.unknown);
        return;
      }

      _commitAssignment(
        serviceId: serviceId,
        driver: candidate,
        event: ServiceEventName.acceptService,
        actorRole: UserRole.driver,
        actorId: candidate.id,
      );
    });
  }

  /// Puts [driver] on the job and starts them moving, the one way it happens.
  ///
  /// Shared by the cascade and by a dispatcher assigning by hand: two copies of
  /// this drifted apart is how a manually assigned job ends up without a
  /// tracking document and a customer watches an empty map.
  void _commitAssignment({
    required String serviceId,
    required Driver driver,
    required ServiceEventName event,
    required UserRole actorRole,
    required String actorId,
  }) {
    final service = _services[serviceId];
    if (service == null) return;

    final truck = _trucks[driver.assignedTruckId ?? ''];
    final live = _live[driver.id];
    final etaSeconds = live == null
        ? 600
        : (live.position.distanceKmTo(service.pickup.geo) / 28 * 3600).round();

    _services[serviceId] = service.copyWith(
      status: ServiceStatus.accepted,
      driverId: driver.id,
      driverName: driver.name,
      driverPhone: driver.phone,
      driverPhotoUrl: driver.photoUrl,
      driverRating: driver.rating,
      truckId: truck?.id,
      truckPlate: truck?.displayPlate ?? '',
      truckLabel: truck?.displayName ?? '',
      assignedAt: _now(),
      assignmentMode: actorRole == UserRole.driver
          ? AssignmentMode.auto
          : AssignmentMode.manual,
      timeline: service.timeline.copyWith(
        dispatchedAt: _now(),
        acceptedAt: _now(),
      ),
    );
    _drivers[driver.id] = driver.copyWith(currentServiceId: serviceId);
    if (live != null) {
      _live[driver.id] = live.copyWith(
        state: DriverLiveState.onService,
        serviceId: serviceId,
      );
    }
    _tracking[serviceId] = ServiceTracking(
      serviceId: serviceId,
      position: live?.position ?? service.pickup.geo,
      driverId: driver.id,
      etaSeconds: etaSeconds,
      updatedAt: _now(),
    );

    _appendEvent(serviceId, event, service.status, ServiceStatus.accepted,
        actorId, actorRole);
    _emitServices();
    _emitDrivers();
    _emitLive();
    _trackingController.add(serviceId);

    _driveToward(serviceId, service.pickup.geo, onArrive: () {
      _transition(serviceId, ServiceStatus.arrived,
          ServiceEventName.markArrived, driver.id, UserRole.driver);
    });
  }

  /// A dispatcher hands the job to a chofer. Returns the refusal, or null.
  ///
  /// Mirrors `assignServiceManually`: the chofer has to be able to take it, and
  /// the service has to still be waiting for one. A dispatcher acting on a list
  /// that is a few seconds stale must be told no, not quietly given a chofer
  /// who is already towing something else.
  String? assignServiceManually({
    required String serviceId,
    required String driverId,
  }) {
    final service = _services[serviceId];
    if (service == null) return 'Este servicio ya no existe.';
    if (!service.status.isAwaitingDriver) {
      return 'Este servicio ya no está esperando chofer.';
    }
    if (service.awaitsOperator) {
      return 'Confirma primero la disponibilidad y el precio con el cliente.';
    }

    final driver = _drivers[driverId];
    if (driver == null) return 'Chofer no encontrado.';
    if (!driver.status.canWork) return 'Ese chofer no está activo.';
    if (driver.isBusy) return 'Ese chofer ya tiene un servicio.';
    if (!driver.truckType.canServe(service.truckTypeRequired)) {
      return 'Ese chofer no tiene una grúa de '
          '${service.truckTypeRequired.label}.';
    }

    _commitAssignment(
      serviceId: serviceId,
      driver: driver,
      event: ServiceEventName.assignServiceManually,
      actorRole: UserRole.admin,
      actorId: currentUserId,
    );
    return null;
  }

  /// Glides the tracked position toward a target, emitting updates the way the
  /// RTDB mirror would.
  void _driveToward(String serviceId, LatLng target, {required VoidCallback onArrive}) {
    const steps = 12;
    var step = 0;
    final start = _tracking[serviceId]?.position ?? target;

    final timer = Timer.periodic(driveStep, (t) {
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

  bool _canTake(Driver d, TruckType type) {
    final live = _live[d.id];
    return d.status.canWork &&
        d.isOnline &&
        !d.isBusy &&
        // Capable, not identical — the same rule the real cascade uses.
        d.truckType.canServe(type) &&
        live != null &&
        live.isOnline;
  }

  /// [driverId], if that chofer can take a job of [type] right now.
  Driver? _availableDriver(String? driverId, TruckType type) {
    final driver = driverId == null ? null : _drivers[driverId];
    return driver != null && _canTake(driver, type) ? driver : null;
  }

  Driver? _nearestIdleDriver(LatLng pickup, TruckType type) {
    final candidates = _drivers.values.where((d) => _canTake(d, type)).toList();

    if (candidates.isEmpty) return null;
    candidates.sort((a, b) {
      // The right truck before the bigger one, the same tie-break the real
      // cascade applies as a score penalty.
      final exact = (a.truckType == type ? 0 : 1) - (b.truckType == type ? 0 : 1);
      if (exact != 0) return exact;
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
      // A card is charged at completion, and Stripe's confirmation closes the
      // job a moment later — as the webhook does for real.
      if (service.payment.isCard) {
        _after(const Duration(milliseconds: 600), () {
          if (_services[serviceId]?.status == ServiceStatus.completed) {
            _transition(serviceId, ServiceStatus.closed,
                ServiceEventName.closeService, 'system', UserRole.unknown);
          }
        });
      }
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

  // -------------------------------------------------------------------------
  // Payments — mirrors functions/src/callables/payments.ts
  // -------------------------------------------------------------------------

  final List<CashSettlement> _settlements = [];
  var _settlementCounter = 0;

  /// Newest first.
  List<CashSettlement> cashSettlements({String? driverId}) => List.unmodifiable(
        _settlements.reversed.where((s) => driverId == null || s.driverId == driverId),
      );

  /// The cash jobs [driverId] collected that no corte counted yet.
  List<Service> uncountedCash(String driverId) => [
        for (final s in _services.values)
          if (s.driverId == driverId &&
              s.payment.isCash &&
              s.payment.status == PaymentStatus.cashCollected &&
              s.payment.cashSettlementId == null)
            s,
      ];

  Result<void> _replacePayment(
    String serviceId,
    ServicePayment Function(ServicePayment payment) change,
  ) {
    final service = _services[serviceId];
    if (service == null) return const Err(Failure(FailureCode.notFound));
    _services[serviceId] =
        service.copyWith(payment: change(service.payment), updatedAt: _now());
    _emitServices();
    return const Ok(null);
  }

  /// "Pagar en efectivo" / "Pagar con tarjeta". The chofer may only mark cash.
  Result<void> choosePaymentMethod(
    String serviceId,
    String actorId,
    PaymentMethod method,
  ) {
    final service = _services[serviceId];
    if (service == null) return const Err(Failure(FailureCode.notFound));
    final isClient = actorId == service.clientId;
    final isDriver = actorId == service.driverId;
    if (!isClient && !(isDriver && method == PaymentMethod.cash)) {
      return const Err(
        Failure(
          FailureCode.permissionDenied,
          message: 'Solo el cliente puede elegir pagar con tarjeta.',
        ),
      );
    }
    if (service.status != ServiceStatus.accepted &&
        service.status != ServiceStatus.arrived) {
      return const Err(
        Failure(
          FailureCode.invalidTransition,
          message: 'La forma de pago ya no se puede cambiar en este servicio.',
        ),
      );
    }
    return _replacePayment(
      serviceId,
      (p) => method == PaymentMethod.cash
          ? p.copyWith(
              method: PaymentMethod.cash,
              status: PaymentStatus.none,
              intentId: null,
              authorizedCents: 0,
            )
          : p.copyWith(method: PaymentMethod.card),
    );
  }

  /// Demo mode has no Stripe to hold a card with: the test card is held as
  /// soon as the customer asks, with the same headroom the server holds.
  Result<PreparedPayment> holdDemoCard(String serviceId, String clientId) {
    final service = _services[serviceId];
    if (service == null) return const Err(Failure(FailureCode.notFound));
    if (service.clientId != clientId) {
      return const Err(Failure(FailureCode.permissionDenied));
    }
    final held = service.quote.totalCents +
        Money.bps(service.quote.totalCents, _pricing.authorizationBufferBps);
    _replacePayment(
      serviceId,
      (p) => p.copyWith(
        method: PaymentMethod.card,
        status: PaymentStatus.authorized,
        gateway: 'demo',
        intentId: 'pi_demo_$serviceId',
        authorizedCents: held,
        authorizedAt: _now(),
        brand: 'Visa',
        last4: '4242',
      ),
    );
    return Ok(
      PreparedPayment(
        alreadyAuthorized: true,
        amountCents: held,
        quoteCents: service.quote.totalCents,
        testMode: true,
      ),
    );
  }

  /// "Cobrado en efectivo": the job is paid, and the chofer now holds the cash.
  Result<void> confirmCashCollected(String serviceId, String driverId, int amountCents) {
    final service = _services[serviceId];
    if (service == null) return const Err(Failure(FailureCode.notFound));
    if (!service.payment.isCash) {
      return const Err(
        Failure(
          FailureCode.invalidTransition,
          message: 'Este servicio se cobra con tarjeta. No hay efectivo que recibir.',
        ),
      );
    }
    final now = _now();
    _services[serviceId] = service.copyWith(
      payment: service.payment.copyWith(
        status: PaymentStatus.cashCollected,
        capturedCents: amountCents,
        cashCollectedAt: now,
      ),
    );
    final driver = _drivers[driverId];
    if (driver != null) {
      _drivers[driverId] =
          driver.copyWith(cashOnHandCents: driver.cashOnHandCents + amountCents);
    }
    _transition(serviceId, ServiceStatus.closed,
        ServiceEventName.confirmCashCollected, driverId, UserRole.driver);
    return const Ok(null);
  }

  /// The corte: the office receives the cash [driverId] holds.
  Result<int> settleDriverCash(String driverId, String staffId, {String note = ''}) {
    final driver = _drivers[driverId];
    if (driver == null) return const Err(Failure(FailureCode.notFound));
    final jobs = uncountedCash(driverId);
    if (jobs.isEmpty) {
      return const Err(
        Failure(
          FailureCode.invalidTransition,
          message: 'Este chofer no tiene efectivo por entregar.',
        ),
      );
    }
    final total = jobs.fold(0, (sum, s) => sum + s.payment.capturedCents);
    final id = 'corte-${++_settlementCounter}';
    final now = _now();
    for (final job in jobs) {
      _services[job.id] = job.copyWith(
        payment: job.payment.copyWith(cashSettlementId: id, cashSettledAt: now),
      );
    }
    _settlements.add(
      CashSettlement(
        id: id,
        driverId: driverId,
        driverName: driver.name,
        amountCents: total,
        serviceCount: jobs.length,
        note: note,
        settledBy: staffId,
        createdAt: now,
      ),
    );
    _drivers[driverId] = driver.copyWith(
      cashOnHandCents: math.max(0, driver.cashOnHandCents - total),
      cashOwedCents: 0,
      lastCashSettlementAt: now,
    );
    final summary = _earnings[driverId];
    if (summary != null) _earnings[driverId] = summary.copyWith(cashOwedCents: 0);
    _emitServices();
    _emitDrivers();
    return Ok(total);
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

  void _emitTrucks() => _trucksController.add(Map.unmodifiable(_trucks));

  void _emitLive() => _liveController.add(Map.unmodifiable(_live));

  void _emitUsers() => _usersController.add(Map.unmodifiable(_users));

  void dispose() {
    unawaited(_callsController.close());
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    unawaited(_servicesController.close());
    unawaited(_driversController.close());
    unawaited(_liveController.close());
    unawaited(_trucksController.close());
    unawaited(_appOpenController.close());
    unawaited(_messagesController.close());
    unawaited(_trackingController.close());
    unawaited(_chatRequestsController.close());
    unawaited(_chatRequestMessagesController.close());
    unawaited(_typingController.close());
  }
}

typedef VoidCallback = void Function();
