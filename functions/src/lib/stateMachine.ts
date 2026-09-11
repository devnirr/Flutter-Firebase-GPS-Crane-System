import { logger } from 'firebase-functions/v2';

import {
  ServiceEventName,
  ServiceStatus,
  TERMINAL_STATUSES,
  UserRole,
} from './enums.js';
import { Code, precondition } from './errors.js';
import { FieldValue, Paths, Timestamp, db } from './firestore.js';

/**
 * The service state machine.
 *
 * Eleven states, one table, one function that applies them. Every callable that
 * moves a service goes through `applyTransition` — hand-rolling the guard in
 * eleven places is how a service ends up stuck in `arrived` forever with no
 * record of why.
 *
 * Three rules hold throughout:
 *
 * 1. **The transaction re-reads the service.** The status the caller saw when
 *    they tapped is not evidence of anything by the time the write lands. Two
 *    choferes accepting 50 ms apart both read `offered`; only one may commit.
 * 2. **No network inside the transaction.** Pushes, Cloud Tasks and gateway
 *    calls run after commit, because a transaction that retries would fire them
 *    twice and Firestore retries transactions freely.
 * 3. **Every accepted transition appends an event.** That log is the audit
 *    trail, the timeline the panel renders, and the only way to reconstruct
 *    what happened on a disputed job.
 */

/** Who is allowed to trigger a transition. */
export type Actor = UserRole | 'system';

export interface TransitionContext {
  serviceId: string;
  service: FirebaseFirestore.DocumentData;
  actorId: string;
  actorRole: Actor;
  meta: Record<string, unknown>;
  transaction: FirebaseFirestore.Transaction;
}

export interface Transition {
  event: ServiceEventName;
  from: readonly ServiceStatus[];
  to: ServiceStatus;
  actors: readonly Actor[];
  /**
   * Extra conditions, run inside the transaction after the status check.
   * Throws an `HttpsError` carrying the specific code the app switches on.
   */
  guard?: (ctx: TransitionContext) => void | Promise<void>;
  /** Fields merged into the service alongside the status change. */
  patch?: (ctx: TransitionContext) => Record<string, unknown>;
}

const t = (transition: Transition): Transition => transition;

/**
 * The full table. This is the specification; `prompt.md` documents the same
 * rows in prose and the two must agree.
 */
