import { onValueWritten } from 'firebase-functions/v2/database';
import { onDocumentCreated, onDocumentWritten } from 'firebase-functions/v2/firestore';
import { logger } from 'firebase-functions/v2';

import { needsDriverPhoto } from '../lib/chatRequests.js';
import { followPresence } from '../lib/presence.js';

import {
  DriverLiveState,
  PaymentMethod,
  ServiceStatus,
  UserRole,
} from '../lib/enums.js';
import { FieldValue, GeoPointOf, Paths, Timestamp } from '../lib/firestore.js';
import { bearing, type LatLng } from '../lib/geo.js';
import { commissionCents, loadPricing } from '../lib/pricing.js';
import { notify } from '../lib/push.js';
import { region } from '../callables/region.js';

/**
 * Background work that follows from a write.
 *
 * Three jobs live here, and each exists because doing it inline would be worse:
 * mirroring positions (so the customer subscribes to one document instead of
 * the fleet), writing the earnings ledger (so a retried completion cannot pay
 * twice), and chat notifications (so a message lands instantly and the push
 * follows).
 */

/**
 * Takes a chofer offline when their app closes.
 *
 * The app goes online by itself when it opens; this is the other half. A phone
 * cannot be trusted to say goodbye — a force-quit, a dead battery or a closed
 * browser tab runs no code at all — so the signal is the one the database
 * produces on its own: the `onDisconnect` the app queued on `/presence/{uid}`
 * fires when the connection closes, and flips `connected` to false.
 *
 * Two things it deliberately does not do:
 *
 * - **Act on a stale event.** A dropped signal and a reconnect a few seconds
 *   later arrive as two writes, and this trigger can run after the second. The
 *   node is read again, and if the app is back the chofer is left alone.
 * - **Take a chofer offline mid-tow.** The customer is watching that truck, and
 *   the `setOnline` callable refuses the same thing for the same reason. If the
 *   phone has really gone, `reapStaleDrivers` notices the silent position and
 *   tells the office.
 */
export const followAppPresence = onValueWritten(
  { ref: '/presence/{driverId}', region: 'us-central1' },
  async (event) => {
    const after = event.data.after.val() as { connected?: boolean } | null;
    if (after?.connected !== false) return;
    await followPresence(event.params['driverId'] as string);
  },
);

/**
 * Mirrors the assigned chofer's position into `tracking/{serviceId}`.
 *
 * The customer app must never read `/live` — that is the whole fleet, and
 * exposing it would let any customer watch every truck. Mirroring means one
 * document, readable by exactly the two parties to that service.
 *
 * Throttled to one Firestore write every eight seconds. The RTDB node updates
 * up to five times as often, and paying Firestore write costs for a position
 * that moved forty metres is how the bill grows faster than the business.
 */
export const mirrorLivePosition = onValueWritten(
  { ref: '/live/{driverId}', region: 'us-central1' },
  async (event) => {
    const after = event.data.after.val() as Record<string, unknown> | null;
    if (!after) return;

    const serviceId = after['serviceId'] as string | undefined;
    if (!serviceId || after['state'] !== DriverLiveState.onService) return;

    const trackingRef = Paths.tracking(serviceId);
    const existing = await trackingRef.get();
    const lastAt = (existing.data()?.['updatedAt'] as FirebaseFirestore.Timestamp | undefined)
      ?.toMillis();

    const now = Date.now();
    if (lastAt && now - lastAt < 8000) return;

    const before = event.data.before.val() as Record<string, unknown> | null;
    const position: LatLng = {
      latitude: after['lat'] as number,
      longitude: after['lng'] as number,
    };

    // Prefer the device's own heading; fall back to the direction of travel,
    // because a parked truck reports 0 and the marker would snap north.
    const heading =
      (after['heading'] as number | undefined) ||
      (before
        ? bearing(
            { latitude: before['lat'] as number, longitude: before['lng'] as number },
            position,
          )
        : 0);

    await trackingRef.set(
      {
        driverId: event.params['driverId'],
        position: GeoPointOf(position),
        heading,
        speedKmh: (after['speedKmh'] as number | undefined) ?? 0,
        updatedAt: Timestamp.fromMillis(now),
      },
      { merge: true },
    );
  },
);

/**
 * Writes the earnings entry when a service completes.
 *
 * Keyed by service id, so a retried trigger overwrites rather than paying the
 * chofer twice — Firestore triggers are at-least-once, and money is exactly the
 * place where that matters.
 *
 * The direction of the money is the subtle part. On a card job the company
 * holds the customer's payment and owes the chofer their net. On a cash job the
 * chofer holds it and owes the company its commission. Same entry, opposite
 * sign, and `cashOwedCents` is the number the office actually chases.
 */
