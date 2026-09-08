import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:firebase_database/firebase_database.dart';

import '../../domain/enums.dart';
import '../../domain/failures.dart';
import '../../domain/models/app_user.dart';
import '../../domain/models/billing.dart';
import '../../domain/models/dispatch_models.dart';
import '../../domain/models/driver.dart';
import '../../domain/models/remote_config_models.dart';
import '../../domain/models/service.dart';
import '../../domain/models/truck.dart';
import '../../domain/repositories.dart';
import '../paths.dart';

/// Firestore-backed repositories.
///
/// Every one satisfies the same contract as its demo counterpart, so switching
/// between them is a provider override and no screen changes. Two habits run
/// through all of them:
///
/// * **Nothing writes a governed field.** There is no method here that sets a
///   service's status, a driver's assignment or a quote. Those go through
///   `FirebaseFunctionsGateway`, where being a remote call that can fail is
///   visible at the call site.
/// * **Every query is bounded.** No `snapshots()` without a `limit` or an
///   equality filter that keeps the result set small. An unbounded listener on
///   `services` is a bill that grows with the business.

/// Maps a thrown Firebase error onto a [Failure] the UI already knows how to
/// render, so no screen ever has to interpret a plugin exception.
Failure _mapError(Object error) {
  if (error is fb.FirebaseAuthException) {
    return switch (error.code) {
      'invalid-verification-code' => const Failure(
          FailureCode.invalidInput,
          message: 'El código no es correcto. Revísalo e intenta de nuevo.',
        ),
      'session-expired' => const Failure(
          FailureCode.timeout,
          message: 'El código expiró. Pide uno nuevo.',
        ),
      'too-many-requests' => const Failure(
          FailureCode.invalidInput,
          message: 'Demasiados intentos. Espera unos minutos.',
        ),
      'quota-exceeded' => const Failure(
          FailureCode.unknown,
          message: 'No pudimos enviar el código. Intenta más tarde.',
        ),
      'invalid-phone-number' => const Failure(
          FailureCode.invalidInput,
          message: 'Ese número no parece válido.',
        ),
      'user-disabled' => const Failure(FailureCode.accountBlocked),
      'wrong-password' ||
      'invalid-credential' ||
      'user-not-found' =>
        const Failure(
          FailureCode.invalidInput,
          message: 'Usuario o contraseña incorrectos.',
        ),
      'network-request-failed' => const Failure(FailureCode.network),
      _ => Failure(FailureCode.unknown, cause: error),
    };
  }

  if (error is FirebaseException) {
    return switch (error.code) {
      'permission-denied' => const Failure(FailureCode.permissionDenied),
      'unauthenticated' => const Failure(FailureCode.unauthenticated),
      'not-found' => const Failure(FailureCode.notFound),
      'unavailable' || 'deadline-exceeded' => const Failure(FailureCode.network),
      _ => Failure(FailureCode.unknown, cause: error),
    };
  }

  if (error is TimeoutException) return const Failure(FailureCode.timeout);
  return Failure(FailureCode.unknown, cause: error);
}

/// Runs [action], turning any thrown Firebase error into a [Failure].
Future<Result<T>> _guard<T>(Future<T> Function() action) async {
  try {
    return Result.ok(await action());
  } on Object catch (error) {
    return Result.err(_mapError(error));
  }
}

// ---------------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------------

class FirebaseAuthRepository implements AuthRepository {
  FirebaseAuthRepository({fb.FirebaseAuth? auth})
      : _auth = auth ?? fb.FirebaseAuth.instance;

  final fb.FirebaseAuth _auth;

  /// Android can verify an SMS without the user typing anything. When that
  /// happens there is no code to confirm, so the credential is parked here and
  /// [confirmSmsCode] uses it instead of the digits.
  fb.PhoneAuthCredential? _autoRetrieved;

  @override
  String? get currentUserId => _auth.currentUser?.uid;

