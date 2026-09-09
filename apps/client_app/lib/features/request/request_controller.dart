import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

/// Everything the customer has filled in so far.
///
/// Held as one immutable value so the quote step, the summary card and the
/// submit call all read the same thing, and so a killed app can restore the
/// draft rather than making a stranded customer type it twice.
class RequestDraft {
  const RequestDraft({
    this.pickup,
    this.dropoff,
    this.vehicle = const ServiceVehicle(),
    this.truckTypeOverride,
    this.paymentMethod = PaymentMethod.cash,
    this.notes = '',
    this.photoPaths = const [],
    this.quote,
    this.quoting = false,
    this.submitting = false,
    this.failure,
  });

  final ServiceLocation? pickup;
  final ServiceLocation? dropoff;
  final ServiceVehicle vehicle;

  /// Set only when the customer disagrees with the inferred type and picks
  /// another. Null means "trust the inference".
  final TruckType? truckTypeOverride;
  final PaymentMethod paymentMethod;
  final String notes;
  final List<String> photoPaths;
  final QuoteResult? quote;
  final bool quoting;
  final bool submitting;
  final Failure? failure;

  TruckType get truckType => truckTypeOverride ?? vehicle.inferredTruckType;

  bool get hasLocations => pickup != null && dropoff != null;

  bool get hasVehicle =>
      vehicle.make.trim().isNotEmpty || vehicle.type != VehicleType.unknown;

  /// The quote step is only worth taking once we know where and what.
  bool get canQuote => hasLocations && hasVehicle;

  bool get canSubmit =>
      canQuote && quote != null && !submitting && !quoting;

  RequestDraft copyWith({
    ServiceLocation? pickup,
    ServiceLocation? dropoff,
    ServiceVehicle? vehicle,
    TruckType? truckTypeOverride,
    bool clearTruckTypeOverride = false,
    PaymentMethod? paymentMethod,
    String? notes,
    List<String>? photoPaths,
    QuoteResult? quote,
    bool clearQuote = false,
    bool? quoting,
    bool? submitting,
    Failure? failure,
    bool clearFailure = false,
  }) {
    return RequestDraft(
      pickup: pickup ?? this.pickup,
      dropoff: dropoff ?? this.dropoff,
      vehicle: vehicle ?? this.vehicle,
      truckTypeOverride:
          clearTruckTypeOverride ? null : (truckTypeOverride ?? this.truckTypeOverride),
      paymentMethod: paymentMethod ?? this.paymentMethod,
      notes: notes ?? this.notes,
      photoPaths: photoPaths ?? this.photoPaths,
      quote: clearQuote ? null : (quote ?? this.quote),
      quoting: quoting ?? this.quoting,
      submitting: submitting ?? this.submitting,
      failure: clearFailure ? null : (failure ?? this.failure),
    );
  }
}

class RequestController extends Notifier<RequestDraft> {
  @override
  RequestDraft build() {
    // Seed the pickup with the customer's current position so the common case
    // — "tow me from where I am" — needs no input at all.
    return const RequestDraft(
      pickup: ServiceLocation(
        geo: DoLocations.defaultCenter,
        address: 'Av. 27 de Febrero, Santo Domingo',
      ),
    );
  }

  /// Any change to what is being priced invalidates the quote. Letting a stale
  /// price survive an edit is how a customer gets charged for a different tow
  /// than the one they agreed to.
  void setPickup(ServiceLocation value) =>
      state = state.copyWith(pickup: value, clearQuote: true, clearFailure: true);

  void setDropoff(ServiceLocation value) =>
      state = state.copyWith(dropoff: value, clearQuote: true, clearFailure: true);

  void setVehicle(ServiceVehicle value) => state = state.copyWith(
        vehicle: value,
        clearQuote: true,
        clearTruckTypeOverride: true,
        clearFailure: true,
      );

  void setTruckType(TruckType? value) => state = value == null
      ? state.copyWith(clearTruckTypeOverride: true, clearQuote: true)
      : state.copyWith(truckTypeOverride: value, clearQuote: true);

  void setPaymentMethod(PaymentMethod value) =>
      state = state.copyWith(paymentMethod: value);

  void setNotes(String value) => state = state.copyWith(notes: value);

  void addPhoto(String path) =>
      state = state.copyWith(photoPaths: [...state.photoPaths, path]);

  void removePhoto(String path) => state = state.copyWith(
        photoPaths: state.photoPaths.where((p) => p != path).toList(),
      );

  /// Asks the server what this tow costs. The app never prices anything itself.
  Future<void> requestQuote() async {
    final pickup = state.pickup;
    final dropoff = state.dropoff;
    if (pickup == null || dropoff == null || state.quoting) return;

    state = state.copyWith(quoting: true, clearFailure: true, clearQuote: true);

    final result = await ref.read(functionsGatewayProvider).quoteService(
          pickup: pickup,
          dropoff: dropoff,
          vehicle: state.vehicle,
          truckTypeOverride: state.truckTypeOverride,
        );

    state = result.fold(
      (quote) => state.copyWith(quoting: false, quote: quote),
      (failure) => state.copyWith(quoting: false, failure: failure),
    );
  }

  /// Submits the request. Returns the new service id, or null on failure — the
  /// failure itself is on [RequestDraft.failure] for the screen to render.
  Future<String?> submit() async {
    final pickup = state.pickup;
    final dropoff = state.dropoff;
    final quote = state.quote;
    if (pickup == null || dropoff == null || quote == null) return null;

    if (quote.isStale(DateTime.now().toUtc())) {
      state = state.copyWith(
        clearQuote: true,
        failure: const Failure(FailureCode.quoteExpired),
      );
      return null;
    }

    state = state.copyWith(submitting: true, clearFailure: true);

    final result = await ref.read(functionsGatewayProvider).requestService(
          pickup: pickup,
          dropoff: dropoff,
          vehicle: state.vehicle,
          truckType: quote.truckType,
          paymentMethod: state.paymentMethod,
          quoteSignature: quote.signature,
          quoteExpiresAt: quote.expiresAt,
          notes: state.notes.isEmpty ? null : state.notes,
        );

    // Awaited above; fold is synchronous here.
    // ignore: async_return_with_no_await
    return result.fold(
      (serviceId) {
        state = state.copyWith(submitting: false);
        return serviceId;
      },
      (failure) {
        state = state.copyWith(submitting: false, failure: failure);
        return null;
      },
    );
  }

  void reset() => state = build();
}

final NotifierProvider<RequestController, RequestDraft> requestControllerProvider =
    NotifierProvider<RequestController, RequestDraft>(RequestController.new);
