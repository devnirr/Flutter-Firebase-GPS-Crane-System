import 'enums.dart';
import 'failures.dart';
import 'models/app_user.dart';
import 'models/billing.dart';
import 'models/dispatch_models.dart';
import 'models/driver.dart';
import 'models/remote_config_models.dart';
import 'models/service.dart';
import 'models/truck.dart';
import 'value_objects.dart';

/// Repository contracts.
///
/// Every one has a Firestore implementation and an in-memory fake. The fakes
/// are not test scaffolding bolted on afterwards — they are how the UI is built
/// and reviewed before a Firebase project exists, and how widget tests run
/// without a network.
///
/// Note what is missing: there is no `updateServiceStatus`. Moving a service
/// between states is a server operation, so it lives on [FunctionsGateway]
/// where it is visibly a remote call that can fail.

/// The signed-in identity, whichever product is asking.
abstract interface class AuthRepository {
  Stream<String?> watchUserId();

  String? get currentUserId;

  /// Custom claims, refreshed from the ID token. `null` until signed in.
  Future<UserRole> currentRole({bool forceRefresh = false});

  /// Starts phone verification. Returns a verification id to pass to
  /// [confirmSmsCode], or completes the sign-in directly on Android
  /// auto-retrieval.
  Future<Result<String>> startPhoneVerification(String e164Phone);

  Future<Result<void>> confirmSmsCode({
    required String verificationId,
    required String smsCode,
  });

  Future<Result<void>> signInWithEmail(String email, String password);

  Future<Result<void>> sendPasswordReset(String email);

  Future<Result<void>> changePassword(String newPassword);

  Future<void> signOut();
}

abstract interface class UserRepository {
  Stream<AppUser?> watchUser(String uid);

  Future<Result<AppUser>> fetchUser(String uid);

  /// Only the client-writable whitelist: name, email, rnc, locale, preferences.
  Future<Result<void>> updateProfile(
    String uid, {
    String? name,
    String? email,
    String? rnc,
    PaymentMethod? preferredPaymentMethod,
  });

  Future<Result<void>> registerFcmToken(String uid, String token, String platform);

  Future<Result<void>> removeFcmToken(String uid, String token);
}

abstract interface class DriverRepository {
  Stream<Driver?> watchDriver(String uid);

  Stream<List<Driver>> watchAllDrivers({DriverStatus? status});

  Future<Result<Driver>> fetchDriver(String uid);

  Stream<List<DriverDocument>> watchDocuments(String uid);

  /// Publishes a position to RTDB. Called at most once every five seconds.
  Future<void> publishLivePosition(DriverLivePosition position);

  /// Sets `isOnline`, and registers the `onDisconnect` handler so a crashed app
  /// removes itself from dispatch without waiting for the stale-position sweep.
  Future<Result<void>> setOnline(String uid, {required bool online});

  /// Admin view of the fleet's live positions.
  Stream<List<DriverLivePosition>> watchLivePositions();
}

abstract interface class TruckRepository {
  Stream<List<Truck>> watchTrucks({bool activeOnly});

  Stream<Truck?> watchTruck(String id);

  Future<Result<Truck>> fetchTruck(String id);
}

/// One page of history, with the cursor needed for the next one.
class PagedServices {
  const PagedServices({required this.items, required this.cursor, required this.hasMore});

  final List<Service> items;

  /// Opaque cursor for the next page. Implementations carry a Firestore
  /// snapshot here; callers only pass it back.
  final Object? cursor;
  final bool hasMore;

  static const empty = PagedServices(items: [], cursor: null, hasMore: false);
}

abstract interface class ServiceRepository {
  Stream<Service?> watchService(String id);

  /// The client's single in-flight service, or null.
  Stream<Service?> watchActiveForClient(String clientId);

  Stream<Service?> watchActiveForDriver(String driverId);

  /// Everything a dispatcher needs on the operations map.
  Stream<List<Service>> watchActiveServices();

  Stream<List<ServiceEvent>> watchEvents(String serviceId);

  Stream<ServiceTracking?> watchTracking(String serviceId);

  /// Paginated. Never fetch an unbounded history — a two-year customer would
  /// otherwise pull thousands of documents to draw one list.
  Future<Result<PagedServices>> fetchHistory({
    required String userId,
    required UserRole role,
    int limit = 20,
    Object? cursor,
  });
}