  @override
  Stream<String?> watchUserId() =>
      _auth.authStateChanges().map((user) => user?.uid);

  @override
  Future<UserRole> currentRole({bool forceRefresh = false}) async {
    final user = _auth.currentUser;
    if (user == null) return UserRole.unknown;
    final token = await user.getIdTokenResult(forceRefresh);
    return UserRole.fromWire(token.claims?['role'] as String?);
  }

  @override
  Future<Result<String>> startPhoneVerification(String e164Phone) {
    final completer = Completer<Result<String>>();

    void finish(Result<String> result) {
      if (!completer.isCompleted) completer.complete(result);
    }

    unawaited(
      _auth.verifyPhoneNumber(
        phoneNumber: e164Phone,
        verificationCompleted: (credential) => _autoRetrieved = credential,
        verificationFailed: (error) => finish(Result.err(_mapError(error))),
        codeSent: (verificationId, _) => finish(Result.ok(verificationId)),
        codeAutoRetrievalTimeout: (verificationId) =>
            finish(Result.ok(verificationId)),
        timeout: const Duration(seconds: 60),
      ),
    );

    return completer.future;
  }

  @override
  Future<Result<void>> confirmSmsCode({
    required String verificationId,
    required String smsCode,
  }) =>
      _guard(() async {
        final credential = _autoRetrieved ??
            fb.PhoneAuthProvider.credential(
              verificationId: verificationId,
              smsCode: smsCode,
            );
        _autoRetrieved = null;
        await _auth.signInWithCredential(credential);
      });

  @override
  Future<Result<void>> signInWithEmail(String email, String password) =>
      _guard(() => _auth.signInWithEmailAndPassword(
            email: email,
            password: password,
          ));

  @override
  Future<Result<void>> sendPasswordReset(String email) =>
      _guard(() => _auth.sendPasswordResetEmail(email: email));

  @override
  Future<Result<void>> changePassword(String newPassword) => _guard(() async {
        final user = _auth.currentUser;
        if (user == null) throw const Failure(FailureCode.unauthenticated);
        await user.updatePassword(newPassword);
      });

  @override
  Future<void> signOut() => _auth.signOut();
}

// ---------------------------------------------------------------------------
// Users
// ---------------------------------------------------------------------------

class FirestoreUserRepository implements UserRepository {
  const FirestoreUserRepository();

  @override
  Stream<AppUser?> watchUser(String uid) =>
      Paths.user(uid).snapshots().map((snap) => snap.data());

  @override
  Future<Result<AppUser>> fetchUser(String uid) => _guard(() async {
        final snap = await Paths.user(uid).get();
        final user = snap.data();
        if (user == null) throw const Failure(FailureCode.notFound);
        return user;
      });

  @override
  Future<Result<void>> updateProfile(
    String uid, {
    String? name,
    String? email,
    String? rnc,
    PaymentMethod? preferredPaymentMethod,
  }) =>
      // A map rather than the model: writing the whole document would touch
      // fields the security rules refuse, and the write would be rejected in
      // full rather than partially applied.
      _guard(() => Paths.user(uid).update({
            'name': ?name,
            'email': ?email,
            'rnc': ?rnc,
            if (preferredPaymentMethod != null)
              'preferredPaymentMethod': preferredPaymentMethod.wire,
            'updatedAt': FieldValue.serverTimestamp(),
          }));

  @override
  Future<Result<void>> registerFcmToken(
    String uid,
    String token,
    String platform,
  ) =>
      // Keyed by the token itself, so re-registering the same device is an
      // overwrite rather than a duplicate.
      _guard(() => Paths.userTokens(uid).doc(token).set({
            'platform': platform,
            'updatedAt': FieldValue.serverTimestamp(),
          }));

  @override
  Future<Result<void>> removeFcmToken(String uid, String token) =>
      _guard(() => Paths.userTokens(uid).doc(token).delete());
}

