import 'package:flutter/foundation.dart';

/// Machine-readable failure codes.
///
/// Cloud Functions throw `failed-precondition` with one of these in the
/// message details, and the apps map each to its own screen state. That
/// distinction matters: "Otro chofer tomó el servicio" and "La oferta expiró"
/// are the same HTTP status and completely different news for the chofer.
enum FailureCode {
  // Transport / auth
  network('network'),
  timeout('timeout'),
  unauthenticated('unauthenticated'),
  permissionDenied('permission_denied'),
  appCheckFailed('app_check_failed'),
  notFound('not_found'),

  // Request flow
  outsideCoverage('outside_coverage'),
  quoteExpired('quote_expired'),
  quoteMismatch('quote_mismatch'),
  alreadyHasActiveService('already_has_active_service'),
  invalidInput('invalid_input'),

  // Dispatch
  offerExpired('OFFER_EXPIRED'),
  alreadyTaken('ALREADY_TAKEN'),
  driverBusy('DRIVER_BUSY'),
  driverInactive('DRIVER_INACTIVE'),
  noDriversAvailable('no_drivers_available'),

  // Chat requests
  chatRequestUnavailable('chat_request_unavailable'),
  chatRequestExpired('chat_request_expired'),

  // Service transitions
  outOfRange('OUT_OF_RANGE'),
  blockedPayment('BLOCKED_PAYMENT'),
  invalidTransition('invalid_transition'),
  photosRequired('photos_required'),

  // Money
  paymentDeclined('payment_declined'),
  paymentRequiresAction('payment_requires_action'),
  cashLimitExceeded('cash_limit_exceeded'),
  paymentsNotConfigured('payments_not_configured'),

  // Account
  accountBlocked('account_blocked'),
  accountSuspended('account_suspended'),
  documentsExpired('documents_expired'),
  wrongRole('wrong_role'),

  maintenance('maintenance'),
  updateRequired('update_required'),
  unknown('unknown');

  const FailureCode(this.wire);

  final String wire;

  static FailureCode fromWire(String? wire) {
    if (wire == null) return FailureCode.unknown;
    for (final code in FailureCode.values) {
      if (code.wire == wire) return code;
    }
    return FailureCode.unknown;
  }
}

/// A failure with a message already written for a Dominican user.
///
/// Error copy lives here rather than at each call site so the same condition
/// reads identically in all three apps, and so a translator has one file to
/// work from.
@immutable
class Failure implements Exception {
  const Failure(this.code, {this.message, this.details, this.cause});

  factory Failure.fromCode(FailureCode code, {Object? details}) =>
      Failure(code, details: details);

  final FailureCode code;

  /// Overrides [userMessage] when the server sent something more specific.
  final String? message;
  final Object? details;
  final Object? cause;

  bool get isRetryable => const {
        FailureCode.network,
        FailureCode.timeout,
        FailureCode.unknown,
      }.contains(code);

