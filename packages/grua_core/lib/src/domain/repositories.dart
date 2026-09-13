import 'dart:typed_data';

import 'enums.dart';
import 'failures.dart';
import 'models/app_user.dart';
import 'models/billing.dart';
import 'models/chat_prefs.dart';
import 'models/chat_request.dart';
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
  /// The document id registration writes its one vehicle to.
  static const String primaryVehicleId = 'principal';

  Stream<AppUser?> watchUser(String uid);

  /// The customer roster, for the office. Newest registration first, because
  /// the reason to open this list is nearly always "who just signed up".
  ///
  /// Staff-only in practice: the rules let a dispatcher read `users/` and
  /// refuse the same query to everyone else, so calling this from the client
  /// app fails rather than quietly handing over the customer base.
  Stream<List<AppUser>> watchAllClients({int limit = 500});

  Future<Result<AppUser>> fetchUser(String uid);

  /// Only the client-writable whitelist: name, email, rnc, address, locale,
  /// preferences. Anything else is refused by the rules, so passing it here
  /// would fail the whole write rather than be ignored.
  Future<Result<void>> updateProfile(
    String uid, {
    String? name,
    String? email,
    String? rnc,
    String? address,
    PaymentMethod? preferredPaymentMethod,
  });

  /// The vehicles a customer has saved, newest first.
  Stream<List<ServiceVehicle>> watchVehicles(String uid);

  /// Writes one saved vehicle under a caller-chosen id.
  ///
  /// Registration always passes [primaryVehicleId] so signing up twice
  /// overwrites rather than accumulating near-duplicates.
  Future<Result<void>> saveVehicle(
    String uid,
    ServiceVehicle vehicle, {
    String id,
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

  /// Admin view of the fleet's live positions.
  Stream<List<DriverLivePosition>> watchLivePositions();

  /// Says "this chofer has the app open" at `/presence/{uid}` for as long as
  /// the returned stream is listened to.
  ///
  /// Separate from [FunctionsGateway.setOnline]: that is the chofer asking for
  /// work, this is
  /// only the app running. The server is told up front to clear the node when
  /// the connection drops, so a closed tab, a killed app or a lost signal all
  /// read as disconnected without the app getting a last word in. Cancelling
  /// the subscription clears it at once.
  Stream<void> holdAppPresence(String uid);

  /// Clears `/presence/{uid}` now. Call it before signing out: once the
  /// session is gone the rules refuse the write, and the node would read as
  /// connected until the connection itself closed.
  Future<void> clearAppPresence(String uid);

  /// Ids of the choferes with the app open right now. Staff only.
  Stream<Set<String>> watchConnectedDriverIds();

  /// Uploads one piece of paperwork to Storage and returns the object path.
  ///
  /// Bytes rather than a file handle because the panel is a web build, where a
  /// picked file never has a path on disk. The returned path is not the record:
  /// `drivers/{uid}/documents/{type}` is server-written, so the caller passes
  /// this to [FunctionsGateway.attachDriverDocument] to make the upload count.
  Future<Result<String>> uploadDocument({
    required String driverId,
    required DriverDocumentType type,
    required Uint8List bytes,
    required String fileName,
    required String contentType,
  });

  /// Uploads the chofer's profile photo and returns the object path. Like a
  /// document, it only counts once the caller passes the path to
  /// [FunctionsGateway.setDriverPhoto]: `photoUrl` is server-written too.
  Future<Result<String>> uploadDriverPhoto({
    required String driverId,
    required Uint8List bytes,
    required String contentType,
  });
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

  /// Every service, newest first, for the office's Servicios page. Staff only:
  /// the rules refuse the query to anyone else.
  ///
  /// [statuses] narrows to those states (at most 30, Firestore's `in` limit),
  /// and [from] / [to] to a creation window, `to` exclusive. Both run on the
  /// server against the `status, createdAt` index, so a filter never means
  /// paging through everything to find three cancellations.
  Future<Result<PagedServices>> fetchServices({
    Set<ServiceStatus>? statuses,
    DateTime? from,
    DateTime? to,
    int limit = 50,
    Object? cursor,
  });

  /// The service with this human code (`GR-260908-0431`), or null. What the
  /// office types when a customer reads their code over the phone.
  Future<Result<Service?>> fetchServiceByCode(String code);

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
  ///
  /// [imageUrl] comes from [uploadImage]. A message carries words, a photo, or
  /// both; the rules refuse an empty one.
  Future<Result<void>> sendMessage({
    required String serviceId,
    required String senderId,
    required UserRole senderRole,
    required String text,
    required String clientMsgId,
    String imageUrl,
  });

  /// Puts a photo in the bucket under `chat/{serviceId}/` and returns the URL
  /// to send. Demo mode has no bucket and hands back a data URI.
  Future<Result<String>> uploadImage({
    required String serviceId,
    required Uint8List bytes,
    required String contentType,
  });

  /// Retracts messages for both sides: the words and the photo are cleared and
  /// a tombstone is left in their place.
  ///
  /// Either party may retract anything in their own conversation, their
  /// message or the other person's; [senderId] is the caller, and the rules
  /// refuse anyone who is not in the conversation.
  Future<Result<void>> deleteMessages({
    required String serviceId,
    required String senderId,
    required List<String> messageIds,
  });

  Future<Result<void>> markRead(String serviceId, String readerId);
}

/// Conversations a customer opens with a nearby truck before any job exists.
///
/// The request itself is server-written through [FunctionsGateway.requestChat]
/// and [FunctionsGateway.respondChatRequest]; its messages are written straight
/// from the apps, like a job's, and the rules only let them in while the
/// chofer has accepted and the conversation is open.
abstract interface class ChatRequestRepository {
  /// Requests addressed to this chofer, newest first.
  Stream<List<ChatRequest>> watchForDriver(String driverId, {int limit = 20});

  /// Requests this customer has sent, newest first.
  Stream<List<ChatRequest>> watchForClient(String clientId, {int limit = 10});

  Stream<ChatRequest?> watchRequest(String requestId);

  Stream<List<ChatMessage>> watchMessages(String requestId, {int limit = 100});

  Future<Result<void>> sendMessage({
    required String requestId,
    required String senderId,
    required UserRole senderRole,
    required String text,
    required String clientMsgId,
    String imageUrl,
  });

  /// As [ChatRepository.uploadImage], under `chat/{requestId}/`.
  Future<Result<String>> uploadImage({
    required String requestId,
    required Uint8List bytes,
    required String contentType,
  });

  /// As [ChatRepository.deleteMessages].
  Future<Result<void>> deleteMessages({
    required String requestId,
    required String senderId,
    required List<String> messageIds,
  });

  Future<Result<void>> markRead(String requestId, String readerId);
}

/// Names one conversation for the typing indicator. Both kinds share the
/// node, so the keys have to say which is which.
String jobThreadKey(String serviceId) => 'job:$serviceId';

String requestThreadKey(String requestId) => 'request:$requestId';

/// Who is typing in a conversation, right now.
///
/// This lives in the Realtime Database rather than Firestore: it changes on
/// every few keystrokes, it is worthless a moment later, and RTDB clears it on
/// its own when a phone drops off — a Firestore write per keystroke would cost
/// real money to say something nobody needs a minute from now.
///
/// The thread key names the conversation across both kinds — see
/// [jobThreadKey] and [requestThreadKey].
abstract interface class TypingRepository {
  /// The uids typing in [threadKey], the caller's own included. Callers filter
  /// themselves out; a stale flag ages out on its own.
  Stream<Set<String>> watchTyping(String threadKey);

  /// Says this user is typing, or has stopped. Never throws: a conversation
  /// that cannot show the indicator still has to send messages.
  Future<void> setTyping({
    required String threadKey,
    required String uid,
    required bool typing,
  });
}

/// Each person's own view of their conversations: what they cleared away,
/// what they deleted off their list, and who they blocked.
///
/// None of it is visible to the other side, and none of it touches the
/// messages themselves — retracting those is [ChatRepository.deleteMessages].
abstract interface class ChatPrefsRepository {
  /// What this person did to one conversation. Emits [ChatThreadPrefs.none]
  /// for a conversation they never touched.
  Stream<ChatThreadPrefs> watchThread({
    required String uid,
    required String threadKey,
  });

  /// Every conversation they touched, by thread key.
  Stream<Map<String, ChatThreadPrefs>> watchThreads(String uid);

  /// The uids this person blocked.
  Stream<Set<String>> watchBlocked(String uid);

  /// Whether [otherUid] blocked this person. One document, not their list:
  /// you learn that you were blocked, never who else was.
  Stream<bool> watchBlockedBy({required String uid, required String otherUid});

  /// Hides everything said up to now, keeping the conversation on their list.
  Future<Result<void>> clearThread({
    required String uid,
    required String threadKey,
  });

  /// As [clearThread], and takes the conversation off their list until
  /// something new is said in it.
  Future<Result<void>> deleteThread({
    required String uid,
    required String threadKey,
  });

  Future<Result<void>> setBlocked({
    required String uid,
    required String otherUid,
    required bool blocked,
  });
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

/// What the office fills in to open a chofer account.
///
/// [email] is not on the paper form the office works from, but an Auth account
/// has to have one: it is the credential the chofer signs in with.
class NewDriver {
  const NewDriver({
    required this.name,
    required this.cedula,
    required this.phone,
    required this.email,
    required this.licenseNumber,
    required this.licenseExpiry,
    this.truckId,
    this.zones = const [],
    this.companyName = '',
    this.rnc = '',
  });

  final String name;

  /// Digits only. The server validates the check digit and refuses a duplicate.
  final String cedula;
  final String phone;
  final String email;
  final String licenseNumber;
  final DateTime licenseExpiry;

  /// The grúa this chofer drives, or null when one has not been assigned yet.
  /// A chofer without a truck can sign in but cannot go online.
  final String? truckId;
  final List<String> zones;
  final String companyName;
  final String rnc;

  Map<String, dynamic> toJson() => {
        'name': name,
        'cedula': cedula,
        'phone': phone,
        'email': email,
        'licenseNumber': licenseNumber,
        'licenseExpiry': licenseExpiry.toUtc().toIso8601String(),
        'truckId': ?truckId,
        'zones': zones,
        'companyName': companyName,
        'rnc': rnc,
      };
}

/// What the office can change on an existing chofer.
///
/// [NewDriver] minus the cédula: it is who the chofer is, and the duplicate
/// check keys on it, so a wrong one means a new account rather than an edit.
class DriverUpdate {
  const DriverUpdate({
    required this.name,
    required this.phone,
    required this.email,
    required this.licenseNumber,
    required this.licenseExpiry,
    this.truckId,
    this.zones = const [],
    this.companyName = '',
    this.rnc = '',
  });

  final String name;
  final String phone;
  final String email;
  final String licenseNumber;
  final DateTime licenseExpiry;

  /// Null takes the chofer off their grúa, which also takes them offline.
  final String? truckId;
  final List<String> zones;
  final String companyName;
  final String rnc;

  Map<String, dynamic> toJson() => {
        'name': name,
        'phone': phone,
        'email': email,
        'licenseNumber': licenseNumber,
        'licenseExpiry': licenseExpiry.toUtc().toIso8601String(),
        // Sent even when null: here null means "unassign", not "unchanged".
        'truckId': truckId,
        'zones': zones,
        'companyName': companyName,
        'rnc': rnc,
      };
}

/// What a chofer fills in to ask for an account from the driver app.
///
/// The same papers as [NewDriver], minus what only the office can decide — the
/// grúa and the coverage zones — plus the password the chofer picks, since
/// there is no office reading a temporary one out to them.
///
/// The account this opens is `inactive`, exactly like one the office creates:
/// signing up is asking to work, not being cleared to.
class DriverSignUp {
  const DriverSignUp({
    required this.name,
    required this.cedula,
    required this.phone,
    required this.email,
    required this.password,
    required this.licenseNumber,
    required this.licenseExpiry,
    this.companyName = '',
    this.rnc = '',
  });

  final String name;

  /// Digits only. The server validates the check digit and refuses a duplicate.
  final String cedula;

  /// E.164, `+1` and ten digits.
  final String phone;
  final String email;
  final String password;
  final String licenseNumber;
  final DateTime licenseExpiry;
  final String companyName;
  final String rnc;

  Map<String, dynamic> toJson() => {
        'name': name,
        'cedula': cedula,
        'phone': phone,
        'email': email,
        'password': password,
        'licenseNumber': licenseNumber,
        'licenseExpiry': licenseExpiry.toUtc().toIso8601String(),
        'companyName': companyName,
        'rnc': rnc,
      };
}

/// One truck from "grúas cerca de ti": where it roughly is, and nothing about
/// who drives it.
class NearbyTruck {
  const NearbyTruck({
    required this.position,
    required this.truckType,
    required this.distanceMeters,
    this.heading = 0,
    this.ref = '',
  });

  /// Rounded by the server to ~110 m.
  final LatLng position;
  final TruckType truckType;
  final int distanceMeters;
  final double heading;

  /// A sealed, short-lived handle on this truck, passed back as
  /// `preferredTruckRef` by "Pedir esta grúa". Opaque on purpose: it names
  /// no driver, and it changes on every search.
  final String ref;

  String get distanceLabel => distanceMeters < 1000
      ? '$distanceMeters m'
      : '${(distanceMeters / 1000).toStringAsFixed(1)} km';
}

/// What the office fills in for a grúa, on creation and on every edit.
///
/// The assignment is not here: a chofer is put on a grúa from the chofer's
/// form, so there is one place that decides who drives what.
class TruckDetails {
  const TruckDetails({
    required this.plate,
    required this.make,
    required this.model,
    required this.type,
    required this.capacityKg,
    required this.insuranceExpiry,
    required this.marbeteExpiry,
    this.year,
    this.color = '',
    this.registrationNumber = '',
    this.insurancePolicy = '',
  });

  /// As typed. The server normalises it and enforces uniqueness.
  final String plate;
  final String make;
  final String model;
  final int? year;
  final String color;

  /// What dispatch matches jobs on. Never [TruckType.unknown].
  final TruckType type;
  final int capacityKg;

  /// The matrícula number.
  final String registrationNumber;
  final String insurancePolicy;
  final DateTime insuranceExpiry;
  final DateTime marbeteExpiry;

  Map<String, dynamic> toJson() => {
        'plate': plate,
        'make': make,
        'model': model,
        'year': year,
        'color': color,
        'type': type.wire,
        'capacityKg': capacityKg,
        'registrationNumber': registrationNumber,
        'insurancePolicy': insurancePolicy,
        'insuranceExpiry': insuranceExpiry.toUtc().toIso8601String(),
        'marbeteExpiry': marbeteExpiry.toUtc().toIso8601String(),
      };
}

/// The one moment the temporary password exists in readable form.
class CreatedDriver {
  const CreatedDriver({required this.driverId, required this.temporaryPassword});

  final String driverId;

  /// Shown once and never retrievable again — the office reads it to the
  /// chofer, and the account forces a change on first sign-in.
  final String temporaryPassword;
}

/// Everything that changes state lives here, because everything that changes
/// state is a Cloud Function call.
abstract interface class FunctionsGateway {
  /// Creates the caller's `users/` document if it does not exist yet.
  ///
  /// The security rules forbid a client from creating its own user document,
  /// because `role` and `blocked` are not the client's to decide. So the
  /// document only comes into being through this call, and until it does the
  /// customer has no profile for any screen to read.
  ///
  /// Idempotent: it costs one read when the document is already there, which
  /// is what makes calling it on every launch reasonable.
  Future<Result<void>> ensureProfile({String locale});

  /// Grants the caller the admin claim, once, when nobody holds it yet.
  ///
  /// The server also requires the caller's email to be on the
  /// `ADMIN_BOOTSTRAP_EMAILS` allowlist, so this cannot be used to escalate
  /// later. It is permanently inert after the first admin exists.
  Future<Result<void>> bootstrapFirstAdmin();

  /// The trucks that could take a job within [radiusKm] of [center] right now,
  /// nearest first: online, free and reporting. Rough positions only — the
  /// customer app may not read the fleet's live positions itself.
  Future<Result<List<NearbyTruck>>> nearbyTrucks({
    required LatLng center,
    required double radiusKm,
  });

  /// "Chatear" on a nearby truck: asks its chofer to talk, before any job.
  ///
  /// [truckRef] is [NearbyTruck.ref]; the server opens it, so the customer
  /// never learns who drives. Asking the same truck again returns the request
  /// already waiting or open. Returns the request's id.
  Future<Result<String>> requestChat(String truckRef);

  /// The chofer's answer to a chat request. Refused once it has lapsed or
  /// been answered.
  Future<Result<void>> respondChatRequest(
    String requestId, {
    required bool accept,
  });

  /// Ends a chat request from either side: withdrawn or refused while it
  /// waits, closed once open.
  Future<Result<void>> closeChatRequest(String requestId);

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
    /// [NearbyTruck.ref] of the truck picked on the map, offered the job
    /// first. A stale or unknown one is ignored, not refused.
    String? preferredTruckRef,
  });

  Future<Result<void>> cancelService({
    required String serviceId,
    required String reason,
  });

  /// The "En línea" switch, for the signed-in chofer.
  ///
  /// Online needs an active account and a grúa; offline is refused mid-tow.
  /// Being online is not yet being dispatchable: the phone still has to land
  /// a fresh position in `/live`, which the app starts doing as soon as the
  /// record says online.
  Future<Result<void>> setOnline({required bool online});

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

  /// Creates a chofer account and returns the uid with the password to read
  /// out to them.
  ///
  /// The account is always created `inactive`, whatever the office asks for:
  /// it is the document check that clears a grúa to work, and this call is
  /// upstream of it. The licence expiry is stored on the driver so the expiry
  /// sweep has something to act on even before the licence photo is reviewed.
  Future<Result<CreatedDriver>> createDriver(NewDriver driver);

  /// Opens a chofer account from the driver app and returns its uid.
  ///
  /// Callable without being signed in — there is nobody to sign in as yet. The
  /// account is always created `inactive`, the same as [createDriver]: the
  /// office still has to verify the documents before the chofer can go online.
  /// The caller signs in with the email and password afterwards.
  Future<Result<String>> registerDriver(DriverSignUp signUp);

  /// Saves the office's edits to a chofer. Changing the grúa is refused while
  /// the chofer holds a job.
  Future<Result<void>> updateDriver(String driverId, DriverUpdate update);

  /// Takes a chofer off the roster: the record is archived, not erased, so
  /// their services and earnings keep a name, and the account is disabled.
  /// Refused while the chofer holds a job.
  Future<Result<void>> archiveDriver(String driverId);

  /// Clears a chofer to work, or stops them.
  ///
  /// [DriverStatus.active] is the office's sign-off that the papers are in
  /// order; it is the only way out of the `inactive` every account starts in.
  /// Anything else takes the chofer offline and revokes their session, so it is
  /// refused while they hold a job. [reason] is stored as `statusReason`, and
  /// for a suspension it is what the chofer reads on their blocked screen.
  Future<Result<void>> setDriverStatus({
    required String driverId,
    required DriverStatus status,
    String reason = '',
  });

  /// Hands a service to a chofer by hand, when the cascade could not.
  ///
  /// The same invariants as an automatic accept apply server-side — the chofer
  /// must be active, free, and driving a truck that can do the job — because a
  /// manual assignment that ignores them strands the same customer, just later.
  /// A refusal comes back as a [Failure] the panel shows; the dispatcher has to
  /// know their pick was not taken.
  Future<Result<void>> assignServiceManually({
    required String serviceId,
    required String driverId,
    String note = '',
  });

  /// Adds a grúa to the fleet, unassigned, and returns its id. Refused when
  /// the plate is malformed or already belongs to another grúa.
  Future<Result<String>> createTruck(TruckDetails details);

  /// Saves the office's edits to a grúa. The plate and type are refused
  /// mid-tow, and the type while the chofer on it is online, because the
  /// type is what dispatch matches jobs on.
  Future<Result<void>> updateTruck(String truckId, TruckDetails details);

  /// Takes a grúa off the fleet: archived, not erased, and its plate freed.
  /// The chofer on it is left without a grúa and taken offline. Refused
  /// mid-tow.
  Future<Result<void>> archiveTruck(String truckId);

  /// Records an uploaded document at `drivers/{driverId}/documents/{type}`.
  ///
  /// Separate from the upload because Storage and Firestore are two writes and
  /// only the second one is governed: the rules refuse every client write under
  /// `drivers/`, so a document nobody attached is a file the office never sees.
  Future<Result<void>> attachDriverDocument({
    required String driverId,
    required DriverDocumentType type,
    required String storagePath,
    required String fileName,
    required String contentType,
    required int sizeBytes,
    DateTime? expiresAt,
  });

  /// Points `drivers/{driverId}.photoUrl` at an uploaded profile photo and
  /// returns the URL. The server mints the URL from the object itself, so it
  /// can only ever name an image under that chofer's own avatar folder.
  Future<Result<String>> setDriverPhoto({
    required String driverId,
    required String storagePath,
  });

  /// Pushes the chofer's live ETA to `tracking/{serviceId}` for the client.
  Future<Result<void>> publishEta({
    required String serviceId,
    required int etaSeconds,
    required int remainingMeters,
  });
}
