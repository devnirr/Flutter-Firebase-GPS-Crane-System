import { HttpsError } from 'firebase-functions/v2/https';

/**
 * Machine-readable failure codes, mirrored from
 * `packages/grua_core/lib/src/domain/failures.dart`.
 *
 * The apps switch on these to choose a screen, so the string matters more than
 * the HTTP status. "Otro chofer tomó el servicio" and "La oferta expiró" are
 * both `failed-precondition`, and telling a chofer the wrong one costs them
 * trust in the dispatcher.
 */
export const Code = {
  // Request flow
  outsideCoverage: 'outside_coverage',
  quoteExpired: 'quote_expired',
  quoteMismatch: 'quote_mismatch',
  alreadyHasActiveService: 'already_has_active_service',
  invalidInput: 'invalid_input',

  // Dispatch
  offerExpired: 'OFFER_EXPIRED',
  alreadyTaken: 'ALREADY_TAKEN',
  driverBusy: 'DRIVER_BUSY',
  driverInactive: 'DRIVER_INACTIVE',
  noDriversAvailable: 'no_drivers_available',

  // Chat requests
  chatRequestUnavailable: 'chat_request_unavailable',
  chatRequestExpired: 'chat_request_expired',

  // Transitions
  outOfRange: 'OUT_OF_RANGE',
  blockedPayment: 'BLOCKED_PAYMENT',
  invalidTransition: 'invalid_transition',
  photosRequired: 'photos_required',

  // Money
  paymentDeclined: 'payment_declined',
  cashLimitExceeded: 'cash_limit_exceeded',

  // Account
  accountBlocked: 'account_blocked',
  accountSuspended: 'account_suspended',
  wrongRole: 'wrong_role',
  documentsExpired: 'documents_expired',

  maintenance: 'maintenance',
  notFound: 'not_found',
} as const;

export type Code = (typeof Code)[keyof typeof Code];

/**
 * A `failed-precondition` carrying one of the codes above.
 *
 * `details` rides along so a message can be specific without the app parsing
 * prose — `markArrived` sends the measured distance, so the chofer sees
 * "estás a 1.2 km" rather than a flat refusal.
 */
export function precondition(
  code: Code,
  message: string,
  details?: Record<string, unknown>,
): HttpsError {
  return new HttpsError('failed-precondition', message, { code, ...details });
}

export function invalidArgument(
  message: string,
  details?: Record<string, unknown>,
): HttpsError {
  return new HttpsError('invalid-argument', message, {
    code: Code.invalidInput,
    ...details,
  });
}

export function permissionDenied(message = 'No tienes permiso para hacer esto.'): HttpsError {
  return new HttpsError('permission-denied', message, { code: Code.wrongRole });
}

export function unauthenticated(message = 'Tu sesión expiró. Inicia sesión de nuevo.'): HttpsError {
  return new HttpsError('unauthenticated', message);
}

export function notFound(message = 'No encontramos lo que buscas.'): HttpsError {
  return new HttpsError('not-found', message, { code: Code.notFound });
}

export function internal(message = 'Algo salió mal. Intenta de nuevo.'): HttpsError {
  return new HttpsError('internal', message);
}