abstract interface class OfferRepository {
  /// The one open offer addressed to this chofer, if any. Drives the ringing
  /// screen; there is deliberately never a queue of them.
  Stream<Offer?> watchIncomingOffer(String driverId);

  Stream<Offer?> watchOffer(String serviceId, String driverId);
}

abstract interface class ChatRepository {
  Stream<List<ChatMessage>> watchMessages(String serviceId, {int limit = 100});

  /// Written directly by the app — the only subcollection that is. Rules
  /// enforce sender identity, length, and that the service is still open.
  Future<Result<void>> sendMessage({
    required String serviceId,
    required String senderId,
    required UserRole senderRole,
    required String text,
    required String clientMsgId,
  });

  Future<Result<void>> markRead(String serviceId, String readerId);
}

abstract interface class EarningsRepository {
  Stream<EarningsSummary?> watchSummary(String driverId);

  Future<Result<List<EarningEntry>>> fetchEntries({
    required String driverId,
    required DateTime from,
    required DateTime to,
  });
}

abstract interface class InvoiceRepository {
  Future<Result<Invoice>> fetchInvoice(String invoiceId);

  /// A short-lived signed URL. Storage objects are never public.
  Future<Result<String>> downloadUrl(String invoiceId);
}

abstract interface class ConfigRepository {
  Stream<PricingConfig> watchPricing();

  Stream<DispatchConfig> watchDispatch();

  Stream<AppSettings> watchAppSettings();

  Future<AppSettings> currentAppSettings();
}

/// The result of asking the server what a tow will cost.
class QuoteResult {
  const QuoteResult({
    required this.quote,
    required this.route,
    required this.expiresAt,
    required this.signature,
    required this.truckType,
  });

  final Quote quote;
  final ServiceRoute route;
  final DateTime expiresAt;

  /// HMAC over the priced inputs. `requestService` recomputes it and refuses a
  /// mismatch, so a modified client cannot request a RD$200 tow to Puerto Plata.
  final String signature;
  final TruckType truckType;

  bool isStale(DateTime now) => now.isAfter(expiresAt);
}

/// Everything that changes state lives here, because everything that changes
/// state is a Cloud Function call.
abstract interface class FunctionsGateway {
  Future<Result<QuoteResult>> quoteService({
    required ServiceLocation pickup,
    required ServiceLocation dropoff,
    required ServiceVehicle vehicle,
    TruckType? truckTypeOverride,
  });

  Future<Result<String>> requestService({
    required ServiceLocation pickup,
    required ServiceLocation dropoff,
    required ServiceVehicle vehicle,
    required TruckType truckType,
    required PaymentMethod paymentMethod,
    required String quoteSignature,
    /// Echoed back from [quoteService]. The signature covers it, so the server
    /// can tell an expired quote from a tampered one.
    required DateTime quoteExpiresAt,
    String? paymentMethodId,
    String? notes,
  });

  Future<Result<void>> cancelService({
    required String serviceId,
    required String reason,
  });

  Future<Result<void>> acceptService(String serviceId);

  Future<Result<void>> rejectService(String serviceId, {DriverCancelReason? reason});

  Future<Result<void>> markArrived({
    required String serviceId,
    required LatLng position,
  });

  Future<Result<void>> startService({
    required String serviceId,
    required List<String> photoPaths,
  });

  Future<Result<void>> completeService({
    required String serviceId,
    required LatLng position,
    required List<String> photoPaths,
    String? notes,
  });

  Future<Result<void>> confirmCashCollected({
    required String serviceId,
    required int amountCents,
    String? discrepancyReason,
  });

  Future<Result<void>> cancelByDriver({
    required String serviceId,
    required DriverCancelReason reason,
  });

  Future<Result<void>> rateService({
    required String serviceId,
    required int stars,
    String? comment,
  });

  /// A short-lived signed URL for an invoice PDF.
  ///
  /// Minted by a callable rather than read from Storage: the bucket refuses
  /// client reads, so a leaked path is not a leaked document.
  Future<Result<String>> invoiceDownloadUrl(String invoiceId);

  /// Pushes the chofer's live ETA to `tracking/{serviceId}` for the client.
  Future<Result<void>> publishEta({
    required String serviceId,
    required int etaSeconds,
    required int remainingMeters,
  });
}