// ---------------------------------------------------------------------------
// Drivers and live positions
// ---------------------------------------------------------------------------

class FirebaseDriverRepository implements DriverRepository {
  FirebaseDriverRepository({FirebaseDatabase? database})
      : _database = database ?? FirebaseDatabase.instance;

  final FirebaseDatabase _database;

  @override
  Stream<Driver?> watchDriver(String uid) =>
      Paths.driver(uid).snapshots().map((snap) => snap.data());

  @override
  Stream<List<Driver>> watchAllDrivers({DriverStatus? status}) {
    var query = Paths.drivers().orderBy('name');
    if (status != null) query = query.where('status', isEqualTo: status.wire);
    // A tow company's fleet is tens of trucks, not thousands; the cap is here
    // so a data-entry accident cannot turn the roster into an unbounded read.
    return query.limit(500).snapshots().map(
          (snap) => snap.docs.map((d) => d.data()).toList(),
        );
  }

  @override
  Future<Result<Driver>> fetchDriver(String uid) => _guard(() async {
        final snap = await Paths.driver(uid).get();
        final driver = snap.data();
        if (driver == null) throw const Failure(FailureCode.notFound);
        return driver;
      });

  @override
  Stream<List<DriverDocument>> watchDocuments(String uid) =>
      Paths.driverDocuments(uid).snapshots().map(
            (snap) => snap.docs.map((d) => d.data()).toList(),
          );

  @override
  Future<void> publishLivePosition(DriverLivePosition position) =>
      Paths.live(position.driverId).set(position.toJson()..remove('driverId'));

  @override
  Future<Result<void>> setOnline(String uid, {required bool online}) =>
      _guard(() async {
        final ref = Paths.live(uid);

        if (online) {
          // Registered before the write, so a crashed app removes itself from
          // dispatch without waiting for the stale-position sweep.
          await ref.onDisconnect().update({
            'isOnline': false,
            'updatedAt': ServerValue.timestamp,
          });
        }

        await ref.update({
          'isOnline': online,
          'updatedAt': ServerValue.timestamp,
        });

        if (!online) await ref.onDisconnect().cancel();
      });

  @override
  Stream<List<DriverLivePosition>> watchLivePositions() =>
      // Only the online subtree: an admin panel does not need to stream the
      // whole fleet's history of last-known positions.
      _database
          .ref('live')
          .orderByChild('isOnline')
          .equalTo(true)
          .onValue
          .map((event) {
        final raw = event.snapshot.value;
        if (raw is! Map) return const <DriverLivePosition>[];

        return raw.entries
            .map((entry) {
              final value = entry.value;
              if (value is! Map) return null;
              return DriverLivePosition.fromJson({
                ...Map<String, dynamic>.from(value),
                'driverId': entry.key.toString(),
              });
            })
            .whereType<DriverLivePosition>()
            .toList();
      });
}

// ---------------------------------------------------------------------------
// Trucks
// ---------------------------------------------------------------------------

class FirestoreTruckRepository implements TruckRepository {
  const FirestoreTruckRepository();

  @override
  Stream<List<Truck>> watchTrucks({bool activeOnly = false}) {
    var query = Paths.trucks().orderBy('plate');
    if (activeOnly) query = query.where('active', isEqualTo: true);
    return query.limit(500).snapshots().map(
          (snap) => snap.docs.map((d) => d.data()).toList(),
        );
  }

  @override
  Stream<Truck?> watchTruck(String id) =>
      Paths.truck(id).snapshots().map((snap) => snap.data());

  @override
  Future<Result<Truck>> fetchTruck(String id) => _guard(() async {
        final snap = await Paths.truck(id).get();
        final truck = snap.data();
        if (truck == null) throw const Failure(FailureCode.notFound);
        return truck;
      });
}

// ---------------------------------------------------------------------------
// Services
// ---------------------------------------------------------------------------

