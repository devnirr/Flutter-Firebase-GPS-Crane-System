import 'package:flutter_riverpod/flutter_riverpod.dart';
// Riverpod 3 keeps `Override` out of the default export surface.
import 'package:flutter_riverpod/misc.dart'
    show FutureProviderFamily, Override, ProviderFamily, StreamProviderFamily;

import 'calls/voice_call.dart';
import 'calls/voice_transport.dart';
import 'config/app_config.dart';
import 'config/maps_script.dart';
import 'data/demo/demo_backend.dart';
import 'data/demo/demo_repositories.dart';
import 'domain/enums.dart';
import 'domain/models/app_user.dart';
import 'domain/models/billing.dart';
import 'domain/models/chat_prefs.dart';
import 'domain/models/chat_request.dart';
import 'domain/models/dispatch_models.dart';
import 'domain/models/driver.dart';
import 'domain/models/payments.dart';
import 'domain/models/remote_config_models.dart';
import 'domain/models/service.dart';
import 'domain/models/truck.dart';
import 'domain/repositories.dart';
import 'domain/value_objects.dart';
import 'location/location_service.dart';
import 'location/places_service.dart';
import 'location/route_service.dart';

/// Dependency wiring for all three apps.
///
/// Repositories are declared here as unimplemented providers and bound at
/// startup by `runGruaApp`, which chooses the demo or Firebase implementation.
/// Screens depend on the interface only, so the same widget tree runs against
/// an in-memory backend in a widget test, the emulator in development, and
/// production — with no conditionals inside the UI.

/// Build configuration. Overridden in `main()` with the app's own [AppKind].
final appConfigProvider = Provider<AppConfig>(
  (ref) => throw UnimplementedError('appConfigProvider must be overridden'),
);

/// The in-memory backend. Only bound when running in demo mode.
final demoBackendProvider = Provider<DemoBackend>(
  (ref) {
    final backend = DemoBackend()..seed();
    ref.onDispose(backend.dispose);
    return backend;
  },
);

// ---------------------------------------------------------------------------
// Repositories
// ---------------------------------------------------------------------------

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => throw UnimplementedError('authRepositoryProvider must be overridden'),
);

final userRepositoryProvider = Provider<UserRepository>(
  (ref) => throw UnimplementedError('userRepositoryProvider must be overridden'),
);

final driverRepositoryProvider = Provider<DriverRepository>(
  (ref) => throw UnimplementedError('driverRepositoryProvider must be overridden'),
);

final truckRepositoryProvider = Provider<TruckRepository>(
  (ref) => throw UnimplementedError('truckRepositoryProvider must be overridden'),
);

final serviceRepositoryProvider = Provider<ServiceRepository>(
  (ref) =>
      throw UnimplementedError('serviceRepositoryProvider must be overridden'),
);

final callRepositoryProvider = Provider<CallRepository>(
  (ref) => throw UnimplementedError('callRepositoryProvider must be overridden'),
);

final offerRepositoryProvider = Provider<OfferRepository>(
  (ref) => throw UnimplementedError('offerRepositoryProvider must be overridden'),
);

final chatRepositoryProvider = Provider<ChatRepository>(
  (ref) => throw UnimplementedError('chatRepositoryProvider must be overridden'),
);

final chatRequestRepositoryProvider = Provider<ChatRequestRepository>(
  (ref) => throw UnimplementedError(
    'chatRequestRepositoryProvider must be overridden',
  ),
);

final typingRepositoryProvider = Provider<TypingRepository>(
  (ref) =>
      throw UnimplementedError('typingRepositoryProvider must be overridden'),
);

final chatPrefsRepositoryProvider = Provider<ChatPrefsRepository>(
  (ref) =>
      throw UnimplementedError('chatPrefsRepositoryProvider must be overridden'),
);

final earningsRepositoryProvider = Provider<EarningsRepository>(
  (ref) =>
      throw UnimplementedError('earningsRepositoryProvider must be overridden'),
);

