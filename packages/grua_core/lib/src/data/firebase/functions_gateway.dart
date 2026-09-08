import 'dart:async';

// cloud_functions exports its own `Result`, which would shadow the domain one
// this whole layer returns.
import 'package:cloud_functions/cloud_functions.dart' hide Result;

import '../../domain/enums.dart';
import '../../domain/failures.dart';
import '../../domain/models/service.dart';
import '../../domain/repositories.dart';
import '../../domain/value_objects.dart';

/// Calls the Cloud Functions that move a service between states.
///
/// Every method here is a state transition, and every one can be refused. The
/// refusals matter as much as the successes: `failed-precondition` with
/// `ALREADY_TAKEN` and the same status with `OFFER_EXPIRED` are the same HTTP
/// response and completely different news for a chofer, so the server's code
/// is carried through to a [FailureCode] rather than flattened into "error".
class FirebaseFunctionsGateway implements FunctionsGateway {
  FirebaseFunctionsGateway({required String region, FirebaseFunctions? functions})
      : _functions =
            functions ?? FirebaseFunctions.instanceFor(region: region);

  final FirebaseFunctions _functions;

  /// Long enough for a cold start on a function that calls the Routes API,
  /// short enough that a stranded customer is not left watching a spinner.
  static const _timeout = Duration(seconds: 30);

  Future<Result<T>> _call<T>(
    String name,
    Map<String, dynamic> payload,
    T Function(Map<String, dynamic> data) parse,
  ) async {
    try {
      final result = await _functions
          .httpsCallable(name, options: HttpsCallableOptions(timeout: _timeout))
          .call<Object?>(payload);

      final data = result.data;
      return Result.ok(parse(data is Map ? Map<String, dynamic>.from(data) : {}));
    } on FirebaseFunctionsException catch (error) {
      return Result.err(_mapCallableError(error));
    } on TimeoutException {
      return const Result.err(Failure(FailureCode.timeout));
    } on Object catch (error) {
      return Result.err(Failure(FailureCode.unknown, cause: error));
    }
  }

  Future<Result<void>> _callVoid(String name, Map<String, dynamic> payload) =>
      _call<void>(name, payload, (_) {});

  /// Turns a callable's status and details into a domain failure.
  ///
  /// The server puts a machine-readable code in `details.code`; the message it
  /// sends alongside is already written for a Dominican user, so it is used
  /// verbatim when present rather than replaced with a generic one.
  Failure _mapCallableError(FirebaseFunctionsException error) {
    final details = error.details;
    final code = details is Map ? details['code'] as String? : null;
    final serverMessage = error.message;

    // A recognised business code always wins: it is more specific than the
    // transport status that carried it.
    final mapped = FailureCode.fromWire(code);
    if (mapped != FailureCode.unknown) {
      return Failure(
        mapped,
        // Only override the built-in copy when the server actually said
        // something more specific, such as the distance in an OUT_OF_RANGE.
        message: (serverMessage != null && serverMessage.contains(' '))
            ? serverMessage
            : null,
        details: details is Map ? details['data'] : null,
      );
    }

    return switch (error.code) {
      'unauthenticated' => const Failure(FailureCode.unauthenticated),
      'permission-denied' => const Failure(FailureCode.permissionDenied),
      'not-found' => const Failure(FailureCode.notFound),
      'invalid-argument' => Failure(
          FailureCode.invalidInput,
          message: serverMessage,
        ),
      'failed-precondition' => Failure(
          FailureCode.invalidTransition,
          message: serverMessage,
        ),
      'resource-exhausted' => const Failure(
          FailureCode.unknown,
          message: 'Demasiadas solicitudes. Espera un momento.',
        ),
      'deadline-exceeded' => const Failure(FailureCode.timeout),
      'unavailable' => const Failure(FailureCode.network),
      _ => Failure(FailureCode.unknown, cause: error),
    };
  }

  // -------------------------------------------------------------------------
  // Client
  // -------------------------------------------------------------------------

