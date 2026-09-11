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
  markArrived: 'markArrived',
  startService: 'startService',
  completeService: 'completeService',
  confirmCashCollected: 'confirmCashCollected',
  closeService: 'closeService',
  cancelService: 'cancelService',
  cancelByDriver: 'cancelByDriver',
  failService: 'failService',
} as const;

export type ServiceEventName =
  (typeof ServiceEventName)[keyof typeof ServiceEventName];

export const UserRole = {
  client: 'client',
  driver: 'driver',
  admin: 'admin',
  ops: 'ops',
} as const;

export type UserRole = (typeof UserRole)[keyof typeof UserRole];

export const DriverStatus = {
  inactive: 'inactive',
  active: 'active',
  suspended: 'suspended',
} as const;

export type DriverStatus = (typeof DriverStatus)[keyof typeof DriverStatus];

/** Paperwork a chofer must keep current. Mirrors `DriverDocumentType` in Dart. */
export const DriverDocumentType = {
  licencia: 'licencia',
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
  sedan: 'sedan',
  suv: 'suv',
  camioneta: 'camioneta',
  camion: 'camion',
  motor: 'motor',
} as const;

export type VehicleType = (typeof VehicleType)[keyof typeof VehicleType];

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

export const PaymentMethod = { card: 'card', cash: 'cash' } as const;
export type PaymentMethod = (typeof PaymentMethod)[keyof typeof PaymentMethod];

export const PaymentStatus = {
  none: 'none',
  authorized: 'authorized',
  captured: 'captured',
  failed: 'failed',
  refunded: 'refunded',
  cashPending: 'cash_pending',
  cashCollected: 'cash_collected',
} as const;

export type PaymentStatus = (typeof PaymentStatus)[keyof typeof PaymentStatus];

export const AssignmentMode = { auto: 'auto', manual: 'manual' } as const;
export type AssignmentMode =
  (typeof AssignmentMode)[keyof typeof AssignmentMode];

export const CancelledBy = {
  client: 'client',
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
  if (FLATBED_CONDITIONS.includes(condition)) return TruckType.plataforma;
  if (vehicleType === VehicleType.camion) return TruckType.pesada;
  return TruckType.gancho;
}