export const recordEarnings = onDocumentWritten(
  { document: 'services/{serviceId}', region },
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!after) return;

    const becameCompleted =
      before?.['status'] !== ServiceStatus.completed &&
      after['status'] === ServiceStatus.completed;
    if (!becameCompleted) return;

    const driverId = after['driverId'] as string | undefined;
    if (!driverId) {
      logger.warn('earnings.noDriver', { serviceId: event.params['serviceId'] });
      return;
    }

    const serviceId = event.params['serviceId'];
    const pricing = await loadPricing();

    const gross =
      ((after['final'] as Record<string, unknown> | undefined)?.['totalCents'] as number) ??
      ((after['quote'] as Record<string, unknown> | undefined)?.['totalCents'] as number) ??
      0;
    const commission = commissionCents(pricing, gross);
    const net = gross - commission;
    const method = ((after['payment'] as Record<string, unknown>)['method'] as string) ??
      PaymentMethod.cash;
    const isCash = method === PaymentMethod.cash;

    const entryRef = Paths.earningEntry(driverId, serviceId);
    const existing = await entryRef.get();
    if (existing.exists) {
      logger.debug('earnings.alreadyRecorded', { serviceId, driverId });
      return;
    }

    await entryRef.set({
      serviceId,
      driverId,
      serviceCode: after['code'] ?? '',
      grossCents: gross,
      commissionCents: commission,
      netCents: net,
      method,
      pickupAddress:
        ((after['pickup'] as Record<string, unknown>)['address'] as string) ?? '',
      dropoffAddress:
        ((after['dropoff'] as Record<string, unknown> | undefined)?.['address'] as string) ??
        '',
      settled: false,
      completedAt: FieldValue.serverTimestamp(),
    });

    await Paths.earnings(driverId).set(
      {
        driverId,
        todayGrossCents: FieldValue.increment(gross),
        todayNetCents: FieldValue.increment(net),
        todayServices: FieldValue.increment(1),
        weekGrossCents: FieldValue.increment(gross),
        weekNetCents: FieldValue.increment(net),
        weekServices: FieldValue.increment(1),
        monthGrossCents: FieldValue.increment(gross),
        monthNetCents: FieldValue.increment(net),
        monthServices: FieldValue.increment(1),
        lifetimeNetCents: FieldValue.increment(net),
        // Only cash creates a debt; on a card job the company already has the
        // money and owes the chofer.
        ...(isCash ? { cashOwedCents: FieldValue.increment(commission) } : {}),
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    if (isCash) {
      await Paths.driver(driverId).update({
        cashOwedCents: FieldValue.increment(commission),
      });
    }

    logger.info('earnings.recorded', { serviceId, driverId, gross, net, method });
  },
);

/**
 * Notifies the other party about a chat message.
 *
 * Messages are written straight from the app so they land instantly; this only
 * carries the push. It reads the service to decide who the recipient is, which
 * is one extra read per message and the reason the sender's own role is stored
 * on the message rather than inferred here.
 */
export const notifyOnMessage = onDocumentCreated(
  { document: 'services/{serviceId}/messages/{messageId}', region },
  async (event) => {
    const message = event.data?.data();
    if (!message) return;

    const serviceId = event.params['serviceId'];
    const snap = await Paths.service(serviceId).get();
    const service = snap.data();
    if (!service) return;

    const senderId = message['senderId'] as string;
    const clientId = service['clientId'] as string | undefined;
    const driverId = service['driverId'] as string | undefined;

    const isFromClient = senderId === clientId;
    const recipientId = isFromClient ? driverId : clientId;
    if (!recipientId) return;

    // Denormalised so the app can badge the conversation without counting
    // unread documents on every render.
    await Paths.service(serviceId).update({
      [isFromClient ? 'unreadForDriver' : 'unreadForClient']: FieldValue.increment(1),
    });

    await notify({
      uid: recipientId,
      audience: isFromClient ? 'driver' : 'client',
      title: isFromClient
        ? (service['clientName'] as string) || 'Cliente'
        : (service['driverName'] as string) || 'Chofer',
      body: (message['text'] as string) ?? '',
      data: { serviceId, type: 'chat' },
      channel: 'chat',
    });
  },
);

/**
 * The same, for a conversation opened from a nearby truck before any job.
 * The request document says who the two sides are.
 */
export const notifyOnChatRequestMessage = onDocumentCreated(
  { document: 'chatRequests/{requestId}/messages/{messageId}', region },
  async (event) => {
    const message = event.data?.data();
    if (!message) return;

    const requestId = event.params['requestId'];
    const chat = (await Paths.chatRequest(requestId).get()).data();
    if (!chat) return;

    // A conversation accepted before the answer carried the chofer's photo
    // never gets its document written again, so the customer would go on
    // seeing a grey initial for as long as they talked. The first message
    // through here fills it in.
    if (needsDriverPhoto(chat)) {
      const driver = (await Paths.driver(chat['driverId'] as string).get()).data();
      const photoUrl = (driver?.['photoUrl'] as string | undefined) ?? '';
      if (photoUrl) {
        await Paths.chatRequest(requestId).update({ driverPhotoUrl: photoUrl });
        logger.info('chatRequest.photoBackfilled', { requestId });
      }
    }

    const isFromClient = message['senderId'] === chat['clientId'];
    const recipientId = (isFromClient ? chat['driverId'] : chat['clientId']) as
      | string
      | undefined;
    if (!recipientId) return;

    await notify({
      uid: recipientId,
      audience: isFromClient ? 'driver' : 'client',
      title: isFromClient
        ? (chat['clientName'] as string) || 'Cliente'
        : (chat['driverName'] as string) || 'Chofer',
      body: (message['text'] as string) ?? '',
      data: { requestId, type: 'chat_request_message' },
      channel: 'chat',
    });
  },
);

/**
 * Fills in the chofer's photo on an accepted conversation that has none.
 *
 * The answer itself copies the photo across, so this only ever fires for a
 * conversation accepted before that existed, or one whose chofer set their
 * photo afterwards. Writing back to the same document re-runs this trigger
 * once, and the second pass sees the photo and stops.
 */
export const backfillChatRequestPhoto = onDocumentWritten(
  { document: 'chatRequests/{requestId}', region },
  async (event) => {
    const after = event.data?.after;
    const request = after?.data();
    if (!after || !request || !needsDriverPhoto(request)) return;

    const driver = (await Paths.driver(request['driverId'] as string).get()).data();
    const photoUrl = (driver?.['photoUrl'] as string | undefined) ?? '';
    if (!photoUrl) return;

    await after.ref.update({ driverPhotoUrl: photoUrl });
    logger.info('chatRequest.photoBackfilled', {
      requestId: event.params['requestId'],
    });
  },
);
