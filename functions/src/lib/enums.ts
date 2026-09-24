/**
 * Wire values, mirrored from `packages/grua_core/lib/src/domain/enums.dart`.
 *
 * These are the strings actually stored in Firestore, so the two files must
 * agree exactly. They are duplicated rather than generated because a codegen
 * step between Dart and TypeScript would be a build dependency for the sake of
 * ~60 string literals — but a change on either side without the other is a
 * silent data bug, so `enums.test.ts` asserts the sets match the Dart source.
 */

export const ServiceStatus = {
  pendingDispatch: 'pending_dispatch',
  offered: 'offered',
  accepted: 'accepted',
  arrived: 'arrived',
  inProgress: 'in_progress',
  completed: 'completed',
  closed: 'closed',
  needsManual: 'needs_manual',
  cancelled: 'cancelled',
  expired: 'expired',
  failed: 'failed',
} as const;

export type ServiceStatus = (typeof ServiceStatus)[keyof typeof ServiceStatus];

/** States in which a customer is considered to have a tow in flight. */
export const ACTIVE_STATUSES: readonly ServiceStatus[] = [
  ServiceStatus.pendingDispatch,
  ServiceStatus.offered,
  ServiceStatus.accepted,
  ServiceStatus.arrived,
  ServiceStatus.inProgress,
  ServiceStatus.completed,
  ServiceStatus.needsManual,
];

export const TERMINAL_STATUSES: readonly ServiceStatus[] = [
  ServiceStatus.closed,
  ServiceStatus.cancelled,
  ServiceStatus.expired,
  ServiceStatus.failed,
];

/** States where chat and calling between the two parties are open. */
export const CONTACT_OPEN_STATUSES: readonly ServiceStatus[] = [
  ServiceStatus.accepted,
  ServiceStatus.arrived,
  ServiceStatus.inProgress,
];

export const ServiceEventName = {
  requestService: 'requestService',
  dispatchNext: 'dispatchNext',
  acceptService: 'acceptService',
  rejectService: 'rejectService',
  expireOffer: 'expireOffer',
  noDriversFound: 'noDriversFound',
  assignServiceManually: 'assignServiceManually',
  confirmHeavyService: 'confirmHeavyService',
  markArrived: 'markArrived',
  startService: 'startService',
  completeService: 'completeService',
  confirmCashCollected: 'confirmCashCollected',
  closeService: 'closeService',
  cancelService: 'cancelService',
  cancelByDriver: 'cancelByDriver',
  failService: 'failService',

  // Money, logged beside the transitions. None of these move the status.
  choosePaymentMethod: 'choosePaymentMethod',
  paymentAuthorized: 'paymentAuthorized',
  paymentCaptured: 'paymentCaptured',
  paymentFailed: 'paymentFailed',
  paymentVoided: 'paymentVoided',
} as const;

export type ServiceEventName =
  (typeof ServiceEventName)[keyof typeof ServiceEventName];

export const UserRole = {
  client: 'client',
  driver: 'driver',
  admin: 'admin',
  ops: 'ops',
  /** A person working for an insurance company that is billed monthly. */
  insurer: 'insurer',
} as const;

export type UserRole = (typeof UserRole)[keyof typeof UserRole];

/**
 * What a person can do inside their insurance company.
 *
 * Both create and follow tows. Only a manager adds or removes the company's
 * people, and only a manager sees its invoices.
 */
export const InsurerRole = {
  manager: 'manager',
  operator: 'operator',
} as const;

export type InsurerRole = (typeof InsurerRole)[keyof typeof InsurerRole];

/** Whether an insurance company may use the platform at all. */
export const InsurerStatus = {
  active: 'active',
  suspended: 'suspended',
} as const;

export type InsurerStatus = (typeof InsurerStatus)[keyof typeof InsurerStatus];

export const DriverStatus = {
  inactive: 'inactive',
  active: 'active',
  suspended: 'suspended',
} as const;

export type DriverStatus = (typeof DriverStatus)[keyof typeof DriverStatus];