class FirestoreServiceRepository implements ServiceRepository {
  const FirestoreServiceRepository();

  static final List<String> _activeWire =
      ServiceStatus.active.map((s) => s.wire).toList(growable: false);

  @override
  Stream<Service?> watchService(String id) =>
      Paths.service(id).snapshots().map((snap) => snap.data());

  @override
  Stream<Service?> watchActiveForClient(String clientId) => Paths.services()
      .where('clientId', isEqualTo: clientId)
      .where('status', whereIn: _activeWire)
      .orderBy('createdAt', descending: true)
      .limit(1)
      .snapshots()
      .map((snap) => snap.docs.isEmpty ? null : snap.docs.first.data());

  @override
  Stream<Service?> watchActiveForDriver(String driverId) => Paths.services()
      .where('driverId', isEqualTo: driverId)
      .where('status', whereIn: _activeWire)
      .orderBy('createdAt', descending: true)
      .limit(1)
      .snapshots()
      .map((snap) => snap.docs.isEmpty ? null : snap.docs.first.data());

  @override
  Stream<List<Service>> watchActiveServices() => Paths.services()
      .where('status', whereIn: _activeWire)
      .orderBy('createdAt')
      // A dispatcher who genuinely has 200 open jobs has a staffing problem,
      // not a pagination problem — but the cap keeps the listener bounded.
      .limit(200)
      .snapshots()
      .map((snap) => snap.docs.map((d) => d.data()).toList());

  @override
  Stream<List<ServiceEvent>> watchEvents(String serviceId) =>
      Paths.events(serviceId).orderBy('at').limit(100).snapshots().map(
            (snap) => snap.docs.map((d) => d.data()).toList(),
          );

  @override
  Stream<ServiceTracking?> watchTracking(String serviceId) =>
      Paths.trackingFor(serviceId).snapshots().map((snap) => snap.data());

  @override
  Future<Result<PagedServices>> fetchHistory({
    required String userId,
    required UserRole role,
    int limit = 20,
    Object? cursor,
  }) =>
      _guard(() async {
        var query = Paths.services()
            .where(
              role == UserRole.driver ? 'driverId' : 'clientId',
              isEqualTo: userId,
            )
            .orderBy('createdAt', descending: true)
            .limit(limit);

        // The cursor is the previous page's last snapshot. Callers treat it as
        // opaque, which is what lets the demo implementation use an int.
        if (cursor is DocumentSnapshot) {
          query = query.startAfterDocument(cursor);
        }

        final snap = await query.get();
        return PagedServices(
          items: snap.docs.map((d) => d.data()).toList(),
          cursor: snap.docs.isEmpty ? null : snap.docs.last,
          hasMore: snap.docs.length == limit,
        );
      });
}

class FirestoreOfferRepository implements OfferRepository {
  const FirestoreOfferRepository();

  @override
  Stream<Offer?> watchIncomingOffer(String driverId) =>
      // A collection-group query because an offer lives under the service it
      // belongs to, and the chofer does not know which service that is until
      // it arrives.
      FirebaseFirestore.instance
          .collectionGroup(Paths.offersSubcollection)
          .where('driverId', isEqualTo: driverId)
          .where('state', isEqualTo: OfferState.sent.wire)
          .limit(1)
          .snapshots()
          .map((snap) {
        if (snap.docs.isEmpty) return null;
        final doc = snap.docs.first;
        return Offer.fromJson({
          ...doc.data(),
          'driverId': doc.id,
          // services/{serviceId}/offers/{driverId}
          'serviceId': doc.reference.parent.parent?.id ?? '',
        });
      });

  @override
  Stream<Offer?> watchOffer(String serviceId, String driverId) =>
      Paths.offer(serviceId, driverId).snapshots().map((snap) => snap.data());
}

class FirestoreChatRepository implements ChatRepository {
  const FirestoreChatRepository();