final invoiceRepositoryProvider = Provider<InvoiceRepository>(
  (ref) =>
      throw UnimplementedError('invoiceRepositoryProvider must be overridden'),
);

final configRepositoryProvider = Provider<ConfigRepository>(
  (ref) =>
      throw UnimplementedError('configRepositoryProvider must be overridden'),
);

final functionsGatewayProvider = Provider<FunctionsGateway>(
  (ref) => throw UnimplementedError('functionsGatewayProvider must be overridden'),
);

/// Binds every repository to the in-memory demo backend.
///
/// Used by demo builds and by widget tests. Pass a pre-seeded [backend] from a
/// test to control the fixture, and [actingAs] to sign in as somebody other
/// than the seeded customer — the driver app runs the same wiring as a chofer.
List<Override> demoOverrides({
  DemoBackend? backend,
  UserRole role = UserRole.client,
  String? actingAs,
  VoiceTransport Function()? voiceTransport,
}) {
  final instance = backend ?? (DemoBackend()..seed());
  if (actingAs != null) instance.currentUserId = actingAs;
  return [
    demoBackendProvider.overrideWithValue(instance),
    authRepositoryProvider
        .overrideWithValue(DemoAuthRepository(instance, role: role)),
    userRepositoryProvider.overrideWithValue(DemoUserRepository(instance)),
    driverRepositoryProvider.overrideWithValue(DemoDriverRepository(instance)),
    truckRepositoryProvider.overrideWithValue(DemoTruckRepository(instance)),
    serviceRepositoryProvider.overrideWithValue(DemoServiceRepository(instance)),
    offerRepositoryProvider.overrideWithValue(const DemoOfferRepository()),
    callRepositoryProvider.overrideWithValue(DemoCallRepository(instance)),
    // No LiveKit server in demo mode: calls ring and connect without audio.
    voiceTransportFactoryProvider
        .overrideWithValue(voiceTransport ?? SilentVoiceTransport.new),
    chatRepositoryProvider.overrideWithValue(DemoChatRepository(instance)),
    chatRequestRepositoryProvider
        .overrideWithValue(DemoChatRequestRepository(instance)),
    typingRepositoryProvider.overrideWithValue(DemoTypingRepository(instance)),
    chatPrefsRepositoryProvider
        .overrideWithValue(DemoChatPrefsRepository(instance)),
    earningsRepositoryProvider
        .overrideWithValue(DemoEarningsRepository(instance)),
    invoiceRepositoryProvider.overrideWithValue(DemoInvoiceRepository(instance)),
    configRepositoryProvider.overrideWithValue(DemoConfigRepository(instance)),
    functionsGatewayProvider
        .overrideWithValue(DemoFunctionsGateway(instance)),
  ];
}

// ---------------------------------------------------------------------------
// Device
// ---------------------------------------------------------------------------

/// Device location and geocoding. Overridable in tests with a fake geolocator.
final locationServiceProvider = Provider<LocationService>(
  (ref) => LocationService(),
);

/// Whether Google Maps is available: a key supplied at build time, or — on the
/// web — the Maps script already loaded by `index.html`.
///
/// Screens pass this to `GruaMap`, which renders a real Google map when it is
/// true and the drawn fallback when it is false. Keeping the decision in one
/// provider means no screen has to know how the map is sourced.
final hasMapsKeyProvider = Provider<bool>(
  (ref) =>
      ref.watch(appConfigProvider).googleMapsApiKey.isNotEmpty ||
      googleMapsScriptLoaded,
);

/// Address suggestions. Uses the build-time key, or — on the web, where the
/// key lives in `index.html` — the one the page's Maps script was loaded with.
final placesServiceProvider = Provider<PlacesService>((ref) {
  final configured = ref.watch(appConfigProvider).googleMapsApiKey;
  return PlacesService(
    apiKey: configured.isNotEmpty ? configured : googleMapsScriptKey,
  );
});

final routeServiceProvider = Provider<RouteService>(
  (ref) => RouteService(apiKey: ref.watch(appConfigProvider).googleMapsApiKey),
);