export const TRANSITIONS: readonly Transition[] = [
  t({
    event: ServiceEventName.requestService,
    from: [],
    to: ServiceStatus.pendingDispatch,
    actors: [UserRole.client],
  }),

  t({
    event: ServiceEventName.dispatchNext,
    from: [ServiceStatus.pendingDispatch],
    to: ServiceStatus.offered,
    actors: ['system'],
  }),

  t({
    event: ServiceEventName.acceptService,
    from: [ServiceStatus.offered, ServiceStatus.pendingDispatch],
    to: ServiceStatus.accepted,
    actors: [UserRole.driver],
  }),

  t({
    event: ServiceEventName.rejectService,
    from: [ServiceStatus.offered],
    to: ServiceStatus.pendingDispatch,
    actors: [UserRole.driver, 'system'],
  }),

  t({
    event: ServiceEventName.expireOffer,
    from: [ServiceStatus.offered],
    to: ServiceStatus.pendingDispatch,
    actors: ['system'],
  }),

  t({
    event: ServiceEventName.noDriversFound,
    from: [ServiceStatus.pendingDispatch, ServiceStatus.offered],
    to: ServiceStatus.needsManual,
    actors: ['system'],
  }),

  t({
    event: ServiceEventName.assignServiceManually,
    from: [
      ServiceStatus.pendingDispatch,
      ServiceStatus.offered,
      ServiceStatus.needsManual,
    ],
    to: ServiceStatus.accepted,
    actors: [UserRole.admin, UserRole.ops],
  }),

  t({
    event: ServiceEventName.markArrived,
    from: [ServiceStatus.accepted],
    to: ServiceStatus.arrived,
    actors: [UserRole.driver, UserRole.admin, UserRole.ops],
    patch: () => ({ 'timeline.arrivedAt': FieldValue.serverTimestamp() }),
  }),

  t({
    event: ServiceEventName.startService,
    from: [ServiceStatus.arrived],
    to: ServiceStatus.inProgress,
    actors: [UserRole.driver, UserRole.admin, UserRole.ops],
    guard: ({ service }) => {
      // A card job may not start until the hold is in place. Starting without
      // one means towing a vehicle with no way to charge for it.
      const payment = service['payment'] as Record<string, unknown> | undefined;
      if (payment?.['method'] === 'card' && payment['status'] !== 'authorized') {
        throw precondition(
          Code.blockedPayment,
          'El pago no está autorizado todavía. Pídele al cliente que lo ' +
            'corrija o cambia a efectivo.',
        );
      }
    },
    patch: () => ({ 'timeline.startedAt': FieldValue.serverTimestamp() }),
  }),

  t({
    event: ServiceEventName.completeService,
    from: [ServiceStatus.inProgress],
    to: ServiceStatus.completed,
    actors: [UserRole.driver, UserRole.admin, UserRole.ops],
    patch: () => ({ 'timeline.completedAt': FieldValue.serverTimestamp() }),
  }),

  t({
    event: ServiceEventName.confirmCashCollected,
    from: [ServiceStatus.completed],
    to: ServiceStatus.closed,
    actors: [UserRole.driver, UserRole.admin, UserRole.ops],
    patch: () => ({
      'payment.status': 'cash_collected',
      'payment.cashCollectedAt': FieldValue.serverTimestamp(),
      'timeline.closedAt': FieldValue.serverTimestamp(),
    }),
  }),

  t({
    event: ServiceEventName.closeService,
    from: [ServiceStatus.completed],
    to: ServiceStatus.closed,
    actors: ['system', UserRole.admin],
    patch: () => ({ 'timeline.closedAt': FieldValue.serverTimestamp() }),
  }),

  t({
    event: ServiceEventName.cancelService,
    from: [
      ServiceStatus.pendingDispatch,
      ServiceStatus.offered,
      ServiceStatus.needsManual,
      ServiceStatus.accepted,
      ServiceStatus.arrived,
    ],
    to: ServiceStatus.cancelled,
    actors: [UserRole.client, UserRole.admin, UserRole.ops],
    patch: () => ({ 'timeline.cancelledAt': FieldValue.serverTimestamp() }),
  }),

  t({
    event: ServiceEventName.cancelByDriver,
    from: [ServiceStatus.accepted, ServiceStatus.arrived],
    // Back into the pool rather than cancelled: the customer still needs a tow.
    to: ServiceStatus.pendingDispatch,
    actors: [UserRole.driver],
  }),

  t({
    event: ServiceEventName.failService,
    from: [...ACTIVE_EXCEPT_TERMINAL()],
    to: ServiceStatus.failed,
    actors: ['system', UserRole.admin],
    patch: () => ({ 'timeline.cancelledAt': FieldValue.serverTimestamp() }),
  }),
];

function ACTIVE_EXCEPT_TERMINAL(): ServiceStatus[] {
  return Object.values(ServiceStatus).filter(
    (s) => !TERMINAL_STATUSES.includes(s),
  );
}

const BY_EVENT = new Map<ServiceEventName, Transition>(
  TRANSITIONS.map((transition) => [transition.event, transition]),
);

export function transitionFor(event: ServiceEventName): Transition {
  const transition = BY_EVENT.get(event);
  if (!transition) throw new Error(`No transition defined for '${event}'`);
  return transition;
}

/** Work to run after the transaction commits. */
export type AfterCommit = () => Promise<void>;

export interface ApplyOptions {
  serviceId: string;
  event: ServiceEventName;
  actorId: string;
  actorRole: Actor;
  meta?: Record<string, unknown>;
  /** Extra fields to write, merged over the transition's own patch. */
  patch?: Record<string, unknown>;
  /**
   * Additional reads and writes inside the same transaction — freeing a chofer,
   * marking an offer accepted. Anything that must be atomic with the status
   * change belongs here rather than in a follow-up write.
   */
  inTransaction?: (ctx: TransitionContext) => void | Promise<void>;
  /** Pushes, tasks and gateway calls. Run once, after commit. */
  afterCommit?: (ctx: { service: FirebaseFirestore.DocumentData }) => Promise<void>;
}