  @override
  Stream<List<ChatMessage>> watchMessages(String serviceId, {int limit = 100}) =>
      Paths.messages(serviceId)
          .orderBy('sentAt')
          .limit(limit)
          .snapshots()
          .map((snap) => snap.docs.map((d) => d.data()).toList());

  @override
  Future<Result<void>> sendMessage({
    required String serviceId,
    required String senderId,
    required UserRole senderRole,
    required String text,
    required String clientMsgId,
  }) =>
      // Keyed by clientMsgId so a retry on bad signal overwrites rather than
      // duplicating. The field set matches the security rule exactly; anything
      // extra is rejected.
      _guard(() => Paths.messages(serviceId).doc(clientMsgId).set(
            ChatMessage(
              id: clientMsgId,
              senderId: senderId,
              senderRole: senderRole,
              text: text.trim(),
              clientMsgId: clientMsgId,
            ),
          ));

  @override
  Future<Result<void>> markRead(String serviceId, String readerId) =>
      _guard(() async {
        final unread = await Paths.messages(serviceId)
            .where('readAt', isNull: true)
            .limit(50)
            .get();

        final batch = FirebaseFirestore.instance.batch();
        for (final doc in unread.docs) {
          if (doc.data().senderId == readerId) continue;
          batch.update(doc.reference, {
            'readAt': FieldValue.serverTimestamp(),
          });
        }
        await batch.commit();
      });
}

// ---------------------------------------------------------------------------
// Money
// ---------------------------------------------------------------------------

class FirestoreEarningsRepository implements EarningsRepository {
  const FirestoreEarningsRepository();

  @override
  Stream<EarningsSummary?> watchSummary(String driverId) =>
      Paths.earningsSummary(driverId).snapshots().map((snap) => snap.data());

  @override
  Future<Result<List<EarningEntry>>> fetchEntries({
    required String driverId,
    required DateTime from,
    required DateTime to,
  }) =>
      _guard(() async {
        final snap = await Paths.earningEntries(driverId)
            .where('completedAt',
                isGreaterThanOrEqualTo: Timestamp.fromDate(from))
            .where('completedAt', isLessThan: Timestamp.fromDate(to))
            .orderBy('completedAt', descending: true)
            .limit(500)
            .get();
        return snap.docs.map((d) => d.data()).toList();
      });
}

class FirestoreInvoiceRepository implements InvoiceRepository {
  const FirestoreInvoiceRepository({required this.gateway});

  /// The signed URL comes from a callable, not from Storage directly — the
  /// bucket refuses client reads on purpose.
  final FunctionsGateway gateway;

  @override
  Future<Result<Invoice>> fetchInvoice(String invoiceId) => _guard(() async {
        final snap = await Paths.invoice(invoiceId).get();
        final invoice = snap.data();
        if (invoice == null) throw const Failure(FailureCode.notFound);
        return invoice;
      });

  @override
  Future<Result<String>> downloadUrl(String invoiceId) =>
      gateway.invoiceDownloadUrl(invoiceId);
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

class FirestoreConfigRepository implements ConfigRepository {
  const FirestoreConfigRepository();

  @override
  Stream<PricingConfig> watchPricing() => Paths.pricingConfig()
      .snapshots()
      .map((snap) => snap.data() ?? const PricingConfig());

  @override
  Stream<DispatchConfig> watchDispatch() => Paths.dispatchConfig()
      .snapshots()
      .map((snap) => snap.data() ?? const DispatchConfig());

  @override
  Stream<AppSettings> watchAppSettings() => Paths.appSettings()
      .snapshots()
      .map((snap) => snap.data() ?? const AppSettings());

  @override
  Future<AppSettings> currentAppSettings() async {
    // Defaults rather than a throw: a config document that has not been seeded
    // yet should not stop a customer requesting a tow.
    try {
      final snap = await Paths.appSettings().get();
      return snap.data() ?? const AppSettings();
    } on Object {
      return const AppSettings();
    }
  }
}
