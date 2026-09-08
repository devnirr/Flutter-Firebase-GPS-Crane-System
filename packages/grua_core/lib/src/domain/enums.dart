/// Domain enumerations shared by the three apps and mirrored in
/// `functions/src/lib/enums.ts`.
///
/// Every enum here follows the same contract: a `wire` string that is the only
/// thing ever written to Firestore, and a tolerant `fromWire` that resolves an
/// unrecognised value to an `unknown` member instead of throwing. That matters
/// because an app on a customer's phone can be months behind the backend, and a
/// chofer whose app crashes on a new status is a chofer who cannot work.
library;

/// Resolves [wire] against [values], falling back to [fallback].
T _resolve<T>(List<T> values, String? wire, String Function(T) key, T fallback) {
  if (wire == null) return fallback;
  for (final value in values) {
    if (key(value) == wire) return value;
  }
  return fallback;
}

// ---------------------------------------------------------------------------
// Identity
// ---------------------------------------------------------------------------

enum UserRole {
  client('client'),
  driver('driver'),
  admin('admin'),
  ops('ops'),
  unknown('unknown');

  const UserRole(this.wire);

  final String wire;

  static UserRole fromWire(String? wire) =>
      _resolve(UserRole.values, wire, (v) => v.wire, UserRole.unknown);

  bool get isStaff => this == UserRole.admin || this == UserRole.ops;
}

/// Lifecycle of a chofer's account, controlled entirely from the admin panel.
enum DriverStatus {
  /// Created but not yet cleared to work — usually missing documents.
  inactive('inactive'),

  /// Cleared to go online and receive offers.
  active('active'),

  /// Blocked by an admin. Cannot log in to work.
  suspended('suspended'),

  unknown('unknown');

  const DriverStatus(this.wire);

  final String wire;

  static DriverStatus fromWire(String? wire) =>
      _resolve(DriverStatus.values, wire, (v) => v.wire, DriverStatus.unknown);

  bool get canWork => this == DriverStatus.active;
}

/// What the chofer is doing right now, as published to `/live/{driverId}`.
enum DriverLiveState {
  /// Online and dispatchable.
  idle('idle'),

  /// Online but already committed to a service.
  onService('on_service'),

  unknown('unknown');

  const DriverLiveState(this.wire);

  final String wire;

  static DriverLiveState fromWire(String? wire) =>
      _resolve(DriverLiveState.values, wire, (v) => v.wire, DriverLiveState.unknown);
}

// ---------------------------------------------------------------------------
// Fleet
// ---------------------------------------------------------------------------

/// The kind of grúa required. This is the field dispatch filters on, so an
/// unknown value must never be dispatchable.
enum TruckType {
  /// Flatbed. Required for anything that cannot roll or must not be towed on
  /// its own wheels.
  plataforma('plataforma', 'Plataforma'),

  /// Hook and chain / wheel-lift. The everyday tow.
  gancho('gancho', 'Gancho'),

  /// Heavy recovery for trucks and buses.
  pesada('pesada', 'Grúa pesada'),

  unknown('unknown', 'Desconocido');

  const TruckType(this.wire, this.label);

  final String wire;

  /// Spanish label shown to users in the Dominican Republic.
  final String label;

  static TruckType fromWire(String? wire) =>
      _resolve(TruckType.values, wire, (v) => v.wire, TruckType.unknown);

  bool get isDispatchable => this != TruckType.unknown;
}

/// The customer's vehicle class, used to infer [TruckType].
enum VehicleType {
  sedan('sedan', 'Carro / Sedán'),
  suv('suv', 'Jeepeta / SUV'),
  camioneta('camioneta', 'Camioneta'),
  camion('camion', 'Camión / Autobús'),
  motor('motor', 'Motor'),
  unknown('unknown', 'Otro');

  const VehicleType(this.wire, this.label);

  final String wire;
  final String label;

  static VehicleType fromWire(String? wire) =>
      _resolve(VehicleType.values, wire, (v) => v.wire, VehicleType.unknown);
}

/// Why the vehicle needs a grúa. Drives both pricing and truck-type inference.
enum VehicleCondition {
  noArranca('no_arranca', 'No arranca'),
  accidentado('accidentado', 'Accidentado'),
  ruedasBloqueadas('ruedas_bloqueadas', 'Ruedas bloqueadas'),
  volcado('volcado', 'Volcado'),
  sinCombustible('sin_combustible', 'Sin combustible'),
  gomaPinchada('goma_pinchada', 'Goma pinchada'),
  unknown('unknown', 'Otro problema');

  const VehicleCondition(this.wire, this.label);

  final String wire;
  final String label;

  static VehicleCondition fromWire(String? wire) =>
      _resolve(VehicleCondition.values, wire, (v) => v.wire, VehicleCondition.unknown);

  /// A vehicle that cannot roll on its own wheels needs a flatbed.
  bool get requiresFlatbed =>
      this == VehicleCondition.volcado ||
      this == VehicleCondition.accidentado ||
      this == VehicleCondition.ruedasBloqueadas;
}

