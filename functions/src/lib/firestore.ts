import { getApps, initializeApp } from 'firebase-admin/app';
import { FieldValue, GeoPoint, Timestamp, getFirestore } from 'firebase-admin/firestore';
import { getDatabase } from 'firebase-admin/database';

/**
 * Admin SDK access and typed paths.
 *
 * Every collection name in the backend appears here and nowhere else, matching
 * `packages/grua_core/lib/src/data/paths.dart`. A typo in `'sevices'` is a
 * silent empty result that looks like a permissions problem for an afternoon.
 */

// Functions can cold-start more than once per instance; initializing twice
// throws.
if (getApps().length === 0) initializeApp();

export const db = getFirestore();
export { FieldValue, GeoPoint, Timestamp };

/**
 * The Realtime Database, connected on first use.
 *
 * `getDatabase()` throws when it cannot determine a database URL, and doing
 * that at module load means importing a path helper — or a pure pricing
 * function two imports away — fails on any machine without live Firebase
 * config. Connecting lazily keeps the logic tests runnable with no emulator.
 */
let cachedRtdb: ReturnType<typeof getDatabase> | undefined;

export function rtdb(): ReturnType<typeof getDatabase> {
  cachedRtdb ??= getDatabase();
  return cachedRtdb;
}

/** Builds a Firestore GeoPoint from the plain shape the geo helpers use. */
export const GeoPointOf = (point: { latitude: number; longitude: number }): GeoPoint =>
  new GeoPoint(point.latitude, point.longitude);

export const Collections = {
  users: 'users',
  drivers: 'drivers',
  trucks: 'trucks',
  trucksByPlate: 'trucks_by_plate',
  services: 'services',
  tracking: 'tracking',
  invoices: 'invoices',
  earnings: 'earnings',
  config: 'config',
  reports: 'reports',
  audit: 'audit',
  chatRequests: 'chatRequests',
  calls: 'calls',
  cashSettlements: 'cashSettlements',
} as const;

export const Sub = {
  offers: 'offers',
  messages: 'messages',
  events: 'events',
  documents: 'documents',
  entries: 'entries',
  tokens: 'tokens',
  notifications: 'notifications',
} as const;

export const Paths = {
  user: (uid: string) => db.collection(Collections.users).doc(uid),
  userTokens: (uid: string) =>
    db.collection(Collections.users).doc(uid).collection(Sub.tokens),
  userNotifications: (uid: string) =>
    db.collection(Collections.users).doc(uid).collection(Sub.notifications),

  drivers: () => db.collection(Collections.drivers),
  driver: (uid: string) => db.collection(Collections.drivers).doc(uid),
  driverTokens: (uid: string) =>
    db.collection(Collections.drivers).doc(uid).collection(Sub.tokens),
  driverDocuments: (uid: string) =>
    db.collection(Collections.drivers).doc(uid).collection(Sub.documents),

  trucks: () => db.collection(Collections.trucks),
  truck: (id: string) => db.collection(Collections.trucks).doc(id),
  truckByPlate: (plate: string) =>
    db.collection(Collections.trucksByPlate).doc(plate.toUpperCase()),

  services: () => db.collection(Collections.services),
  service: (id: string) => db.collection(Collections.services).doc(id),
  offers: (serviceId: string) =>
    db.collection(Collections.services).doc(serviceId).collection(Sub.offers),
  offer: (serviceId: string, driverId: string) =>
    db
      .collection(Collections.services)
      .doc(serviceId)
      .collection(Sub.offers)
      .doc(driverId),
  events: (serviceId: string) =>
    db.collection(Collections.services).doc(serviceId).collection(Sub.events),
  messages: (serviceId: string) =>
    db.collection(Collections.services).doc(serviceId).collection(Sub.messages),

  chatRequests: () => db.collection(Collections.chatRequests),
  chatRequest: (id: string) => db.collection(Collections.chatRequests).doc(id),
  calls: () => db.collection(Collections.calls),
  call: (id: string) => db.collection(Collections.calls).doc(id),
  chatRequestMessages: (id: string) =>
    db.collection(Collections.chatRequests).doc(id).collection(Sub.messages),

  tracking: (serviceId: string) =>
    db.collection(Collections.tracking).doc(serviceId),

  invoice: (id: string) => db.collection(Collections.invoices).doc(id),
  earnings: (driverId: string) =>
    db.collection(Collections.earnings).doc(driverId),
  earningEntry: (driverId: string, serviceId: string) =>
    db
      .collection(Collections.earnings)
      .doc(driverId)
      .collection(Sub.entries)
      .doc(serviceId),

  pricingConfig: () => db.collection(Collections.config).doc('pricing'),
  dispatchConfig: () => db.collection(Collections.config).doc('dispatch'),
  appSettings: () => db.collection(Collections.config).doc('app'),
  ncfConfig: () => db.collection(Collections.config).doc('ncf'),

  audit: () => db.collection(Collections.audit),
  cashSettlements: () => db.collection(Collections.cashSettlements),

  live: (driverId: string) => rtdb().ref(`live/${driverId}`),
  liveRoot: () => rtdb().ref('live'),
  /** Whether the chofer's app is open; written by the app, cleared by onDisconnect. */
  presence: (driverId: string) => rtdb().ref(`presence/${driverId}`),
} as const;

/** Storage object paths. Storage is addressed by string, not by reference. */
export const StoragePaths = {
  invoicePdf: (invoiceId: string) => `invoices/${invoiceId}.pdf`,
  servicePhoto: (serviceId: string, name: string) =>
    `service_photos/${serviceId}/${name}`,
  driverDoc: (uid: string, docType: string, ext: string) =>
    `drivers/${uid}/docs/${docType}_${Date.now()}.${ext}`,
} as const;