/// The road route between two points. Cached by the service, so a screen that
/// rebuilds with the same ends does not pay for a second call.
final FutureProviderFamily<RoadRoute, (LatLng, LatLng)> roadRouteProvider =
    FutureProvider.family<RoadRoute, (LatLng, LatLng)>(
  (ref, ends) => ref.watch(routeServiceProvider).route(ends.$1, ends.$2),
);

/// The customer's current position, resolved once per screen entry.
final currentPlaceProvider = FutureProvider<ResolvedPlace?>((ref) async {
  final result = await ref.watch(locationServiceProvider).currentPlace();
  return result.valueOrNull;
});

/// What is blocking location right now, if anything. Watched by the screens
/// that need to explain it.
final locationBlockerProvider = FutureProvider<LocationBlocker>(
  (ref) => ref.watch(locationServiceProvider).check(),
);

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------

/// The signed-in uid, or null. The router redirects on this.
final authStateProvider = StreamProvider<String?>(
  (ref) => ref.watch(authRepositoryProvider).watchUserId(),
);

/// Convenience: the uid, or null while loading.
final currentUserIdProvider = Provider<String?>(
  (ref) => ref.watch(authStateProvider).value,
);

final isSignedInProvider = Provider<bool>(
  (ref) => ref.watch(currentUserIdProvider) != null,
);

/// The signed-in account's role, read from the token's custom claim.
///
/// `forceRefresh` is deliberate: a claim granted moments ago is not in the
/// cached token, and a panel that trusted the stale copy would keep refusing
/// somebody who does now have access.
final currentRoleProvider = FutureProvider<UserRole>((ref) async {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return UserRole.unknown;
  return await ref.read(authRepositoryProvider).currentRole(forceRefresh: true);
});

/// The signed-in customer's profile.
final currentUserProvider = StreamProvider<AppUser?>((ref) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return Stream.value(null);
  return ref.watch(userRepositoryProvider).watchUser(uid);
});

/// Creates the signed-in customer's `users/` document if it is missing.
///
/// The security rules forbid a client from creating its own user document,
/// because `role` and `blocked` are not the client's to decide, so the document
/// only exists once the server has made one. Until then [currentUserProvider]
/// streams null and every screen waiting on a profile waits forever.
///
/// Watch it once near the root of the app. It re-runs whenever the uid changes,
/// which covers both a fresh sign-in and a cold start on an existing session,
/// and the callable is idempotent so the repeat costs one read.
final ensureProfileProvider = FutureProvider<void>((ref) async {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return;
  await ref.read(functionsGatewayProvider).ensureProfile();
});

/// The signed-in chofer's record.
final currentDriverProvider = StreamProvider<Driver?>((ref) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return Stream.value(null);
  return ref.watch(driverRepositoryProvider).watchDriver(uid);
});

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

final appSettingsProvider = StreamProvider<AppSettings>(
  (ref) => ref.watch(configRepositoryProvider).watchAppSettings(),
);

final pricingConfigProvider = StreamProvider<PricingConfig>(
  (ref) => ref.watch(configRepositoryProvider).watchPricing(),
);

final dispatchConfigProvider = StreamProvider<DispatchConfig>(
  (ref) => ref.watch(configRepositoryProvider).watchDispatch(),
);

// ---------------------------------------------------------------------------
// Services
// ---------------------------------------------------------------------------

/// The client's single in-flight service. Drives the client app's home screen:
/// null means "show the request button", non-null means "show tracking".
final activeClientServiceProvider = StreamProvider<Service?>((ref) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return Stream.value(null);
  return ref.watch(serviceRepositoryProvider).watchActiveForClient(uid);
});

/// The chofer's current job, restored on cold start so a force-quit mid-tow
/// reopens on the right screen.
final activeDriverServiceProvider = StreamProvider<Service?>((ref) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return Stream.value(null);
  return ref.watch(serviceRepositoryProvider).watchActiveForDriver(uid);
});