  /// What the user actually reads. Every string says what went wrong and, where
  /// there is one, what to do about it.
  String get userMessage {
    final override = message;
    if (override != null && override.isNotEmpty) return override;
    return switch (code) {
      FailureCode.network =>
        'Sin conexión. Revisa tus datos móviles o el WiFi e intenta de nuevo.',
      FailureCode.timeout => 'La conexión tardó demasiado. Intenta de nuevo.',
      FailureCode.unauthenticated => 'Tu sesión expiró. Inicia sesión de nuevo.',
      FailureCode.permissionDenied => 'No tienes permiso para hacer esto.',
      FailureCode.appCheckFailed =>
        'No pudimos verificar la app. Actualízala desde la tienda.',
      FailureCode.notFound => 'No encontramos lo que buscas.',
      FailureCode.outsideCoverage =>
        'Todavía no damos servicio en esa zona. Llámanos y te ayudamos.',
      FailureCode.quoteExpired =>
        'El precio venció. Vamos a calcularlo de nuevo.',
      FailureCode.quoteMismatch =>
        'El precio cambió. Revisa el nuevo total antes de continuar.',
      FailureCode.alreadyHasActiveService =>
        'Ya tienes un servicio en curso.',
      FailureCode.invalidInput => 'Revisa los datos e intenta de nuevo.',
      FailureCode.offerExpired => 'La oferta expiró.',
      FailureCode.alreadyTaken => 'Otro chofer tomó el servicio.',
      FailureCode.driverBusy => 'Ya tienes un servicio asignado.',
      FailureCode.driverInactive =>
        'Tu cuenta no está activa. Comunícate con la oficina.',
      FailureCode.noDriversAvailable =>
        'No hay grúas disponibles ahora mismo. Ya estamos buscando una para ti.',
      FailureCode.chatRequestUnavailable =>
        'Este chofer no puede chatear ahora. Prueba con otra grúa.',
      FailureCode.chatRequestExpired =>
        'Esta solicitud de chat ya venció o fue respondida.',
      FailureCode.outOfRange =>
        'Estás muy lejos del punto. Acércate e intenta de nuevo.',
      FailureCode.blockedPayment =>
        'El pago no está autorizado todavía. Pídele al cliente que lo corrija o cambia a efectivo.',
      FailureCode.invalidTransition =>
        'Ese paso ya no aplica. Actualiza la pantalla.',
      FailureCode.photosRequired => 'Debes tomar las fotos antes de continuar.',
      FailureCode.paymentDeclined =>
        'La tarjeta fue rechazada. Usa otra tarjeta o paga en efectivo.',
      FailureCode.paymentRequiresAction =>
        'Tu banco pide confirmar el pago. Sigue los pasos en pantalla.',
      FailureCode.cashLimitExceeded =>
        'Tienes mucho efectivo pendiente de entregar. Liquida para seguir recibiendo servicios en efectivo.',
      FailureCode.paymentsNotConfigured =>
        'El pago con tarjeta no está disponible ahora. Puedes pagar en efectivo.',
      FailureCode.accountBlocked =>
        'Tu cuenta está bloqueada. Comunícate con soporte.',
      FailureCode.accountSuspended =>
        'Tu cuenta está suspendida. Comunícate con la oficina.',
      FailureCode.documentsExpired =>
        'Tienes documentos vencidos. Actualízalos para poder trabajar.',
      FailureCode.wrongRole => 'Esta cuenta no es de chofer.',
      FailureCode.maintenance =>
        'Estamos en mantenimiento. Vuelve en unos minutos.',
      FailureCode.updateRequired =>
        'Necesitas actualizar la app para continuar.',
      FailureCode.unknown =>
        'Algo salió mal. Intenta de nuevo o llámanos si sigue pasando.',
    };
  }

  @override
  String toString() => 'Failure(${code.wire}: $userMessage)';
}

/// A success-or-failure return value.
///
/// Callables return this instead of throwing so a caller cannot forget to
/// handle the error path — the only way to read the value is to handle both
/// branches.
sealed class Result<T> {
  const Result();

  const factory Result.ok(T value) = Ok<T>;

  const factory Result.err(Failure failure) = Err<T>;

  bool get isOk => this is Ok<T>;

  bool get isErr => this is Err<T>;

  T? get valueOrNull => switch (this) {
        Ok<T>(:final value) => value,
        Err<T>() => null,
      };

  Failure? get failureOrNull => switch (this) {
        Ok<T>() => null,
        Err<T>(:final failure) => failure,
      };

  R fold<R>(R Function(T value) onOk, R Function(Failure failure) onErr) =>
      switch (this) {
        Ok<T>(:final value) => onOk(value),
        Err<T>(:final failure) => onErr(failure),
      };

  Result<R> map<R>(R Function(T value) transform) => switch (this) {
        Ok<T>(:final value) => Ok<R>(transform(value)),
        Err<T>(:final failure) => Err<R>(failure),
      };
}

final class Ok<T> extends Result<T> {
  const Ok(this.value);

  final T value;
}

final class Err<T> extends Result<T> {
  const Err(this.failure);

  final Failure failure;
}