/// Documents a chofer must keep current to stay `active`.
enum DriverDocumentType {
  licencia('licencia', 'Licencia de conducir', required: true),
  cedula('cedula', 'Cédula', required: true),
  seguro('seguro', 'Seguro del vehículo', required: true),
  marbete('marbete', 'Marbete', required: true),
  matricula('matricula', 'Matrícula', required: true),
  certificadoMedico('certificado_medico', 'Certificado médico', required: false),
  unknown('unknown', 'Documento', required: false);

  const DriverDocumentType(this.wire, this.label, {required this.required});

  final String wire;
  final String label;

  /// When a required document expires, the chofer is forced offline.
  final bool required;

  static DriverDocumentType fromWire(String? wire) =>
      _resolve(DriverDocumentType.values, wire, (v) => v.wire, DriverDocumentType.unknown);
}

enum DocumentReviewState {
  pending('pending', 'Pendiente'),
  verified('verified', 'Verificado'),
  rejected('rejected', 'Rechazado'),
  expired('expired', 'Vencido'),
  unknown('unknown', 'Desconocido');

  const DocumentReviewState(this.wire, this.label);

  final String wire;
  final String label;

  static DocumentReviewState fromWire(String? wire) =>
      _resolve(DocumentReviewState.values, wire, (v) => v.wire, DocumentReviewState.unknown);
}

// ---------------------------------------------------------------------------
// Service lifecycle
// ---------------------------------------------------------------------------

/// The eleven service states. Transitions are enforced server-side; this enum
/// exists so the apps can render the right screen, never to decide a change.
enum ServiceStatus {
  /// Created and looking for a chofer.
  pendingDispatch('pending_dispatch', 'Buscando grúa'),

  /// One chofer is holding an exclusive 25-second offer.
  offered('offered', 'Buscando grúa'),

  /// A chofer took it and is on the way.
  accepted('accepted', 'Grúa en camino'),

  /// The chofer pressed "Llegué".
  arrived('arrived', 'Tu grúa llegó'),

  /// Vehicle loaded, heading to the destination.
  inProgress('in_progress', 'En camino al destino'),

  /// The chofer pressed "Finalizar". Payment may still be settling.
  completed('completed', 'Servicio completado'),

  /// Paid and invoiced. Terminal.
  closed('closed', 'Servicio cerrado'),

  /// The cascade gave up; a dispatcher must assign by hand.
  needsManual('needs_manual', 'Asignando grúa'),

  /// Cancelled by client, chofer, admin or the system. Terminal.
  cancelled('cancelled', 'Servicio cancelado'),

  /// Nobody was ever assigned within the dispatch window. Terminal.
  expired('expired', 'Servicio expirado'),

  /// Something went wrong that needs a human. Terminal.
  failed('failed', 'Servicio con problema'),

  unknown('unknown', 'Estado desconocido');

  const ServiceStatus(this.wire, this.label);

  final String wire;

  /// Customer-facing es-DO label. Note that `offered` deliberately reads the
  /// same as `pending_dispatch`: the client should not see the cascade churn.
  final String label;

  static ServiceStatus fromWire(String? wire) =>
      _resolve(ServiceStatus.values, wire, (v) => v.wire, ServiceStatus.unknown);

  static const Set<ServiceStatus> terminal = {
    ServiceStatus.closed,
    ServiceStatus.cancelled,
    ServiceStatus.expired,
    ServiceStatus.failed,
  };

  /// States in which a client is considered to have a service in flight and
  /// may not request another.
  static const Set<ServiceStatus> active = {
    ServiceStatus.pendingDispatch,
    ServiceStatus.offered,
    ServiceStatus.accepted,
    ServiceStatus.arrived,
    ServiceStatus.inProgress,
    ServiceStatus.completed,
    ServiceStatus.needsManual,
  };

  /// States where chat and calling between the two parties are open.
  static const Set<ServiceStatus> contactOpen = {
    ServiceStatus.accepted,
    ServiceStatus.arrived,
    ServiceStatus.inProgress,
  };

  bool get isTerminal => terminal.contains(this);

  bool get isActive => active.contains(this);

  /// True once a specific chofer owns the job.
  bool get hasDriver => const {
        ServiceStatus.accepted,
        ServiceStatus.arrived,
        ServiceStatus.inProgress,
        ServiceStatus.completed,
        ServiceStatus.closed,
      }.contains(this);

  /// The client may cancel right up until the vehicle is loaded.
  bool get isCancellableByClient => const {
        ServiceStatus.pendingDispatch,
        ServiceStatus.offered,
        ServiceStatus.needsManual,
        ServiceStatus.accepted,
        ServiceStatus.arrived,
      }.contains(this);

  bool get allowsContact => contactOpen.contains(this);
}

/// Names of the server callables that move a service between states. Keeping
/// them here means the apps and the tests cannot drift from the function names.
enum ServiceEventName {
  requestService('requestService'),
  dispatchNext('dispatchNext'),
  acceptService('acceptService'),
  rejectService('rejectService'),
  expireOffer('expireOffer'),
  noDriversFound('noDriversFound'),
  assignServiceManually('assignServiceManually'),
  markArrived('markArrived'),
  startService('startService'),
  completeService('completeService'),
  confirmCashCollected('confirmCashCollected'),
  closeService('closeService'),
  cancelService('cancelService'),
  cancelByDriver('cancelByDriver'),
  failService('failService'),
  unknown('unknown');