final StreamProviderFamily<Service?, String> serviceByIdProvider =
    StreamProvider.family<Service?, String>(
  (ref, id) => ref.watch(serviceRepositoryProvider).watchService(id),
);

/// Live position of the chofer on one service. Null until a chofer is assigned
/// and has published a fix.
final StreamProviderFamily<ServiceTracking?, String> serviceTrackingProvider =
    StreamProvider.family<ServiceTracking?, String>(
  (ref, id) => ref.watch(serviceRepositoryProvider).watchTracking(id),
);

final StreamProviderFamily<List<ServiceEvent>, String> serviceEventsProvider =
    StreamProvider.family<List<ServiceEvent>, String>(
  (ref, id) => ref.watch(serviceRepositoryProvider).watchEvents(id),
);

final StreamProviderFamily<List<ChatMessage>, String> serviceMessagesProvider =
    StreamProvider.family<List<ChatMessage>, String>(
  (ref, id) => ref.watch(chatRepositoryProvider).watchMessages(id),
);

/// Messages on one service the signed-in user has not read yet — only the
/// other party's, never their own. Drives the chat badges.
final ProviderFamily<int, String> unreadMessageCountProvider =
    Provider.family<int, String>((ref, id) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return 0;
  final messages = ref.watch(serviceMessagesProvider(id)).value ?? const [];
  return messages.where((m) => !m.isMine(uid) && !m.isRead).length;
});

// ---------------------------------------------------------------------------
// Chat requests — talking to a nearby chofer before any job
// ---------------------------------------------------------------------------

/// Chat requests addressed to the signed-in chofer, newest first.
final driverChatRequestsProvider = StreamProvider<List<ChatRequest>>((ref) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return Stream.value(const []);
  return ref.watch(chatRequestRepositoryProvider).watchForDriver(uid);
});

/// Chat requests the signed-in customer has sent, newest first.
final clientChatRequestsProvider = StreamProvider<List<ChatRequest>>((ref) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return Stream.value(const []);
  return ref.watch(chatRequestRepositoryProvider).watchForClient(uid);
});

final StreamProviderFamily<ChatRequest?, String> chatRequestProvider =
    StreamProvider.family<ChatRequest?, String>(
  (ref, id) => ref.watch(chatRequestRepositoryProvider).watchRequest(id),
);

final StreamProviderFamily<List<ChatMessage>, String>
    chatRequestMessagesProvider = StreamProvider.family<List<ChatMessage>, String>(
  (ref, id) => ref.watch(chatRequestRepositoryProvider).watchMessages(id),
);

/// The other side's unread messages in one chat request's conversation.
final ProviderFamily<int, String> unreadChatRequestMessageCountProvider =
    Provider.family<int, String>((ref, id) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return 0;
  final messages = ref.watch(chatRequestMessagesProvider(id)).value ?? const [];
  return messages.where((m) => !m.isMine(uid) && !m.isRead).length;
});

/// Whether the *other* side is typing in one conversation, keyed by
/// [jobThreadKey] or [requestThreadKey]. Your own keystrokes never count.
final StreamProviderFamily<bool, String> otherTypingProvider =
    StreamProvider.family<bool, String>((ref, threadKey) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return Stream.value(false);
  return ref
      .watch(typingRepositoryProvider)
      .watchTyping(threadKey)
      .map((uids) => uids.any((typist) => typist != uid));
});

// ---------------------------------------------------------------------------
// Each person's own view of their conversations
// ---------------------------------------------------------------------------

/// What the signed-in person did to one conversation: cleared it, deleted it,
/// or neither.
final StreamProviderFamily<ChatThreadPrefs, String> chatThreadPrefsProvider =
    StreamProvider.family<ChatThreadPrefs, String>((ref, threadKey) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return Stream.value(ChatThreadPrefs.none);
  return ref
      .watch(chatPrefsRepositoryProvider)
      .watchThread(uid: uid, threadKey: threadKey);
});

