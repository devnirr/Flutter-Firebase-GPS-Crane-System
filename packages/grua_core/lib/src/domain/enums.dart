/// Domain enumerations shared by the three apps and mirrored in
/// `functions/src/lib/enums.ts`.
///
/// Every enum here follows the same contract: a `wire` string that is the only
/// thing ever written to Firestore, and a tolerant `fromWire` that resolves an
/// unrecognised value to an `unknown` member instead of throwing. That matters
/// because an app on a customer's phone can be months behind the backend, and a
/// chofer whose app crashes on a new status is a chofer who cannot work.
library;

import 'package:json_annotation/json_annotation.dart';

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
  @JsonValue('client')
  client('client'),
  @JsonValue('driver')
  driver('driver'),
  @JsonValue('admin')
  admin('admin'),
  @JsonValue('ops')
  ops('ops'),
  @JsonValue('unknown')
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
  @JsonValue('inactive')
  inactive('inactive'),

  /// Cleared to go online and receive offers.
  @JsonValue('active')
  active('active'),

  /// Blocked by an admin. Cannot log in to work.
  @JsonValue('suspended')
  suspended('suspended'),

  @JsonValue('unknown')
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
  @JsonValue('idle')
  idle('idle'),

  /// Online but already committed to a service.
  @JsonValue('on_service')
  onService('on_service'),

  @JsonValue('unknown')
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
  @JsonValue('plataforma')
  plataforma('plataforma', 'Plataforma'),

  /// Hook and chain / wheel-lift. The everyday tow.
  @JsonValue('gancho')
  gancho('gancho', 'Gancho'),

  /// Heavy recovery for trucks and buses.
  @JsonValue('pesada')
  pesada('pesada', 'Grúa pesada'),

  @JsonValue('unknown')
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
  @JsonValue('sedan')
  sedan('sedan', 'Carro / Sedán'),
  @JsonValue('suv')
  suv('suv', 'Jeepeta / SUV'),
  @JsonValue('camioneta')
  camioneta('camioneta', 'Camioneta'),
  @JsonValue('camion')
  camion('camion', 'Camión / Autobús'),
  @JsonValue('motor')
  motor('motor', 'Motor'),
  @JsonValue('unknown')
  unknown('unknown', 'Otro');

  const VehicleType(this.wire, this.label);

  final String wire;
  final String label;

  static VehicleType fromWire(String? wire) =>
      _resolve(VehicleType.values, wire, (v) => v.wire, VehicleType.unknown);
}

/// Why the vehicle needs a grúa. Drives both pricing and truck-type inference.
enum VehicleCondition {
  @JsonValue('no_arranca')
  noArranca('no_arranca', 'No arranca'),
  @JsonValue('accidentado')
  accidentado('accidentado', 'Accidentado'),
  @JsonValue('ruedas_bloqueadas')
  ruedasBloqueadas('ruedas_bloqueadas', 'Ruedas bloqueadas'),
  @JsonValue('volcado')
  volcado('volcado', 'Volcado'),
  @JsonValue('sin_combustible')
  sinCombustible('sin_combustible', 'Sin combustible'),
  @JsonValue('goma_pinchada')
  gomaPinchada('goma_pinchada', 'Goma pinchada'),
  @JsonValue('unknown')
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
  @JsonValue('licencia')
  licencia('licencia', 'Licencia de conducir', required: true),
  @JsonValue('cedula')
  cedula('cedula', 'Cédula', required: true),
  @JsonValue('seguro')
  seguro('seguro', 'Seguro del vehículo', required: true),
  @JsonValue('marbete')
  marbete('marbete', 'Marbete', required: true),
  @JsonValue('matricula')
  matricula('matricula', 'Matrícula', required: true),
  @JsonValue('certificado_medico')
  certificadoMedico('certificado_medico', 'Certificado médico', required: false),
  @JsonValue('unknown')
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
  @JsonValue('pending')
  pending('pending', 'Pendiente'),
  @JsonValue('verified')
  verified('verified', 'Verificado'),
  @JsonValue('rejected')
  rejected('rejected', 'Rechazado'),
  @JsonValue('expired')
  expired('expired', 'Vencido'),
  @JsonValue('unknown')
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
  @JsonValue('pending_dispatch')
  pendingDispatch('pending_dispatch', 'Buscando grúa'),