  const ServiceEventName(this.wire);

  final String wire;

  static ServiceEventName fromWire(String? wire) =>
      _resolve(ServiceEventName.values, wire, (v) => v.wire, ServiceEventName.unknown);
}

/// State of a single dispatch offer to one chofer.
enum OfferState {
  sent('sent'),
  accepted('accepted'),
  rejected('rejected'),
  expired('expired'),
  cancelled('cancelled'),
  unknown('unknown');

  const OfferState(this.wire);

  final String wire;

  static OfferState fromWire(String? wire) =>
      _resolve(OfferState.values, wire, (v) => v.wire, OfferState.unknown);

  bool get isOpen => this == OfferState.sent;
}

enum AssignmentMode {
  auto('auto', 'Automático'),
  manual('manual', 'Manual'),
  unknown('unknown', 'Desconocido');

  const AssignmentMode(this.wire, this.label);

  final String wire;
  final String label;

  static AssignmentMode fromWire(String? wire) =>
      _resolve(AssignmentMode.values, wire, (v) => v.wire, AssignmentMode.unknown);
}

enum CancelledBy {
  client('client', 'Cliente'),
  driver('driver', 'Chofer'),
  admin('admin', 'Administración'),
  system('system', 'Sistema'),
  unknown('unknown', 'Desconocido');

  const CancelledBy(this.wire, this.label);

  final String wire;
  final String label;

  static CancelledBy fromWire(String? wire) =>
      _resolve(CancelledBy.values, wire, (v) => v.wire, CancelledBy.unknown);
}

/// Fixed reasons a chofer may give for dropping a job. Free text is not
/// accepted because these feed the admin's abuse flags.
enum DriverCancelReason {
  vehicleBreakdown('vehicle_breakdown', 'Avería de la grúa'),
  wrongTruckType('wrong_truck_type', 'Tipo de grúa incorrecto'),
  clientNotPresent('client_not_present', 'El cliente no está en el lugar'),
  clientRefused('client_refused', 'El cliente rechazó el servicio'),
  inaccessibleLocation('inaccessible_location', 'No puedo llegar al lugar'),
  unsafeLocation('unsafe_location', 'Lugar inseguro'),
  emergency('emergency', 'Emergencia personal'),
  other('other', 'Otro motivo'),
  unknown('unknown', 'Desconocido');

  const DriverCancelReason(this.wire, this.label);

  final String wire;
  final String label;

  static DriverCancelReason fromWire(String? wire) =>
      _resolve(DriverCancelReason.values, wire, (v) => v.wire, DriverCancelReason.unknown);
}

// ---------------------------------------------------------------------------
// Money
// ---------------------------------------------------------------------------

enum PaymentMethod {
  card('card', 'Tarjeta'),
  cash('cash', 'Efectivo'),
  unknown('unknown', 'Desconocido');

  const PaymentMethod(this.wire, this.label);

  final String wire;
  final String label;

  static PaymentMethod fromWire(String? wire) =>
      _resolve(PaymentMethod.values, wire, (v) => v.wire, PaymentMethod.unknown);
}

enum PaymentStatus {
  /// Cash job, or a card job before the hold is placed.
  none('none', 'Sin procesar'),

  /// Card hold placed at accept time.
  authorized('authorized', 'Autorizado'),

  /// Hold captured at completion.
  captured('captured', 'Cobrado'),

  /// Authorization or capture was declined.
  failed('failed', 'Rechazado'),

  refunded('refunded', 'Reembolsado'),

  /// Completed cash job, chofer has not confirmed collection yet.
  cashPending('cash_pending', 'Cobro en efectivo pendiente'),

  cashCollected('cash_collected', 'Efectivo recibido'),

  unknown('unknown', 'Desconocido');

  const PaymentStatus(this.wire, this.label);

  final String wire;
  final String label;

  static PaymentStatus fromWire(String? wire) =>
      _resolve(PaymentStatus.values, wire, (v) => v.wire, PaymentStatus.unknown);

  bool get isSettled =>
      this == PaymentStatus.captured || this == PaymentStatus.cashCollected;

  /// A card service cannot start until the hold is in place.
  bool get blocksServiceStart => this == PaymentStatus.failed || this == PaymentStatus.none;
}

/// Dominican tax receipt types (Números de Comprobante Fiscal).
enum NcfType {
  /// Crédito fiscal — for a customer with an RNC who will deduct the ITBIS.
  creditoFiscal('01', 'Crédito fiscal'),

  /// Consumo — the default for individuals.
  consumo('02', 'Consumo'),

  unknown('unknown', 'Desconocido');

  const NcfType(this.wire, this.label);

  final String wire;
  final String label;

  static NcfType fromWire(String? wire) =>
      _resolve(NcfType.values, wire, (v) => v.wire, NcfType.unknown);
}