/// The uids the signed-in person blocked.
final blockedUsersProvider = StreamProvider<Set<String>>((ref) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return Stream.value(const <String>{});
  return ref.watch(chatPrefsRepositoryProvider).watchBlocked(uid);
});

/// Whether the other person blocked the signed-in one, so their messages
/// would not arrive. Reads the one document that names them, never the list.
final StreamProviderFamily<bool, String> blockedByProvider =
    StreamProvider.family<bool, String>((ref, otherUid) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null || otherUid.isEmpty) return Stream.value(false);
  return ref
      .watch(chatPrefsRepositoryProvider)
      .watchBlockedBy(uid: uid, otherUid: otherUid);
});

/// Whether a conversation stays off this person's list: they deleted it, and
/// nothing has been said in it since.
///
/// Only a deleted conversation looks at its messages, so an untouched list
/// costs nothing extra to draw.
final ProviderFamily<bool, String> chatThreadHiddenProvider =
    Provider.family<bool, String>((ref, threadKey) {
  final prefs =
      ref.watch(chatThreadPrefsProvider(threadKey)).value ?? ChatThreadPrefs.none;
  if (!prefs.isDeleted) return false;

  const jobPrefix = 'job:';
  final messages = threadKey.startsWith(jobPrefix)
      ? ref.watch(serviceMessagesProvider(threadKey.substring(jobPrefix.length)))
            .value
      : ref
            .watch(
              chatRequestMessagesProvider(
                threadKey.substring('request:'.length),
              ),
            )
            .value;

  DateTime? lastAt;
  for (final message in messages ?? const <ChatMessage>[]) {
    final sentAt = message.sentAt;
    if (sentAt == null) continue;
    if (lastAt == null || sentAt.isAfter(lastAt)) lastAt = sentAt;
  }
  return !prefs.showsAgain(lastAt);
});

// ---------------------------------------------------------------------------
// Fleet — admin panel
// ---------------------------------------------------------------------------

final allDriversProvider = StreamProvider<List<Driver>>(
  (ref) => ref.watch(driverRepositoryProvider).watchAllDrivers(),
);

/// The customer roster. Staff-only — the rules refuse this query to a client.
final allClientsProvider = StreamProvider<List<AppUser>>(
  (ref) => ref.watch(userRepositoryProvider).watchAllClients(),
);

final liveDriverPositionsProvider = StreamProvider<List<DriverLivePosition>>(
  (ref) => ref.watch(driverRepositoryProvider).watchLivePositions(),
);

/// Ids of the choferes with the app open right now, for the roster's dot.
final connectedDriverIdsProvider = StreamProvider<Set<String>>(
  (ref) => ref.watch(driverRepositoryProvider).watchConnectedDriverIds(),
);

final activeServicesProvider = StreamProvider<List<Service>>(
  (ref) => ref.watch(serviceRepositoryProvider).watchActiveServices(),
);

final allTrucksProvider = StreamProvider<List<Truck>>(
  (ref) => ref.watch(truckRepositoryProvider).watchTrucks(),
);

// ---------------------------------------------------------------------------
// Earnings — driver app
// ---------------------------------------------------------------------------

final driverEarningsProvider = StreamProvider<EarningsSummary?>((ref) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return Stream.value(null);
  return ref.watch(earningsRepositoryProvider).watchSummary(uid);
});

/// Every chofer's cortes, newest first. The office's cash screen.
final cashSettlementsProvider = StreamProvider<List<CashSettlement>>(
  (ref) => ref.watch(earningsRepositoryProvider).watchCashSettlements(),
);

/// The cash jobs a chofer collected and no corte counted yet.
final StreamProviderFamily<List<Service>, String> uncountedCashProvider =
    StreamProvider.family<List<Service>, String>(
  (ref, driverId) =>
      ref.watch(earningsRepositoryProvider).watchUncountedCash(driverId),
);

/// The one open offer addressed to this chofer. Drives the ringing screen.
final incomingOfferProvider = StreamProvider<Offer?>((ref) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return Stream.value(null);
  return ref.watch(offerRepositoryProvider).watchIncomingOffer(uid);
});