  /// One chofer is holding an exclusive 25-second offer.
  @JsonValue('offered')
  offered('offered', 'Buscando grúa'),

  /// A chofer took it and is on the way.
  @JsonValue('accepted')
  accepted('accepted', 'Grúa en camino'),

  /// The chofer pressed "Llegué".
  @JsonValue('arrived')
  arrived('arrived', 'Tu grúa llegó'),

  /// Vehicle loaded, heading to the destination.
  @JsonValue('in_progress')
  inProgress('in_progress', 'En camino al destino'),

  /// The chofer pressed "Finalizar". Payment may still be settling.
  @JsonValue('completed')
  completed('completed', 'Servicio completado'),

  /// Paid and invoiced. Terminal.
  @JsonValue('closed')
  closed('closed', 'Servicio cerrado'),

  /// The cascade gave up; a dispatcher must assign by hand.
  @JsonValue('needs_manual')
  needsManual('needs_manual', 'Asignando grúa'),

  /// Cancelled by client, chofer, admin or the system. Terminal.
  @JsonValue('cancelled')
  cancelled('cancelled', 'Servicio cancelado'),

  /// Nobody was ever assigned within the dispatch window. Terminal.
  @JsonValue('expired')
  expired('expired', 'Servicio expirado'),

  /// Something went wrong that needs a human. Terminal.
  @JsonValue('failed')
  failed('failed', 'Servicio con problema'),

  @JsonValue('unknown')
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

  /// The office's name for the state. [label] is written for the customer —
  /// "Tu grúa llegó", and `offered` hidden behind "Buscando grúa" — which is
  /// the wrong voice for a dispatcher reading a list of every job.
  String get officeLabel => switch (this) {
        ServiceStatus.pendingDispatch => 'Buscando chofer',
        ServiceStatus.offered => 'Ofrecido a chofer',
        ServiceStatus.accepted => 'Chofer en camino',
        ServiceStatus.arrived => 'Chofer en el punto',
        ServiceStatus.inProgress => 'Remolcando',
        ServiceStatus.completed => 'Completado',
        ServiceStatus.closed => 'Cerrado',
        ServiceStatus.needsManual => 'Requiere asignación',
        ServiceStatus.cancelled => 'Cancelado',
        ServiceStatus.expired => 'Expirado',
        ServiceStatus.failed => 'Con problema',
        ServiceStatus.unknown => 'Desconocido',
      };

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
  @JsonValue('requestService')
  requestService('requestService'),
  @JsonValue('dispatchNext')
  dispatchNext('dispatchNext'),
  @JsonValue('acceptService')
  acceptService('acceptService'),
  @JsonValue('rejectService')
  rejectService('rejectService'),
  @JsonValue('expireOffer')
  expireOffer('expireOffer'),
  @JsonValue('noDriversFound')
  noDriversFound('noDriversFound'),
  @JsonValue('assignServiceManually')
  assignServiceManually('assignServiceManually'),
  @JsonValue('markArrived')
  markArrived('markArrived'),
  @JsonValue('startService')
  startService('startService'),
  @JsonValue('completeService')
  completeService('completeService'),
  @JsonValue('confirmCashCollected')
  confirmCashCollected('confirmCashCollected'),
  @JsonValue('closeService')
  closeService('closeService'),
  @JsonValue('cancelService')
  cancelService('cancelService'),
  @JsonValue('cancelByDriver')
  cancelByDriver('cancelByDriver'),
  @JsonValue('failService')
  failService('failService'),
  @JsonValue('unknown')
  unknown('unknown');

  const ServiceEventName(this.wire);

  final String wire;

  static ServiceEventName fromWire(String? wire) =>
      _resolve(ServiceEventName.values, wire, (v) => v.wire, ServiceEventName.unknown);
}