  @override
  Future<Result<QuoteResult>> quoteService({
    required ServiceLocation pickup,
    required ServiceLocation dropoff,
    required ServiceVehicle vehicle,
    TruckType? truckTypeOverride,
  }) =>
      _call('quoteService', {
        'pickup': pickup.toJson(),
        'dropoff': dropoff.toJson(),
        'vehicle': vehicle.toJson(),
        if (truckTypeOverride != null)
          'truckTypeOverride': truckTypeOverride.wire,
      }, (data) {
        return QuoteResult(
          quote: Quote.fromJson(
            Map<String, dynamic>.from(data['quote'] as Map? ?? {}),
          ),
          route: ServiceRoute.fromJson(
            Map<String, dynamic>.from(data['route'] as Map? ?? {}),
          ),
          expiresAt: DateTime.tryParse(data['expiresAt'] as String? ?? '')
                  ?.toUtc() ??
              DateTime.now().toUtc(),
          // The HMAC the server recomputes on requestService. Opaque here on
          // purpose — the app must not be able to construct one.
          signature: data['signature'] as String? ?? '',
          truckType: TruckType.fromWire(data['truckType'] as String?),
        );
      });

  @override
  Future<Result<String>> requestService({
    required ServiceLocation pickup,
    required ServiceLocation dropoff,
    required ServiceVehicle vehicle,
    required TruckType truckType,
    required PaymentMethod paymentMethod,
    required String quoteSignature,
    String? paymentMethodId,
    String? notes,
  }) =>
      _call('requestService', {
        'pickup': pickup.toJson(),
        'dropoff': dropoff.toJson(),
        'vehicle': vehicle.toJson(),
        'truckType': truckType.wire,
        'paymentMethod': paymentMethod.wire,
        'quoteSignature': quoteSignature,
        'paymentMethodId': ?paymentMethodId,
        'notes': ?notes,
      }, (data) => data['serviceId'] as String? ?? '');

  @override
  Future<Result<void>> cancelService({
    required String serviceId,
    required String reason,
  }) =>
      _callVoid('cancelService', {'serviceId': serviceId, 'reason': reason});

  @override
  Future<Result<void>> rateService({
    required String serviceId,
    required int stars,
    String? comment,
  }) =>
      _callVoid('rateService', {
        'serviceId': serviceId,
        'stars': stars,
        'comment': ?comment,
      });

  // -------------------------------------------------------------------------
  // Driver
  // -------------------------------------------------------------------------

  @override
  Future<Result<void>> acceptService(String serviceId) =>
      _callVoid('acceptService', {'serviceId': serviceId});

  @override
  Future<Result<void>> rejectService(
    String serviceId, {
    DriverCancelReason? reason,
  }) =>
      _callVoid('rejectService', {
        'serviceId': serviceId,
        if (reason != null) 'reason': reason.wire,
      });

  @override
  Future<Result<void>> markArrived({
    required String serviceId,
    required LatLng position,
  }) =>
      _callVoid('markArrived', {
        'serviceId': serviceId,
        'lat': position.latitude,
        'lng': position.longitude,
      });

  @override
  Future<Result<void>> startService({
    required String serviceId,
    required List<String> photoPaths,
  }) =>
      _callVoid('startService', {
        'serviceId': serviceId,
        'photoPaths': photoPaths,
      });

  @override
  Future<Result<void>> completeService({
    required String serviceId,
    required LatLng position,
    required List<String> photoPaths,
    String? notes,
  }) =>
      _callVoid('completeService', {
        'serviceId': serviceId,
        'lat': position.latitude,
        'lng': position.longitude,
        'photoPaths': photoPaths,
        'notes': ?notes,
      });

  @override
  Future<Result<void>> confirmCashCollected({
    required String serviceId,
    required int amountCents,
    String? discrepancyReason,
  }) =>
      _callVoid('confirmCashCollected', {
        'serviceId': serviceId,
        'amountCents': amountCents,
        'discrepancyReason': ?discrepancyReason,
      });

  @override
  Future<Result<void>> cancelByDriver({
    required String serviceId,
    required DriverCancelReason reason,
  }) =>
      _callVoid('cancelByDriver', {
        'serviceId': serviceId,
        'reason': reason.wire,
      });

  @override
  Future<Result<void>> publishEta({
    required String serviceId,
    required int etaSeconds,
    required int remainingMeters,
  }) =>
      _callVoid('publishEta', {
        'serviceId': serviceId,
        'etaSeconds': etaSeconds,
        'remainingMeters': remainingMeters,
      });

  @override
  Future<Result<String>> invoiceDownloadUrl(String invoiceId) =>
      _call('getInvoiceUrl', {'invoiceId': invoiceId},
          (data) => data['url'] as String? ?? '');
}