/** Paperwork a chofer must keep current. Mirrors `DriverDocumentType` in Dart. */
export const DriverDocumentType = {
  licencia: 'licencia',
  licenciaReverso: 'licencia_reverso',
  cedula: 'cedula',
  seguro: 'seguro',
  marbete: 'marbete',
  matricula: 'matricula',
  certificadoMedico: 'certificado_medico',
} as const;

export type DriverDocumentType =
  (typeof DriverDocumentType)[keyof typeof DriverDocumentType];

export const DocumentReviewState = {
  pending: 'pending',
  verified: 'verified',
  rejected: 'rejected',
  expired: 'expired',
} as const;

export type DocumentReviewState =
  (typeof DocumentReviewState)[keyof typeof DocumentReviewState];

/**
 * Where a self-registered chofer's licence check stands. Mirrors
 * `LicenseVerificationState` in Dart. Choferes the office opened never get
 * one: the office saw their papers in person.
 */
export const LicenseVerificationState = {
  /** Registered; the two photos have not been submitted for checking yet. */
  awaitingDocuments: 'awaiting_documents',
  processing: 'processing',
  /** Passed every check. The account still waits for an admin to activate it. */
  verified: 'verified',
  /** Failed a check the chofer can fix with new photos. */
  rejected: 'rejected',
  /** Needs a person: an unclear result, a suspected edit, or too many tries. */
  manualReview: 'manual_review',
} as const;

export type LicenseVerificationState =
  (typeof LicenseVerificationState)[keyof typeof LicenseVerificationState];

export const DriverLiveState = {
  idle: 'idle',
  onService: 'on_service',
} as const;

export type DriverLiveState =
  (typeof DriverLiveState)[keyof typeof DriverLiveState];

export const TruckType = {
  plataforma: 'plataforma',
  gancho: 'gancho',
  pesada: 'pesada',
} as const;

export type TruckType = (typeof TruckType)[keyof typeof TruckType];

export const VehicleType = {
  /** Carro. */
  sedan: 'sedan',
  /** Jeepeta. */
  suv: 'suv',
  camioneta: 'camioneta',
  /** Camión de 2 ejes. */
  camion: 'camion',
  /** Patana / tráiler. */
  patana: 'patana',
  equipoPesado: 'equipo_pesado',
  motor: 'motor',
} as const;

export type VehicleType = (typeof VehicleType)[keyof typeof VehicleType];

/**
 * Vehículos pesados: a special grúa, a price that is only an estimate, and an
 * operator who confirms both before anybody drives out.
 */
export const HEAVY_VEHICLE_TYPES: readonly VehicleType[] = [
  VehicleType.camion,
  VehicleType.patana,
  VehicleType.equipoPesado,
];

export const isHeavyVehicle = (type: VehicleType | string | undefined): boolean =>
  HEAVY_VEHICLE_TYPES.includes(type as VehicleType);

/** Where a heavy request stands with the operator. */
export const OperatorReviewState = {
  pending: 'pending',
  confirmed: 'confirmed',
} as const;

export type OperatorReviewState =
  (typeof OperatorReviewState)[keyof typeof OperatorReviewState];

export const VehicleCondition = {
  noArranca: 'no_arranca',
  accidentado: 'accidentado',
  ruedasBloqueadas: 'ruedas_bloqueadas',
  volcado: 'volcado',
  sinCombustible: 'sin_combustible',
  gomaPinchada: 'goma_pinchada',
} as const;

export type VehicleCondition =
  (typeof VehicleCondition)[keyof typeof VehicleCondition];

/** Conditions where the vehicle cannot roll on its own wheels. */
export const FLATBED_CONDITIONS: readonly VehicleCondition[] = [
  VehicleCondition.volcado,
  VehicleCondition.accidentado,
  VehicleCondition.ruedasBloqueadas,
];

export const OfferState = {
  sent: 'sent',
  accepted: 'accepted',
  rejected: 'rejected',
  expired: 'expired',
  cancelled: 'cancelled',
} as const;

export type OfferState = (typeof OfferState)[keyof typeof OfferState];

/**
 * How the customer pays. `pending` until they choose, which they do when the
 * chofer arrives: the price can still change on the way (an operator's
 * confirmation, a longer wait), and a card is only held once there is a truck
 * at the curb.
 */