export interface ApplyResult {
  from: ServiceStatus;
  to: ServiceStatus;
  service: FirebaseFirestore.DocumentData;
}

/**
 * Moves a service, or refuses with a code the app can act on.
 *
 * The whole point is that the status check happens *inside* the transaction, on
 * a fresh read. Everything a caller thought it knew before entering is
 * hearsay.
 */
export async function applyTransition(options: ApplyOptions): Promise<ApplyResult> {
  const {
    serviceId,
    event,
    actorId,
    actorRole,
    meta = {},
    patch: extraPatch,
    inTransaction,
    afterCommit,
  } = options;

  const transition = transitionFor(event);

  if (!transition.actors.includes(actorRole)) {
    throw precondition(
      Code.invalidTransition,
      'No puedes hacer ese cambio en el servicio.',
      { event, actorRole },
    );
  }

  const serviceRef = Paths.service(serviceId);
  let result: ApplyResult | undefined;

  await db.runTransaction(async (transaction) => {
    const snap = await transaction.get(serviceRef);
    const service = snap.data();

    if (!service) {
      throw precondition(Code.notFound, 'Este servicio ya no existe.');
    }

    const from = service['status'] as ServiceStatus;

    if (!transition.from.includes(from)) {
      // Being specific here is what lets the chofer app tell "otro chofer lo
      // tomó" apart from "la oferta expiró".
      throw preconditionForRejectedTransition(event, from);
    }

    const ctx: TransitionContext = {
      serviceId,
      service,
      actorId,
      actorRole,
      meta,
      transaction,
    };

    await transition.guard?.(ctx);

    const update: Record<string, unknown> = {
      status: transition.to,
      updatedAt: FieldValue.serverTimestamp(),
      ...(transition.patch?.(ctx) ?? {}),
      ...(extraPatch ?? {}),
    };

    transaction.update(serviceRef, update);

    transaction.create(Paths.events(serviceId).doc(), {
      event,
      from,
      to: transition.to,
      actorId,
      actorRole,
      meta,
      at: FieldValue.serverTimestamp(),
    });

    await inTransaction?.(ctx);

    result = { from, to: transition.to, service };
  });

  if (!result) throw new Error('Transaction completed without a result');

  logger.info('service.transition', {
    serviceId,
    event,
    from: result.from,
    to: result.to,
    actorId,
    actorRole,
  });

  // Outside the transaction on purpose: Firestore retries transactions, and a
  // push sent inside one can be delivered several times.
  if (afterCommit) {
    try {
      await afterCommit({ service: result.service });
    } catch (error) {
      // The state change already committed and is correct. A failed
      // notification must not surface as a failed action to the user.
      logger.error('service.afterCommit failed', { serviceId, event, error });
    }
  }

  return result;
}

/** Turns a rejected transition into the most specific message available. */
function preconditionForRejectedTransition(
  event: ServiceEventName,
  from: ServiceStatus,
): Error {
  if (event === ServiceEventName.acceptService) {
    if (from === ServiceStatus.accepted || from === ServiceStatus.arrived) {
      return precondition(Code.alreadyTaken, 'Otro chofer tomó el servicio.', {
        from,
      });
    }
    if (TERMINAL_STATUSES.includes(from)) {
      return precondition(Code.alreadyTaken, 'Este servicio ya no está disponible.', {
        from,
      });
    }
  }

  if (
    event === ServiceEventName.cancelService &&
    from === ServiceStatus.inProgress
  ) {
    return precondition(
      Code.invalidTransition,
      'El vehículo ya va en la grúa. Llama a la oficina para cancelar.',
      { from },
    );
  }

  return precondition(
    Code.invalidTransition,
    'Ese paso ya no aplica. Actualiza la pantalla.',
    { event, from },
  );
}