/// State of a single dispatch offer to one chofer.
enum OfferState {
  @JsonValue('sent')
  sent('sent'),
  @JsonValue('accepted')
  accepted('accepted'),
  @JsonValue('rejected')
  rejected('rejected'),
  @JsonValue('expired')
  expired('expired'),
  @JsonValue('cancelled')
  cancelled('cancelled'),
  @JsonValue('unknown')
  unknown('unknown');

  const OfferState(this.wire);

  final String wire;

  static OfferState fromWire(String? wire) =>
      _resolve(OfferState.values, wire, (v) => v.wire, OfferState.unknown);

  bool get isOpen => this == OfferState.sent;
}

enum AssignmentMode {
  @JsonValue('auto')
  auto('auto', 'Automático'),
  @JsonValue('manual')
  manual('manual', 'Manual'),
  @JsonValue('unknown')
  unknown('unknown', 'Desconocido');

  const AssignmentMode(this.wire, this.label);

  final String wire;
  final String label;

  static AssignmentMode fromWire(String? wire) =>
      _resolve(AssignmentMode.values, wire, (v) => v.wire, AssignmentMode.unknown);
}

enum CancelledBy {
  @JsonValue('client')
  client('client', 'Cliente'),
  @JsonValue('driver')
  driver('driver', 'Chofer'),
  @JsonValue('admin')
  admin('admin', 'Administración'),
  @JsonValue('system')
  system('system', 'Sistema'),
  @JsonValue('unknown')
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
  @JsonValue('vehicle_breakdown')
  vehicleBreakdown('vehicle_breakdown', 'Avería de la grúa'),
  @JsonValue('wrong_truck_type')
  wrongTruckType('wrong_truck_type', 'Tipo de grúa incorrecto'),
  @JsonValue('client_not_present')
  clientNotPresent('client_not_present', 'El cliente no está en el lugar'),
  @JsonValue('client_refused')
  clientRefused('client_refused', 'El cliente rechazó el servicio'),
  @JsonValue('inaccessible_location')
  inaccessibleLocation('inaccessible_location', 'No puedo llegar al lugar'),
  @JsonValue('unsafe_location')
  unsafeLocation('unsafe_location', 'Lugar inseguro'),
  @JsonValue('emergency')
  emergency('emergency', 'Emergencia personal'),
  @JsonValue('other')
  other('other', 'Otro motivo'),
  @JsonValue('unknown')
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
  @JsonValue('card')
  card('card', 'Tarjeta'),
  @JsonValue('cash')
  cash('cash', 'Efectivo'),
  @JsonValue('unknown')
  unknown('unknown', 'Desconocido');

  const PaymentMethod(this.wire, this.label);

  final String wire;
  final String label;

  static PaymentMethod fromWire(String? wire) =>
      _resolve(PaymentMethod.values, wire, (v) => v.wire, PaymentMethod.unknown);
}

enum PaymentStatus {
  /// Cash job, or a card job before the hold is placed.
  @JsonValue('none')
  none('none', 'Sin procesar'),

  /// Card hold placed at accept time.
  @JsonValue('authorized')
  authorized('authorized', 'Autorizado'),

  /// Hold captured at completion.
  @JsonValue('captured')
  captured('captured', 'Cobrado'),

  /// Authorization or capture was declined.
  @JsonValue('failed')
  failed('failed', 'Rechazado'),

  @JsonValue('refunded')
  refunded('refunded', 'Reembolsado'),

  /// Completed cash job, chofer has not confirmed collection yet.
  @JsonValue('cash_pending')
  cashPending('cash_pending', 'Cobro en efectivo pendiente'),

  @JsonValue('cash_collected')
  cashCollected('cash_collected', 'Efectivo recibido'),

  @JsonValue('unknown')
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
  @JsonValue('01')
  creditoFiscal('01', 'Crédito fiscal'),

  /// Consumo — the default for individuals.
  @JsonValue('02')
  consumo('02', 'Consumo'),

  @JsonValue('unknown')
  unknown('unknown', 'Desconocido');

  const NcfType(this.wire, this.label);

  final String wire;
  final String label;

  static NcfType fromWire(String? wire) =>
      _resolve(NcfType.values, wire, (v) => v.wire, NcfType.unknown);
}