export const PaymentMethod = {
  card: 'card',
  cash: 'cash',
  pending: 'pending',
  /** Nobody pays at the roadside: the insurance company is billed monthly. */
  insurer: 'insurer',
} as const;
export type PaymentMethod = (typeof PaymentMethod)[keyof typeof PaymentMethod];

export const PaymentStatus = {
  none: 'none',
  /** The card is held for the job; nothing charged yet. */
  authorized: 'authorized',
  /** Charged. Shown to everyone as "Pagado". */
  captured: 'captured',
  failed: 'failed',
  refunded: 'refunded',
  /** A hold released without charging: cancelled, or switched to cash. */
  voided: 'voided',
  cashPending: 'cash_pending',
  cashCollected: 'cash_collected',
  /** An insurer's tow, done, waiting for the month's invoice. */
  toInvoice: 'to_invoice',
  /** An insurer's tow on a monthly invoice, whose id is in `invoiceId`. */
  invoiced: 'invoiced',
} as const;

export type PaymentStatus = (typeof PaymentStatus)[keyof typeof PaymentStatus];

export const AssignmentMode = { auto: 'auto', manual: 'manual' } as const;
export type AssignmentMode =
  (typeof AssignmentMode)[keyof typeof AssignmentMode];

export const CancelledBy = {
  client: 'client',
  /** A person of the insurance company that ordered the tow. */
  insurer: 'insurer',
  driver: 'driver',
  admin: 'admin',
  system: 'system',
} as const;

export type CancelledBy = (typeof CancelledBy)[keyof typeof CancelledBy];

export const DriverCancelReason = {
  vehicleBreakdown: 'vehicle_breakdown',
  wrongTruckType: 'wrong_truck_type',
  clientNotPresent: 'client_not_present',
  clientRefused: 'client_refused',
  inaccessibleLocation: 'inaccessible_location',
  unsafeLocation: 'unsafe_location',
  emergency: 'emergency',
  other: 'other',
} as const;

export type DriverCancelReason =
  (typeof DriverCancelReason)[keyof typeof DriverCancelReason];

export const NcfType = { creditoFiscal: '01', consumo: '02' } as const;
export type NcfType = (typeof NcfType)[keyof typeof NcfType];

/**
 * The truck type a vehicle needs.
 *
 * Ported from `ServiceVehicle.inferredTruckType`. The app runs the same rule to
 * show a price before the customer commits, but this is the authority — a
 * modified client claiming a `gancho` tow for a rolled-over car would otherwise
 * get the cheap rate and a truck that cannot lift it.
 */
export function inferTruckType(
  vehicleType: VehicleType,
  condition: VehicleCondition,
): TruckType {
  // First, whatever the condition: a flatbed cannot lift a camión, let alone a
  // patana or a loader, rolled over or not.
  if (isHeavyVehicle(vehicleType)) return TruckType.pesada;
  if (FLATBED_CONDITIONS.includes(condition)) return TruckType.plataforma;
  return TruckType.gancho;
}

/**
 * Which trucks can actually do a job that asks for `required`, best first.
 *
 * Dispatch used to demand an exact match, and that is not how a yard works. A
 * plataforma carries the whole vehicle, so it can do anything a gancho can —
 * refusing it meant a customer with a car that would not start watched
 * "Buscando grúa" for six minutes while an idle flatbed sat two streets away,
 * and the job ended up on a dispatcher's desk as `needs_manual`.
 *
 * Not the other way round: a gancho tows on the vehicle's own wheels, which is
 * exactly what a flipped or wheel-locked car cannot do. And a pesada is for
 * trucks and buses; nothing substitutes for it and it substitutes for nothing,
 * because sending a heavy wrecker to a sedan is the wrong truck at the wrong
 * price.
 */
export function trucksThatCanServe(required: TruckType): readonly TruckType[] {
  switch (required) {
    case TruckType.gancho:
      return [TruckType.gancho, TruckType.plataforma];
    case TruckType.plataforma:
      return [TruckType.plataforma];
    default:
      return [required];
  }
}
