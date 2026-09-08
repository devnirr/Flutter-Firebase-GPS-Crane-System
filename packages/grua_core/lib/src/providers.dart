import 'package:flutter_riverpod/flutter_riverpod.dart';
// Riverpod 3 keeps `Override` out of the default export surface.
import 'package:flutter_riverpod/misc.dart' show Override, StreamProviderFamily;

import 'config/app_config.dart';
import 'data/demo/demo_backend.dart';
import 'data/demo/demo_repositories.dart';
import 'domain/enums.dart';
import 'domain/models/app_user.dart';
import 'domain/models/billing.dart';
import 'domain/models/dispatch_models.dart';
import 'domain/models/driver.dart';
import 'domain/models/remote_config_models.dart';
import 'domain/models/service.dart';
import 'domain/models/truck.dart';
import 'domain/repositories.dart';

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

final offerRepositoryProvider = Provider<OfferRepository>(
  (ref) => throw UnimplementedError('offerRepositoryProvider must be overridden'),
);

final chatRepositoryProvider = Provider<ChatRepository>(
  (ref) => throw UnimplementedError('chatRepositoryProvider must be overridden'),
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
    chatRepositoryProvider.overrideWithValue(DemoChatRepository(instance)),
    earningsRepositoryProvider
        .overrideWithValue(DemoEarningsRepository(instance)),
    invoiceRepositoryProvider.overrideWithValue(DemoInvoiceRepository(instance)),
    configRepositoryProvider.overrideWithValue(DemoConfigRepository(instance)),
    functionsGatewayProvider
        .overrideWithValue(DemoFunctionsGateway(instance)),
  ];
}

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

/// The signed-in customer's profile.
final currentUserProvider = StreamProvider<AppUser?>((ref) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return Stream.value(null);
  return ref.watch(userRepositoryProvider).watchUser(uid);
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

// ---------------------------------------------------------------------------
// Fleet — admin panel
// ---------------------------------------------------------------------------

final allDriversProvider = StreamProvider<List<Driver>>(
  (ref) => ref.watch(driverRepositoryProvider).watchAllDrivers(),
);

final liveDriverPositionsProvider = StreamProvider<List<DriverLivePosition>>(
  (ref) => ref.watch(driverRepositoryProvider).watchLivePositions(),
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

/// The one open offer addressed to this chofer. Drives the ringing screen.
final incomingOfferProvider = StreamProvider<Offer?>((ref) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return Stream.value(null);
  return ref.watch(offerRepositoryProvider).watchIncomingOffer(uid);
});
