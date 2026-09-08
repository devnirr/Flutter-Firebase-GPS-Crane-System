# Grúa RD — Build Playbook

**42 sequenced prompts that build two Flutter apps and one Flutter Web panel on a single Firebase backend.**

Servicio de grúas 24/7 · República Dominicana

| | |
|---|---|
| **Deliverables** | 3 — client app · driver app (chofer) · admin web |
| **Phases** | 11, strictly ordered |
| **Prompts** | 42, one branch each |
| **Service states** | 11, server-enforced |
| **Currency** | DOP · ITBIS 18% · NCF |
| **Timezone** | America/Santo_Domingo (UTC-4, no DST) |

---

## Table of contents

- [How to use this playbook](#how-to-use-this-playbook)
- [Architecture](#architecture)
- [Firestore schema](#firestore-schema)
- [Service state machine](#service-state-machine)
- [Dispatch algorithm](#dispatch-algorithm)
- [Phase 0 — Cimientos](#phase-0--cimientos)
- [Phase 1 — Modelo de datos](#phase-1--modelo-de-datos)
- [Phase 2 — Auth y roles](#phase-2--auth-y-roles)
- [Phase 3 — Solicitud del cliente](#phase-3--solicitud-del-cliente)
- [Phase 4 — Motor de despacho](#phase-4--motor-de-despacho)
- [Phase 5 — App chofer](#phase-5--app-chofer)
- [Phase 6 — Tracking, chat y llamadas](#phase-6--tracking-chat-y-llamadas)
- [Phase 7 — Pagos y facturación](#phase-7--pagos-y-facturación)
- [Phase 8 — Panel admin](#phase-8--panel-admin)
- [Phase 9 — Reportes](#phase-9--reportes)
- [Phase 10 — Endurecimiento y release](#phase-10--endurecimiento-y-release)
- [Sequencing and risk](#sequencing-and-risk)

---

## How to use this playbook

Each prompt is one unit of work: one branch, one commit, one review. Run them **in order** — the dependency chain is real, and prompts in Phase 5 assume the callables from Phase 4 exist.

1. **Prompt 0.3 first, always.** It writes `CLAUDE.md` at the repo root containing the schema, the state machine, and the conventions from this document. Every later prompt inherits it automatically, which is why the prompts below can stay short.
2. **Prepend the context header** (below) to any prompt you run in a fresh session or in a tool that does not read `CLAUDE.md`.
3. **Never let a prompt invent schema.** If an agent proposes a field that is not in `CLAUDE.md`, make it amend `CLAUDE.md` in the same commit. The spec is the source of truth, not the code.
4. **Run against the emulator suite** (Prompt 0.4) before any cloud deploy. The dispatch engine is the part most likely to be subtly wrong, and it is only cheap to test locally.
5. **Tick each prompt off** in the checklist at the end of this file as you land it.

### Context header — paste above any prompt

```
Project: Grúa RD — 24/7 tow-truck dispatch for the Dominican Republic.
Monorepo: Flutter (client app, driver app, admin web) + Firebase (Auth,
Firestore, Functions v2 in TypeScript, Storage, FCM) + Google Maps/Routes
+ Stripe. Currency DOP, timezone America/Santo_Domingo, UI language es-DO.

Read /CLAUDE.md before writing code. It holds the Firestore schema, the
service state machine, and the naming conventions. Do not invent fields or
states; if you need one, amend CLAUDE.md in the same commit and say so.

Rules that never change:
- Service status transitions happen ONLY inside Cloud Functions callables.
  Clients never write `status`, `driverId`, `quote`, or `payment`.
- Money is stored as integer cents (DOP). Never floats.
- All timestamps are Firestore Timestamps in UTC; format for display in
  America/Santo_Domingo.
- Every callable validates App Check, auth, role, and input with zod.
- Write tests against the Firebase emulator suite for anything you add.
```

### ⚠️ Your screens already exist

Do not let these prompts regenerate them. Add to each UI-touching prompt:

> *"The screens already exist under `lib/features/…`. Wire the existing widgets to the new controllers; do not create new screens or change the visual design. If a widget is missing a callback or state field it needs, add only that."*

---

## Architecture

One Firebase project per environment (`dev`, `stg`, `prod`), one monorepo, one shared Dart package. The three apps are thin: nearly all business logic lives in Cloud Functions, because the client and driver apps are both untrusted and both have a financial incentive to lie about state.

```
grua_rd/
├── melos.yaml
├── CLAUDE.md                  # spec of record — schema + state machine
├── packages/
│   └── grua_core/             # models, repos, paths, theme, l10n, DI, result types
├── apps/
│   ├── client_app/            # Android + iOS  — phone OTP
│   ├── driver_app/            # Android + iOS  — admin-created accounts
│   └── admin_web/             # Flutter Web    — custom-claim gated
├── functions/                 # TypeScript, Functions v2
│   └── src/{callables,triggers,scheduled,dispatch,payments,lib}
├── firestore.rules
├── firestore.indexes.json
├── storage.rules
└── firebase.json
```

### Why the split

- **Firestore** holds everything durable. **Realtime Database** holds live driver positions — RTDB writes are roughly an order of magnitude cheaper at 1 Hz per driver and have lower latency, and a fleet of 40 trucks streaming to Firestore will dominate your bill.
- **Cloud Tasks**, not Cloud Scheduler, drives offer timeouts. A scheduler runs at most once a minute; an offer needs to expire at a precise `t+25s`. Enqueue one task per offer.
- **Callables** for anything a user initiates, **Firestore triggers** for fan-out (notifications, ledger entries, denormalisation), **scheduled** functions for rollups and document-expiry sweeps.
- **App Check** enforced on Firestore, Functions and Storage from day one. Retrofitting it after launch means a forced-update release.

### 🛑 Decide this before Phase 7

**Stripe does not onboard businesses domiciled in the Dominican Republic.** Card payments will need either a foreign entity (US/PR) that can hold the Stripe account, or a local acquirer — **Azul**, **CardNet**, or **tPago**. Prompt 7.1 therefore builds a `PaymentGateway` interface with Stripe as the first implementation, so swapping in Azul later is one class, not a rewrite. Confirm the merchant entity with the client before you write payment code.

---

## Firestore schema

Twelve top-level collections. The *who writes* column is enforced by security rules — **SDK** means a client app may write directly, **fn** means only the Admin SDK inside a function can.

| Path | Who writes | Holds |
|---|---|---|
| `users/{uid}` | SDK (own) | Client profile: phone, name, email, `fcmTokens`, `gatewayCustomerId`, `blocked`, `activeServiceId` |
| `drivers/{uid}` | fn | Chofer: name, cédula, licencia, `status` (active/inactive/suspended), `assignedTruckId`, `currentServiceId`, `isOnline`, `rating`, `ratingCount`, `createdBy` |
| `drivers/{uid}/documents/{docType}` | fn | licencia · seguro · marbete · matrícula: `storagePath`, `issuedAt`, `expiresAt`, `verifiedBy` |
| `trucks/{truckId}` | fn | Grúa: `plate`, `type` (plataforma/gancho/pesada), `capacityKg`, `active`, `assignedDriverId`, photos |
| `services/{serviceId}` | fn | **The order.** Full shape below. |
| `services/{id}/offers/{driverId}` | fn | `state` (sent/accepted/rejected/expired), `sentAt`, `expiresAt`, `distanceMeters`, `round` |
| `services/{id}/messages/{msgId}` | SDK (parties) | Chat: `senderId`, `senderRole`, `text`, `sentAt`, `readAt` |
| `services/{id}/events/{eventId}` | fn | Append-only transition log — `from`, `to`, `actorId`, `actorRole`, `at`, `meta` |
| `tracking/{serviceId}` | fn | Position mirrored from RTDB while on service, so the client listens to *one* doc instead of the fleet |
| `invoices/{invoiceId}` | fn | `serviceId`, `ncf`, `ncfType`, `rnc`, line items, `itbisCents`, `totalCents`, `pdfPath` |
| `earnings/{driverId}/entries/{id}` | fn | `serviceId`, `grossCents`, `commissionCents`, `netCents`, `method`, `settledAt` |
| `config/{pricing\|dispatch\|app}` | fn | Tariffs, dispatch tuning, min supported app version, maintenance flag |
| `reports/daily/{yyyy-MM-dd}` | fn | Pre-aggregated rollups — never query raw `services` from the admin panel |

### RTDB — live positions only

```jsonc
// Realtime Database — written at <= 0.2 Hz by the driver app
/live/{driverId} = {
  lat, lng, geohash,        // geohash precision 6 (~1.2 km cells)
  heading, speedKmh, accuracy,
  isOnline: true,
  state: "idle" | "on_service",
  truckType: "plataforma",
  serviceId: null,
  updatedAt: 1757308800000
}
```

### The service document

```jsonc
services/{serviceId} = {
  code: "GR-260908-0431",               // human-readable, shown to both parties
  status: "pending_dispatch",
  clientId, clientName, clientPhone,

  vehicle: { make, model, year, color, plate,
             type: "sedan|suv|camioneta|camion",
             condition: "no_arranca|accidentado|ruedas_bloqueadas|volcado|sin_combustible" },
  truckTypeRequired: "plataforma|gancho|pesada",   // derived from vehicle, overridable

  pickup:  { geo: GeoPoint, geohash, address, placeId, reference, notes },
  dropoff: { geo: GeoPoint, geohash, address, placeId },

  route: { distanceMeters, durationSeconds, polyline, provider: "routes_api", fetchedAt },

  quote: { pricingVersion: 3, baseCents, includedKm, perKmCents, distanceKm,
           distanceCents, surcharges: [{ code, label, cents }],
           subtotalCents, itbisCents, totalCents, currency: "DOP" },
  final: { /* same shape, written at completion; differs if waiting time or reroute */ },

  payment: { method: "card|cash",
             status: "none|authorized|captured|failed|refunded|cash_pending|cash_collected",
             gateway: "stripe", intentId, customerId,
             authorizedCents, capturedCents, cashCollectedAt, last4, brand },

  driverId, truckId, assignedAt, assignmentMode: "auto|manual",

  dispatch: { round: 0, radiusKm: 5, offeredTo: [], rejectedBy: [],
              lastOfferAt, offerExpiresAt, taskName },

  timeline: { createdAt, dispatchedAt, acceptedAt, arrivedAt,
              startedAt, completedAt, cancelledAt },

  cancellation: { by: "client|driver|admin|system", reason, feeCents },
  ratings: { clientToDriver: { stars, comment }, driverToClient: { stars, comment } },

  invoiceId, createdAt, updatedAt
}
```

### Indexes you will need

`services`: (`clientId` asc, `createdAt` desc) · (`driverId` asc, `createdAt` desc) · (`status` asc, `createdAt` desc) · (`status` asc, `dispatch.offerExpiresAt` asc).

Add them in Prompt 1.3 — do not wait for a production query to fail.

---

## Service state machine

Eleven states. Every transition is a Cloud Function callable with a guard; the client and driver apps only ever *request* a transition. Each accepted transition appends to `services/{id}/events`, which is your audit trail and your debugging tool.

**Happy path:**

```
pending_dispatch → offered → accepted → arrived → in_progress → completed → closed
   (client)       (system)   (chofer)  ("Llegué")  ("Iniciar")  ("Finalizar")  (paid)
```

**Off the happy path:** `needs_manual` (dispatch exhausted), `cancelled`, `expired`, `failed`.

| From | Callable / trigger | Actor | To | Guards | Side effects |
|---|---|---|---|---|---|
| — | `requestService` | client | `pending_dispatch` | No other active service for this client; pickup inside a covered zone; quote signature valid and < 10 min old | Mint `code`; write service; enqueue `dispatchNext` |
| `pending_dispatch` | `dispatchNext` | system | `offered` | ≥1 eligible driver in radius not already offered | Create offer doc; high-priority data FCM; enqueue `expireOffer` at t+27s |
| `offered` | `acceptService` | chofer | `accepted` | Offer exists, state `sent`, not expired; driver `active` + `idle`; service still `offered`. All inside one transaction. | Set `driverId`/`truckId`; RTDB `state=on_service`; delete pending task; authorize card; notify client |
| `offered` | `rejectService` · `expireOffer` | chofer / system | `pending_dispatch` | Offer still `sent` | Push uid to `rejectedBy`; `round++`; immediately `dispatchNext` |
| `pending_dispatch` | `dispatchNext` | system | `needs_manual` | Radius at max (40 km) **and** (round ≥ 8 or elapsed > 6 min) | FCM to topic `admins`; surface in panel queue; keep client informed |
| `needs_manual` | `assignServiceManually` | admin | `accepted` | Target driver `active` and has no `currentServiceId` | Same as accept, plus `assignmentMode=manual` and an audit entry |
| `accepted` | `markArrived` | chofer | `arrived` | Driver within 300 m of pickup, *or* admin override with reason | Notify client "Tu grúa llegó"; start 10-min free waiting clock |
| `arrived` | `startService` | chofer | `in_progress` | Card holds must be `authorized`, else block and surface to client | Stop waiting clock, bill overage; begin dropoff route; live ETA to client |
| `in_progress` | `completeService` | chofer | `completed` | Driver within 500 m of dropoff, or admin override | Compute `final`; capture card or set `cash_pending`; write earnings entry; free driver; request rating |
| `completed` | gateway webhook · `confirmCash` | system | `closed` | Capture succeeded, or chofer confirmed cash received | Generate invoice + NCF + PDF; email/notify client |
| `pending_dispatch` `offered` `accepted` `arrived` | `cancelService` | client | `cancelled` | Not yet `in_progress` | Fee only if > 3 min after `acceptedAt`; release hold or capture fee; free driver; re-open driver to dispatch |
| `accepted` `arrived` | `cancelByDriver` | chofer | `pending_dispatch` | Reason required from a fixed enum | Increment driver's cancel counter; exclude from re-dispatch; alert admins after 3 in 24 h |

> **Implementation rule.** Write this table once as a `TRANSITIONS` constant in `functions/src/lib/stateMachine.ts` and have every callable go through a single `applyTransition(serviceId, event, actor, effects)` helper that checks the guard, runs the transaction, and appends the event. Hand-rolling the guard in eleven callables is how you get a service stuck in `arrived` forever.

---

## Dispatch algorithm

Sequential cascade with an expanding radius — one driver gets one exclusive 25-second offer at a time. Broadcasting to everyone is simpler but produces double-accepts and trains choferes to ignore pushes.

```js
async function dispatchNext(serviceId) {
  const s = await getService(serviceId);
  if (s.status !== "pending_dispatch") return;          // idempotent: safe to re-run

  let r = s.dispatch.radiusKm ?? cfg.startRadiusKm;     // 5
  let candidates = [];

  while (candidates.length === 0 && r <= cfg.maxRadiusKm) {   // 5 → 10 → 20 → 40
    const bounds = geohashQueryBounds(s.pickup.geo, r * 1000);
    const live = await rtdbQueryByGeohashBounds(bounds);

    candidates = live
      .filter(d => d.isOnline && d.state === "idle")
      .filter(d => d.truckType === s.truckTypeRequired)
      .filter(d => haversineKm(d, s.pickup.geo) <= r)        // geohash boxes over-select
      .filter(d => !s.dispatch.offeredTo.includes(d.driverId))
      .filter(d => !s.dispatch.rejectedBy.includes(d.driverId));

    candidates = await dropInactiveDrivers(candidates);       // drivers/{uid}.status === "active"
    if (candidates.length === 0) r *= 2;
  }

  if (candidates.length === 0) {
    const elapsed = now() - s.timeline.createdAt;
    if (s.dispatch.round >= cfg.maxRounds || elapsed > cfg.maxDispatchMs) {
      return applyTransition(serviceId, "noDriversFound");    // → needs_manual
    }
    return scheduleRetry(serviceId, cfg.retryDelayMs);        // 15 s, radius stays at max
  }

  // Lower score wins. Distance dominates; rating and fairness break ties.
  const best = candidates
    .map(d => ({ d, score:
        0.70 * norm(haversineKm(d, s.pickup.geo), 0, r)
      + 0.20 * (1 - norm(d.rating ?? 4.5, 3, 5))
      + 0.10 * (1 - norm(minutesIdle(d), 0, 30)) }))   // longest-waiting gets a nudge
    .sort((a, b) => a.score - b.score)[0].d;

  await runTransaction(async tx => {
    const fresh = await tx.get(serviceRef);
    if (fresh.status !== "pending_dispatch") return;    // someone beat us
    tx.set(offerRef(serviceId, best.driverId), {
      state: "sent", round: s.dispatch.round, sentAt: now(),
      expiresAt: now() + cfg.offerTtlMs,                // 25 000
      distanceMeters: Math.round(haversineKm(best, s.pickup.geo) * 1000),
    });
    tx.update(serviceRef, {
      status: "offered",
      "dispatch.radiusKm": r,
      "dispatch.offeredTo": FieldValue.arrayUnion(best.driverId),
      "dispatch.lastOfferAt": now(),
      "dispatch.offerExpiresAt": now() + cfg.offerTtlMs,
    });
  });

  await sendOfferPush(best.driverId, serviceId);   // data-only, high priority, ttl 25s
  await enqueueTask("expireOffer", { serviceId, driverId: best.driverId },
                    { scheduleTime: now() + cfg.offerTtlMs + 2000 });
}
```

### Tuning constants — `config/dispatch`

| Key | Default | Why |
|---|---|---|
| `offerTtlMs` | 25 000 | Long enough for a chofer to look up from the wheel, short enough that a client is not waiting 3 min on a cascade |
| `startRadiusKm` | 5 | Santo Domingo density; raise to 12 for Santiago and the interior |
| `maxRadiusKm` | 40 | Beyond this the ETA is unsellable — hand to `needs_manual` instead |
| `maxRounds` | 8 | Eight offers ≈ 3.5 min of cascading |
| `maxDispatchMs` | 360 000 | Hard 6-minute ceiling before a human takes over |
| `retryDelayMs` | 15 000 | Radius exhausted but time left — wait for someone to come online |
| `arrivalRadiusM` | 300 | Guard for "Llegué"; GPS in dense urban RD is not better than this |

### Pricing formula — `config/pricing`

Computed server-side only, in integer DOP cents, and stamped with a `pricingVersion` so historical services never reprice when tariffs change.

```
subtotal = baseCents                                   // banderazo, by truck type
         + max(0, distanceKm - includedKm) * perKmCents
         + truckTypeSurcharge                          // pesada > gancho > plataforma
         + nightSurcharge                              // 22:00–06:00 America/Santo_Domingo, % of base
         + holidaySurcharge                            // RD holiday calendar in config
         + max(0, waitingMin - freeWaitingMin) * perWaitingMinCents
         + tollsCents                                  // peajes on the chosen route

itbis    = round(subtotal * 0.18)                      // only when issuing an NCF
total    = subtotal + itbis
```

> **Quote integrity.** The quote the client sees must be the quote the server bills. Have `quoteService` return the quote plus an HMAC signature over `(clientId, pickup, dropoff, totalCents, expiresAt)`; `requestService` recomputes and rejects a mismatch. Otherwise a modified client can request a RD$200 tow to Puerto Plata.

---

## Phase 0 — Cimientos

Monorepo, three Firebase environments, App Check, the spec file, and a working emulator suite. Nothing here is glamorous and all of it is expensive to retrofit.

**Depends on:** nothing · **Blocks:** everything

### Prompt 0.1 — Monorepo scaffold

```
Create a Flutter monorepo named `grua_rd` managed by Melos.

Structure:
- packages/grua_core — a Dart+Flutter package holding models, repository interfaces,
  Firestore path constants, the theme, l10n (es-DO primary, en fallback),
  Result/Failure types, and Riverpod providers shared by all three apps.
- apps/client_app, apps/driver_app — Flutter apps for Android and iOS.
- apps/admin_web — a Flutter app targeting web only.

For each app configure three flavors (dev, stg, prod) with distinct
applicationId / bundleId suffixes and app names, wired through
--dart-define-from-file config/{flavor}.json. Add flutter_flavorizr or
hand-written Gradle/xcconfig — your choice, but document it in the README.

Set up: melos bootstrap scripts, a shared analysis_options.yaml with
very_good_analysis, dart_code_metrics, and `melos run analyze|test|format`.
Add a .gitignore covering google-services.json, GoogleService-Info.plist,
firebase_options*.dart, and config/*.json.

Do not add Firebase yet. Just prove `melos bootstrap && melos run analyze`
is green and all three apps launch a placeholder screen.
```

**Done when:** three apps build in all three flavors; `melos run analyze` exits 0.

### Prompt 0.2 — Firebase + App Check

```
Wire Firebase into all three apps across three projects:
grua-rd-dev, grua-rd-stg, grua-rd-prod.

- Run flutterfire configure per app per flavor; generate
  firebase_options_{flavor}.dart and select at runtime from the flavor
  dart-define. Never commit the generated files with real keys — read the
  API keys from config/{flavor}.json.
- Add firebase_core, firebase_auth, cloud_firestore, firebase_storage,
  firebase_messaging, firebase_app_check, cloud_functions,
  firebase_database, firebase_crashlytics, firebase_remote_config.
- Enable App Check: Play Integrity (Android), DeviceCheck/App Attest (iOS),
  reCAPTCHA Enterprise (web). Use the debug provider under `kDebugMode`.
  Enforce App Check on Firestore, Storage, RTDB and Functions in the DEV
  project now so we catch violations during development, not at launch.
- Initialize a `functions/` TypeScript project on Node 20, Functions v2,
  region `us-east1` (lowest latency to RD). Add zod, firebase-admin,
  firebase-functions, and configure eslint + vitest.
- Initialize Firestore, RTDB, Storage and Hosting (for admin_web) in
  firebase.json with per-project aliases in .firebaserc.

Add a `bootstrap.dart` in grua_core that initializes Firebase, App Check,
Crashlytics (with FlutterError.onError + PlatformDispatcher.onError hooks)
and Remote Config, and have all three apps call it.
```

**Done when:** each app connects to its flavor's project; an App Check violation is visible in the console when you strip the token.

### Prompt 0.3 — CLAUDE.md, the spec of record

```
Create /CLAUDE.md as the single source of truth every later task reads first.
It must contain, verbatim and completely:

1. Project summary: 24/7 tow-truck (grúa) dispatch for the Dominican
   Republic. Three clients, one Firebase backend. DOP, America/Santo_Domingo,
   es-DO UI.
2. The full Firestore schema — every collection, every field, the exact
   service document shape, and the RTDB /live/{driverId} shape.
3. The service state machine — all 11 states and the complete transition
   table (from, callable, actor, to, guards, side effects).
4. The dispatch algorithm pseudocode and the config/dispatch constants.
5. The pricing formula and the quote-signing rule.
6. Hard conventions:
   - status/driverId/quote/payment are written ONLY by Cloud Functions.
   - Money is integer DOP cents. Never doubles.
   - Timestamps are UTC Firestore Timestamps; format in America/Santo_Domingo.
   - Every callable: App Check → auth → role → zod input validation → guard
     → transaction → event append.
   - Feature-first folder layout: lib/features/{feature}/{data,domain,presentation}.
   - Riverpod for state, GoRouter for routing, freezed+json_serializable
     for models.
   - Every new callable ships with an emulator test.
7. An "Amending this file" section: any task that needs a new field or
   state must edit CLAUDE.md in the same commit.

Also create /docs/adr/ with ADR-001 recording why live positions live in
RTDB and not Firestore, and ADR-002 recording the Cloud Tasks choice for
offer expiry.
```

**Done when:** a fresh agent session can answer "what fields does a service have?" from the repo alone.

### Prompt 0.4 — Emulator suite + seed data

```
Set up the full Firebase emulator suite: auth, firestore, database,
functions, storage, pubsub, and the Cloud Tasks emulator shim (or a local
queue stub behind an interface so functions code is identical).

Write scripts/seed.ts that populates a realistic dev dataset:
- 1 admin, 2 ops users with custom claims
- 8 drivers across Santo Domingo, Santiago and Higüey, mixed truck types,
  6 active / 1 inactive / 1 suspended, with /live positions
- 5 trucks (2 plataforma, 2 gancho, 1 pesada) assigned to drivers
- 3 clients with saved payment methods
- 12 services spanning every status, including 2 needs_manual and
  1 cancelled with a fee
- config/pricing, config/dispatch, config/app documents

Add a --with-emulators flag to the three apps that points the Firebase SDKs
at the local emulators, and a `melos run dev` that starts emulators + seed +
the client app.

Write README/DEVELOPMENT.md documenting the loop: start emulators, seed,
run app, run `firebase emulators:exec "npm test"` in functions/.
```

**Done when:** one command gives you a populated local stack; the seeded services render in whatever screens exist.

---

## Phase 1 — Modelo de datos

Types and rules before behaviour. Security rules written now are a design tool — they force you to decide who owns each field.

**Depends on:** 0.1–0.4

### Prompt 1.1 — Dart models in grua_core

```
In packages/grua_core, implement every entity in the CLAUDE.md schema as a
freezed + json_serializable model under lib/src/models/:

AppUser, Driver, DriverDocument, Truck, Service, ServiceVehicle,
ServiceLocation, ServiceRoute, Quote, QuoteSurcharge, ServicePayment,
DispatchState, ServiceTimeline, Offer, ChatMessage, ServiceEvent,
TrackingPoint, Invoice, EarningEntry, PricingConfig, DispatchConfig.

Rules:
- Enums as sealed Dart enums with a `wire` string and a tolerant
  `fromWire` that maps unknown values to an `unknown` member — an old app
  version must never crash on a new status.
- Money fields are `int` cents, named *Cents. Add a `Money` extension with
  `formatDOP()` producing "RD$ 1,250.00".
- Timestamps convert via a TimestampConverter to Dart DateTime in UTC.
- GeoPoint converts to a LatLng value object; keep the geohash as a field.
- Service exposes computed getters: isActive, isCancellable, canChat,
  displayStatus (localized es-DO), etaMinutes.

Generate with build_runner and add unit tests round-tripping each model
through toJson/fromJson including null and unknown-enum cases.
```

**Done when:** round-trip tests pass, and an unknown `status` string deserializes without throwing.

### Prompt 1.2 — Paths, converters, repositories

```
In grua_core add:

1. lib/src/data/paths.dart — a `Paths` class with static typed accessors for
   every collection and document path in the schema. No string literals for
   paths anywhere else in the codebase, ever.
2. withConverter<T> extensions so every read returns a typed model.
3. Repository interfaces in lib/src/domain/repositories/ and Firestore
   implementations in lib/src/data/:
   - UserRepository, DriverRepository, TruckRepository
   - ServiceRepository: watchService(id), watchActiveForClient(uid),
     watchActiveForDriver(uid), watchHistory(uid, role, limit, startAfter)
   - OfferRepository: watchIncomingOffer(driverId)
   - ChatRepository, TrackingRepository, EarningsRepository, ConfigRepository
4. A FunctionsClient wrapper over cloud_functions exposing each callable as a
   typed method returning Result<T, Failure>, mapping FirebaseFunctions
   error codes to domain Failures (unauthenticated, permission-denied,
   failed-precondition → DomainFailure with an es-DO message).
5. Riverpod providers for every repository, overridable in tests with fakes.

All list queries must be paginated with startAfterDocument — never
fetch an unbounded history.
```

**Done when:** no raw collection strings outside `paths.dart`; repositories are swappable with in-memory fakes in tests.

### Prompt 1.3 — Security rules + indexes

```
Write firestore.rules, database.rules.json, storage.rules and
firestore.indexes.json implementing exactly this access model:

Helpers: isSignedIn(), hasAppCheck(), isAdmin() (custom claim role in
['admin','ops']), isOwner(uid), isServiceParty(svc).

- users/{uid}: read/update own doc only, and only a whitelist of fields
  (name, email, fcmTokens, locale). Everything else is function-only.
- drivers/{uid}: driver reads own doc; admins read all; no client writes at all.
  drivers/{uid}/documents/**: driver reads own; admin read/write.
- trucks/**: admin read/write; drivers read their assigned truck.
- services/{id}: read if isServiceParty or isAdmin. create/update/delete: false.
- services/{id}/offers/{driverId}: read if driverId == uid or isAdmin. write: false.
- services/{id}/messages/{msgId}: read if isServiceParty. create if
  isServiceParty && senderId == uid && status is one of the chat-open states
  && text length 1..1000 && no extra fields. update: only readAt. delete: false.
- services/{id}/events/**: read if isServiceParty or isAdmin. write: false.
- tracking/{serviceId}: read if isServiceParty. write: false.
- invoices/{id}: read if own or admin. write: false.
- earnings/{driverId}/**: read if own or admin. write: false.
- config/**: read by any signed-in user. write: admin only.
- reports/**: admin only.

RTDB /live/{driverId}: write if auth.uid == driverId and the payload matches
a strict shape; read: admin only (apps read tracking/ instead).

Storage: drivers/{uid}/docs/** write by that driver or admin, max 10 MB,
contentType in [image/jpeg, image/png, application/pdf].
service_photos/{serviceId}/** write by the assigned driver only.

Require request.auth != null AND hasAppCheck() on every rule.
Add every composite index listed in CLAUDE.md.
```

**Done when:** rules deploy clean and every app still works — any breakage means an app was writing something it shouldn't.

### Prompt 1.4 — Rules unit tests

```
Using @firebase/rules-unit-testing against the emulator, write a test suite
that proves the rules from 1.3. At minimum, assert DENIED for:

- a client reading another client's service
- a client writing services/{id}.status, .driverId, .quote or .payment
- a driver reading an offer addressed to a different driver
- a driver reading the full /live tree
- a non-party posting to services/{id}/messages
- a message with senderId spoofed to another uid
- a message longer than 1000 chars, or with an extra field
- any client write to drivers/, trucks/, invoices/, earnings/, config/, reports/
- an unauthenticated read of anything
- a signed-in request with no App Check token

And ALLOWED for: client reading own service and its messages/events/tracking;
driver reading assigned service and own offer; driver writing own /live node;
admin reading everything.

Wire it into `melos run test` and a GitHub Actions job so a rules regression
fails CI.
```

**Done when:** the deny suite goes red the moment anyone loosens a rule.

---

## Phase 2 — Auth y roles

Three different identity models on one Auth tenant: clients self-register by phone, choferes are created by an admin, admins are gated by custom claims.

**Depends on:** Phase 1

### Prompt 2.1 — Client phone OTP

```
Implement phone-number authentication in apps/client_app.

- Country picker defaulting to +1 809/829/849 (RD). Validate RD mobile
  formats; allow other countries but warn.
- verifyPhoneNumber flow with autoRetrieval on Android, manual 6-digit entry,
  a 60-second resend cooldown, and clear es-DO error copy for
  invalid-verification-code, session-expired, too-many-requests and
  quota-exceeded.
- On first sign-in, an `onUserCreate` Auth blocking function (or a callable
  `ensureUserProfile`) creates users/{uid} with role=client, phone, locale,
  createdAt — never let the app create its own profile document.
- Profile completion screen: name and optional email, written through the
  whitelisted client-writable fields only.
- Persist session; add a GoRouter redirect that sends unauthenticated users
  to the phone screen and blocked users (users/{uid}.blocked) to a support screen.
- Sign-out clears the FCM token for this device.

The screens already exist — wire the existing widgets to Riverpod controllers,
do not redesign them.
```

**Done when:** a new number reaches the home screen with a `users/` doc created server-side.

### Prompt 2.2 — Driver accounts + custom claims

```
Choferes cannot self-register. Implement:

functions: `createDriver` (admin-only callable)
- zod input: name, cedula, phone, email, licenseNumber, licenseExpiry,
  truckId?, initialPassword?
- creates the Auth user (email+password), sets custom claims
  { role: 'driver', driverId: uid }, writes drivers/{uid} with status='inactive'
  until documents are verified, writes an audit entry, and returns a one-time
  setup link. Sends credentials by SMS/email.
- rejects duplicate cedula or email with failed-precondition.

functions: `setDriverStatus` (admin-only) — active | inactive | suspended.
Suspending must also: force isOnline=false in RTDB, refuse if the driver has
a currentServiceId (return failed-precondition naming the service), and
revoke refresh tokens.

driver_app:
- Email+password login only. No sign-up route exists in the router at all.
- After login, force a token refresh and assert claims.role === 'driver';
  otherwise sign out with "Esta cuenta no es de chofer."
- If drivers/{uid}.status !== 'active', show a blocking screen explaining
  which documents are missing or that the account is suspended.
- Force password change on first login.
```

**Done when:** a driver created from a script can log in; a suspended one is locked out within a token refresh.

### Prompt 2.3 — Admin claims + route guards

```
Implement admin access for apps/admin_web.

functions:
- `bootstrapFirstAdmin`: callable that succeeds only if zero users hold an
  admin claim, and only for an email present in a hard-coded allowlist
  (from functions config). Sets { role: 'admin' }.
- `setAdminRole`: admin-only, sets role to 'admin' | 'ops' | null on a target
  uid, writes an audit entry, and refuses to remove the last remaining admin.
- Define permissions per role: 'ops' can view everything and assign services
  manually, but cannot create/delete drivers, change pricing, or manage roles.

admin_web:
- Email+password sign-in with a mandatory reCAPTCHA Enterprise App Check token.
- GoRouter redirect reads the ID token claims; no claim → sign out. Every
  route declares a required permission and renders a 403 page when missing.
- A session-expiry watcher that forces re-auth after 8 hours of inactivity.
- Hide, don't just disable, controls the role cannot use — and re-check the
  permission server-side in every callable regardless.

Add a callable `whoAmI` returning the caller's role and permissions, and use
it as the single source of truth for the UI.
```

**Done when:** an `ops` account can assign a service but gets a server-side denial when calling `createDriver` directly.

---

## Phase 3 — Solicitud del cliente

From "my car died on the Autopista Duarte" to a signed quote and a service document. Everything priced server-side.

**Depends on:** Phase 2

### Prompt 3.1 — Location, permissions, geocoding

```
In client_app implement a LocationService in grua_core using geolocator +
geocoding:

- Permission ladder: check service enabled → request whileInUse → handle
  deniedForever with a "Abrir ajustes" action. Localized es-DO rationale
  shown BEFORE the OS prompt.
- getCurrentPosition with LocationAccuracy.high and a 10 s timeout, falling
  back to getLastKnownPosition, then to a map-centered manual pin.
- Reverse-geocode to a display address. RD addresses are unreliable, so
  always show the resolved address as editable text plus a mandatory
  "Referencia" field (e.g. "frente al colmado, km 12 Autopista Duarte").
- A geohash utility (precision 6 for queries, 9 stored).
- An AddressSearch widget over Places Autocomplete, biased to RD
  (components=country:do) with a session token per search to control cost.

Expose as Riverpod providers: currentPositionProvider,
locationPermissionProvider, addressSearchProvider. Handle the airplane-mode
and GPS-off cases with real UI, not a spinner.
```

**Done when:** denying permission still lets the user place a pin manually and continue.

### Prompt 3.2 — Pickup / dropoff selection

```
Wire the existing map/request screens to a RequestDraft controller
(Riverpod StateNotifier) holding: pickup, dropoff, vehicle, condition,
truckTypeRequired, paymentMethod, notes.

- Google Map with a fixed center pin for pickup selection; the map moves, the
  pin does not. Debounce reverse-geocoding to 400 ms after the camera settles.
- "Usar mi ubicación" button; "Confirmar recogida" advances to dropoff.
- Dropoff supports search, map pin, and saved places (taller, casa, trabajo)
  stored under users/{uid}/places.
- Validate: both points inside a covered zone (read config/app.zones as
  polygons — point-in-polygon check client-side for UX, re-checked
  server-side), and pickup != dropoff.
- Show a live polyline between the two once both are set, using the route
  returned by the quote call — do not call the Routes API from the client.
- Persist the draft to local storage so a killed app resumes the request.
```

**Done when:** a user outside the coverage polygon sees a clear message, not a failed request.

### Prompt 3.3 — Vehicle + condition → truck type

```
Build the vehicle-details step and the truck-type inference that drives
dispatch filtering.

- Fields: marca, modelo, año, color, placa (RD format validation), tipo
  (sedan | suv | camioneta | camion) and condición (no_arranca | accidentado |
  ruedas_bloqueadas | volcado | sin_combustible).
- Inference rules, implemented in grua_core so the server can reuse them:
    volcado OR accidentado OR ruedas_bloqueadas → plataforma
    tipo == camion                             → pesada
    otherwise                                  → gancho
  Let the user override with an explanation of the price difference.
- Optional photos of the vehicle (max 3, compressed to <= 1600 px / 500 KB)
  uploaded to Storage under service_photos/{draftId}/ and moved on creation.
- Save the last-used vehicle to users/{uid}/vehicles for one-tap reuse.
- Show a plain-language summary card before the quote step.

Add unit tests for every inference branch.
```

**Done when:** the same inference function is called by `quoteService` on the server and by the app.

### Prompt 3.4 — quoteService + requestService

```
Implement the two callables that turn a draft into a dispatchable service.

`quoteService(pickup, dropoff, vehicle, condition, truckTypeOverride?)`
- Validates App Check + auth + zod input; verifies both points are inside a
  coverage zone.
- Calls the Google Routes API server-side (never from the app) for
  distanceMeters, durationSeconds, encoded polyline and tolls.
- Computes the quote with the CLAUDE.md pricing formula, reading
  config/pricing and stamping pricingVersion. Night surcharge uses
  America/Santo_Domingo local time, not UTC.
- Returns { quote, route, expiresAt: now+10min, signature } where signature is
  an HMAC-SHA256 over (clientId|pickupGeohash|dropoffGeohash|totalCents|
  expiresAt|pricingVersion) using a secret from Secret Manager.
- Caches by (pickupGeohash7, dropoffGeohash7, truckType, hourBucket) for
  5 minutes to cut Routes API spend.

`requestService(draft, quoteSignature, paymentMethod)`
- Rejects if the caller already has an active service (status not in
  terminal set) — return failed-precondition with the existing serviceId so
  the app can deep-link to it.
- Recomputes the quote and rejects on signature mismatch or expiry.
- Mints `code` as GR-{yyMMdd}-{4 random base32}, writes the service with
  status='pending_dispatch', appends the first event, and enqueues
  dispatchNext with zero delay.
- Sets users/{uid}.activeServiceId in the same batch.

Client side: a quote bottom sheet showing the breakdown (banderazo, km,
recargos, ITBIS, total in RD$), payment method choice, and a "Solicitar grúa"
button that is disabled while the quote is stale. On success, navigate to the
searching screen listening to services/{id}.
```

**Done when:** a tampered `totalCents` is rejected server-side; a second concurrent request returns the existing service.

---

## Phase 4 — Motor de despacho

The hardest part of the system and the one that must be correct under concurrency. Build it entirely against the emulator before any device sees it.

**Depends on:** Phase 3 · **Blocks:** Phase 5

### Prompt 4.1 — Live driver index

```
Build the live-position layer in RTDB and the query helpers functions need.

RTDB:
- /live/{driverId} with the shape in CLAUDE.md. Indexed on `geohash`
  (".indexOn": ["geohash"]).
- onDisconnect().update({ isOnline: false }) set by the driver app so a
  crashed app removes itself from dispatch automatically.

functions/src/lib/geo.ts:
- geohashForLocation, geohashQueryBounds (radius → list of [start,end] ranges),
  haversineKm — port the geofire-common algorithms or depend on geofire-common.
- rtdbQueryByGeohashBounds(bounds): runs one orderByChild('geohash')
  .startAt(a).endAt(b) query per bound, merges, dedupes.
- A `staleness` filter dropping any node whose updatedAt is older than 90 s,
  regardless of isOnline — a phone that lost signal is not dispatchable.

Also write a scheduled function `reapStaleDrivers` (every 2 min) that sets
isOnline=false on nodes stale for > 5 min and, if such a driver holds a
currentServiceId in accepted/arrived, raises an admin alert.

Unit-test geo.ts against known coordinate pairs in Santo Domingo, Santiago
and Punta Cana, including a query that spans a geohash cell boundary.
```

**Done when:** a radius query near a cell boundary returns the same set as a brute-force haversine scan of the seed data.

### Prompt 4.2 — State machine + dispatchNext

```
Implement functions/src/lib/stateMachine.ts and the dispatcher.

stateMachine.ts:
- A TRANSITIONS constant encoding the full table from CLAUDE.md:
  { event, from: Status[], to: Status, actor: 'client'|'driver'|'admin'|'system',
    guard: (ctx) => Promise<void> }
- applyTransition({ serviceId, event, actor, actorId, meta, effects }) which:
  1. opens a Firestore transaction
  2. re-reads the service, asserts status ∈ from, else throws
     failed-precondition with a code the apps can map to es-DO copy
  3. runs the guard
  4. applies the status change + timeline stamp + updatedAt
  5. appends services/{id}/events/{autoId}
  6. returns the effects to run AFTER commit (pushes, tasks, gateway calls)
- Never perform network I/O inside the transaction.

dispatch.ts:
- dispatchNext(serviceId) exactly as the pseudocode in CLAUDE.md: expanding
  radius 5→10→20→40, candidate filtering, weighted scoring
  (0.70 distance, 0.20 rating, 0.10 idle time), transactional offer creation,
  data-only high-priority FCM, and a Cloud Task for expiry.
- Fully idempotent: two concurrent invocations must produce at most one offer.
- Log a structured line per round: { serviceId, round, radiusKm,
  candidateCount, chosenDriverId, scoreBreakdown } for tuning later.

Emulator tests: no drivers → needs_manual after maxRounds; one driver →
one offer; ten drivers → nearest chosen; concurrent dispatchNext calls →
exactly one offer document.
```

**Done when:** the concurrency test passes repeatedly — run it 50 times in CI.

### Prompt 4.3 — Offer expiry + cascade

```
Implement precise offer timeouts with Cloud Tasks.

- lib/tasks.ts: enqueueTask(handler, payload, { scheduleTime, dedupeName }),
  deleteTask(name). Store the task name on the service as
  dispatch.taskName so accept can cancel it.
- HTTP function `expireOffer` (Cloud Tasks target, OIDC-authenticated, not
  publicly callable):
  1. loads the offer; if state !== 'sent', return 200 (already handled)
  2. marks it expired, pushes driverId to dispatch.rejectedBy, round++
  3. transitions the service back to pending_dispatch
  4. calls dispatchNext immediately
  5. sends a silent FCM to the driver to dismiss the ringing UI
- Belt and braces: a scheduled function every 60 s that sweeps
  services where status=='offered' && dispatch.offerExpiresAt < now - 10s and
  force-expires them, in case a task was lost. This is why that composite
  index exists.
- Track a per-driver acceptance rate on drivers/{uid}
  (offersSent, offersAccepted, rolling 30-day) — surface it in the admin
  panel and use it later to weight scoring.

Emulator test with fake timers: offer → no response → expiry → next driver
offered → accepts. Assert exactly one accepted offer and a clean event log.
```

**Done when:** killing the Cloud Tasks emulator mid-test still expires the offer via the sweeper.

### Prompt 4.4 — accept / reject / manual assign

```
Implement the three assignment callables on top of applyTransition.

`acceptService({ serviceId })` — driver only
- One transaction reading service + offer + driver:
  offer.state=='sent' && offer.expiresAt > now && service.status=='offered'
  && driver.status=='active' && driver.currentServiceId == null.
- Any failure → failed-precondition with a specific code:
  OFFER_EXPIRED | ALREADY_TAKEN | DRIVER_BUSY | DRIVER_INACTIVE. The driver
  app maps each to distinct es-DO copy — "Otro chofer tomó el servicio" is a
  very different message from "La oferta expiró".
- Post-commit effects: cancel the expiry task; RTDB state='on_service';
  drivers/{uid}.currentServiceId; authorize the card hold (Phase 7);
  notify the client with the driver name, truck plate and ETA; open the chat.

`rejectService({ serviceId, reason? })` — driver only
- Marks the offer rejected, cancels the task, cascades immediately.
- Reasons from a fixed enum; three rejections in a shift raises an admin flag.

`assignServiceManually({ serviceId, driverId, note })` — admin/ops only
- Allowed from pending_dispatch, offered or needs_manual.
- Cancels any outstanding offer, sets assignmentMode='manual', writes an
  audit entry with the acting admin uid, and pushes to the driver as an
  assignment (not an offer — no accept/reject).

Emulator tests: two drivers accepting the same offer within 50 ms → exactly
one wins and the loser gets ALREADY_TAKEN.
```

**Done when:** the double-accept race is provably impossible, and each failure code has its own screen state.

---

## Phase 5 — App chofer

The app that has to work one-handed, in the rain, on a highway shoulder. Background location and a push that actually wakes the phone are the two hard problems.

**Depends on:** Phase 4

### Prompt 5.1 — Online toggle + background location

```
Implement the driver's online state and continuous position reporting.

- A prominent "En línea / Fuera de línea" switch. Going online requires:
  drivers/{uid}.status=='active', an assigned active truck, location
  permission 'always', battery-optimization exemption on Android, and
  notifications enabled. Show a checklist, not a generic error.
- Position stream: geolocator.getPositionStream with
  LocationAccuracy.high, distanceFilter: 25. Throttle writes to at most one
  every 5 seconds AND at least one every 30 seconds (heartbeat), whichever
  comes first. Write to RTDB /live/{uid}; never to Firestore.
- Android: foreground service via ForegroundNotificationConfig with a
  persistent "Grúa RD está en servicio" notification and
  enableWakeLock: true. Declare FOREGROUND_SERVICE_LOCATION.
- iOS: allowsBackgroundLocationUpdates = true,
  pausesLocationUpdatesAutomatically = false, UIBackgroundModes location +
  remote-notification, and an NSLocationAlwaysAndWhenInUseUsageDescription in
  es-DO explaining the dispatch use.
- onDisconnect handler sets isOnline=false. On sign-out or toggle-off, write
  isOnline=false explicitly and stop the stream.
- Refuse to go offline while currentServiceId is set — explain why.
- Buffer writes when offline and flush the latest single position on
  reconnect; never replay a queue of stale positions.

Add a debug panel (dev flavor only) showing write rate and last payload.
```

**Done when:** the app reports position with the screen off for 30 minutes on a real Android device.

### Prompt 5.2 — Incoming offer, the ringing screen

```
Build the offer notification and the full-screen accept/reject UI. This is the
single highest-risk piece of the driver app.

Server: send data-only messages (no `notification` block) with
android: { priority: 'high', ttl: 25s }, apns: { headers: {
'apns-push-type': 'alert', 'apns-priority': '10',
'apns-expiration': ... }, payload: { aps: { 'interruption-level':
'time-sensitive', 'content-available': 1, sound: 'offer.caf' } } }.

Android:
- A dedicated 'offers' notification channel: IMPORTANCE_HIGH, custom looping
  sound, vibration pattern, bypass DND, and a full-screen intent so the UI
  appears over the lock screen. Request USE_FULL_SCREEN_INTENT.
- A background FCM handler that shows it even when the app is killed.

iOS:
- Use flutter_callkit_incoming to present the offer as an incoming call.
  This is the only reliable way to break through Focus modes and the lock
  screen on iOS; a normal push will be missed on a highway.

UI (both):
- Countdown ring showing the real seconds remaining computed from
  offer.expiresAt, not a local 25-second timer — clock drift loses offers.
- Show: distance to pickup, pickup address + reference, dropoff, vehicle and
  condition, truck type, and the driver's net earnings for the job.
- ACEPTAR / RECHAZAR calling the Phase 4 callables. Disable both buttons
  during the call; map each failure code to its own message.
- Auto-dismiss on the silent "offer cancelled" push or on countdown zero.
- Only one offer can be on screen at a time; queue nothing.
```

**Done when:** an offer wakes a locked, killed app on both a mid-range Android and an iPhone with Focus on.

### Prompt 5.3 — Navigation to pickup

```
After accepting, show the active-service screen with turn-by-turn guidance.

- Map centered on the driver with the route polyline to the pickup, drawn
  from the Routes API result returned by acceptService. Re-request the route
  when the driver deviates > 150 m from the polyline, at most once a minute.
- A persistent header: client name, phone, vehicle, condition, and the
  service `code`.
- "Navegar" opens the user's preferred external app — Google Maps, Waze
  (heavily used in RD), or Apple Maps — via url_launcher with the correct
  scheme per platform, remembered as a preference. Do not build turn-by-turn
  in-app.
- Live ETA recomputed client-side from remaining polyline distance and current
  speed, written to tracking/{serviceId} through a lightweight callable at
  most every 20 s so the client app sees it.
- Buttons for chat and call (Phase 6), and a "Cancelar servicio" with a
  required reason from the enum.
- If the app is killed and reopened, restore straight to this screen from
  drivers/{uid}.currentServiceId.
```

**Done when:** force-quitting mid-service and reopening lands on the same screen with live state.

### Prompt 5.4 — Llegué · Iniciar · Finalizar

```
Implement the three service-state actions with their server guards.

functions:
- `markArrived({ serviceId, lat, lng })`: guard driver within
  config/dispatch.arrivalRadiusM (300 m) of pickup; otherwise
  failed-precondition OUT_OF_RANGE with the measured distance so the app can
  say "Estás a 1.2 km del punto de recogida". Starts the free-waiting clock.
- `startService({ serviceId, photos[] })`: requires arrived; requires
  payment.status=='authorized' when method=='card' (else BLOCKED_PAYMENT);
  computes waiting overage; stamps startedAt.
- `completeService({ serviceId, lat, lng, photos[], notes })`: guard within
  500 m of dropoff or an admin override token; computes `final` from actual
  distance and waiting time; triggers capture or cash_pending; writes the
  earnings entry; clears drivers/{uid}.currentServiceId and sets RTDB
  state='idle'; requests ratings from both sides.

driver_app:
- A single primary action button that changes label and colour by state:
  "Llegué" → "Iniciar servicio" → "Finalizar servicio". Slide-to-confirm on
  finalizar to prevent misfires.
- Mandatory photo capture: 2 at pickup (vehicle loaded, odometer) and 1 at
  dropoff. Compress and upload to service_photos/{serviceId}/; block the
  transition until uploads complete, with a retry queue for bad signal.
- Optimistic UI with rollback on server rejection, and a clear "Reintentar"
  path. Never leave the button in a permanent spinner.
- Show the running waiting-time counter and what it will cost, live.
```

**Done when:** each transition is refused server-side when out of range, with the distance shown to the chofer.

### Prompt 5.5 — Ganancias del chofer

```
Build the earnings feature end to end.

functions:
- A Firestore trigger on services/{id} status → 'completed' that writes
  earnings/{driverId}/entries/{serviceId} with grossCents,
  commissionCents (rate from config/pricing.commissionBps),
  netCents, method ('card'|'cash'), completedAt, and settlement state.
  Use the serviceId as the entry id so the trigger is idempotent.
- Maintain rollups at earnings/{driverId} (totals for today, this week, this
  month, and cashOwedCents — cash jobs mean the DRIVER owes the company the
  commission, which is the number that actually matters operationally).
- A scheduled weekly job producing earnings/{driverId}/settlements/{weekId}.

driver_app:
- Ganancias screen: today / week / month toggle, a total card, a service list
  with each job's gross, commission and net, and a prominent
  "Efectivo por entregar: RD$ X" balance.
- A simple bar chart of the last 7 days.
- Tapping a row opens the service detail with its invoice.
- All figures read from the rollups — never sum client-side over history.
```

**Done when:** cash and card jobs produce different ledger effects, and the cash-owed balance matches a manual audit of the seed data.

---

## Phase 6 — Tracking, chat y llamadas

What the client watches while they wait on the shoulder. Latency and clarity matter more than features here.

**Depends on:** Phase 5

### Prompt 6.1 — Live tracking for the client

```
Give the client a live map without exposing the fleet.

- An RTDB trigger on /live/{driverId} that, when state=='on_service', mirrors
  { lat, lng, heading, speedKmh, updatedAt, etaSeconds } into
  tracking/{serviceId} — throttled to at most one Firestore write every 8
  seconds per service (keep the last write timestamp in memory / a
  lightweight doc field and skip in between).
- The client app listens to exactly two documents: services/{id} and
  tracking/{id}. It must never read /live or query drivers.
- Map UI: truck marker with a rotating icon by heading, animated between
  positions with a Tween over ~1 s so it glides instead of teleporting; the
  route polyline; pickup and dropoff markers; a bottom sheet with driver name,
  photo, rating, truck plate and colour, and the ETA.
- ETA copy by state: "Buscando grúa…" → "Grúa asignada · llega en ~8 min" →
  "Tu grúa llegó" → "En camino al destino · ~14 min" → "Servicio completado".
- Handle stale tracking: if updatedAt is older than 60 s, show
  "Reconectando con el chofer…" instead of a frozen marker in the wrong place.
- Keep the screen awake while a service is active (wakelock_plus).
```

**Done when:** the client's map updates smoothly with ≤ 8 s staleness and no read access to other drivers.

### Prompt 6.2 — In-app chat

```
Implement chat between client and chofer on services/{id}/messages.

- Direct SDK writes (rules already restrict this in 1.3) so messages are
  instant; a Firestore trigger handles the push to the other party.
- Message doc: { senderId, senderRole, text, sentAt: serverTimestamp,
  readAt, clientMsgId }. Use clientMsgId for optimistic rendering and
  de-duplication on retry.
- Chat opens on 'accepted' and closes 24 h after a terminal state; enforce the
  window in both the rules and the UI.
- Quick replies to cut typing while driving: "Ya voy en camino",
  "Estoy llegando", "¿Dónde exactamente estás?", "Llegué, salga por favor".
- Unread badge from a denormalized unreadCount on the service, maintained by
  the trigger; mark read when the chat is on screen and the app is foreground.
- Push notifications open directly to the chat via a deep link carrying
  serviceId.
- Handle offline: queue outgoing messages with Firestore's offline
  persistence and show a pending state.
```

**Done when:** messages arrive in under a second and the unread badge survives an app restart.

### Prompt 6.3 — Calling, with number masking

```
Add voice contact between the parties without leaking personal numbers.

Phase A (ship this first): a call button that launches `tel:` through
url_launcher using the counterparty's real number, available only while the
service is in accepted | arrived | in_progress. Log every call attempt to
services/{id}/events for support. Note the privacy trade-off in the
privacy policy and get the client's sign-off.

Phase B (masking, recommended before public launch): integrate Twilio Proxy
or Voice.
- A callable `createCallSession(serviceId)` that provisions a proxy session
  binding both participants to a shared RD number and returns the number +
  short-lived session id.
- The apps dial that number instead of the counterparty.
- Sessions expire with the service; a Firestore trigger closes them on
  terminal states.
- Store no personal numbers on the session record.

Both phases: block the call button outside the allowed states, and show
"Llamada no disponible" with the reason rather than a dead button.
```

**Done when:** Phase A works and the `PhoneService` interface makes Phase B a single implementation swap.

---

## Phase 7 — Pagos y facturación

Authorize on accept, capture on completion, and never let the app decide an amount. Plus RD tax documents, which are not optional for a registered business.

**Depends on:** Phase 5 · **Blocked by:** the merchant-entity decision

### Prompt 7.1 — PaymentGateway abstraction + Stripe setup

```
Because Stripe does not onboard Dominican-domiciled businesses, isolate the
gateway behind an interface from day one.

functions/src/payments/gateway.ts:
  interface PaymentGateway {
    ensureCustomer(userId, profile): Promise<string>
    createSetupSession(customerId): Promise<{ clientSecret }>
    listMethods(customerId): Promise<Method[]>
    detachMethod(customerId, methodId): Promise<void>
    authorize(params: { customerId, methodId, amountCents, currency,
                        idempotencyKey, metadata }): Promise<AuthResult>
    capture(intentId, amountCents, idempotencyKey): Promise<CaptureResult>
    cancel(intentId, reason): Promise<void>
    refund(intentId, amountCents, idempotencyKey): Promise<void>
    verifyWebhook(rawBody, signature): Promise<GatewayEvent>
  }

Implement StripeGateway with capture_method: 'manual', currency 'dop' (verify
DOP support for the account; fall back to USD with a stored FX rate and
disclose it), Customers + SetupIntents for saved cards, and an
idempotencyKey of `${serviceId}:${action}:${attempt}` on every mutating call.
Secrets from Secret Manager, never functions:config.

Leave a documented AzulGateway stub implementing the same interface.

client_app: flutter_stripe PaymentSheet for adding a card
(setup mode), a saved-cards screen backed by `listPaymentMethods` /
`removePaymentMethod` callables, and a default-method preference on
users/{uid}. Store only brand + last4 locally. No PAN ever touches your code.
```

**Done when:** swapping the gateway implementation requires touching no callable and no Flutter code.

### Prompt 7.2 — Authorize on accept, capture on complete

```
Wire card payments into the service lifecycle.

- On acceptService (card method): authorize quote.totalCents plus a 15%
  buffer for waiting time and reroutes. Set payment.status='authorized',
  store intentId and authorizedCents. If authorization fails
  (insufficient funds, 3DS required, card declined), do NOT fail the service —
  set payment.status='failed', notify the client to fix or switch to cash, and
  block startService until resolved.
- 3D Secure: when the intent needs action, return the client secret to the app
  and have it complete the challenge, then confirm via a
  `confirmAuthorization` callable. Handle abandonment with a 5-minute timeout.
- On completeService: capture min(finalTotal, authorizedCents). If finalTotal
  exceeds the authorization, capture the full hold and create a second
  off-session intent for the difference; if that fails, record a debt on the
  user and notify.
- On cancellation: cancel the intent (no fee) or capture only the
  cancellation fee.
- `stripeWebhook`: raw-body HTTP function verifying the signature, handling
  payment_intent.amount_capturable_updated, .succeeded, .canceled,
  .payment_failed and charge.refunded. Idempotent by event id stored in
  webhook_events/{eventId}; return 200 for duplicates. The webhook, not the
  callable response, is the source of truth for payment.status.
- Every state change appends to services/{id}/events.

Test with Stripe test cards including 4000002500003155 (3DS required) and
4000000000000341 (attaches but fails on charge).
```

**Done when:** a declined authorization blocks `startService` and surfaces a fix-payment flow, without losing the assigned driver.

### Prompt 7.3 — Efectivo + comisiones

```
Implement the cash path and the money it implies.

- Cash services skip authorization entirely. At completeService,
  payment.status='cash_pending' and the driver app shows the exact amount to
  collect in large type, with the change from common bills (RD$ 500, 1000,
  2000) as a helper.
- `confirmCashCollected({ serviceId, amountCents })`: driver-only, requires
  status=='completed', sets cash_collected and closes the service. If the
  collected amount differs from final.totalCents, require a reason and flag it
  for admin review rather than silently accepting.
- The earnings trigger records commissionCents as a DEBT owed by the driver on
  cash jobs and as a DEDUCTION on card jobs. Maintain
  earnings/{driverId}.cashOwedCents.
- A configurable credit limit: when cashOwedCents exceeds
  config/pricing.maxCashOwedCents, the driver is excluded from cash-service
  dispatch (add the check to the candidate filter in dispatchNext) and sees a
  banner explaining how to settle.
- Admin: a `settleDriverCash({ driverId, amountCents, method, note })`
  callable writing a settlement record and reducing the balance, with an
  audit entry.

Show the client a receipt either way; the payment method is a detail, the
receipt is not.
```

**Done when:** a driver over the cash limit stops receiving cash offers but still receives card ones.

### Prompt 7.4 — Facturas con NCF + historial

```
Generate Dominican tax-compliant invoices and expose service history.

- config/ncf holds sequence ranges per type: '02' consumo (default for
  individuals) and '01' crédito fiscal (when the client supplies an RNC).
  Model as { type, prefix, current, rangeEnd, expiresAt }.
- A transactional `allocateNcf(type)` helper using a Firestore counter so two
  concurrent invoices never receive the same NCF, with an alarm when a range
  is 90% consumed.
- On service close, create invoices/{invoiceId}: serviceId, clientId, ncf,
  ncfType, client RNC/name if given, line items (banderazo, kilometraje,
  recargos, espera, peajes), subtotalCents, itbisCents (18%), totalCents,
  issuedAt. Render a PDF (pdf/printing package in a function, or a rendering
  service) to Storage invoices/{invoiceId}.pdf and store the path.
- Client app: an RNC field on the profile; if present, issue type '01'.
- History screen: paginated list of past services with date, code, route,
  status chip, total and payment method; filters by date range and status;
  detail view with the map snapshot, the timeline from services/{id}/events,
  and a "Descargar factura" button using a signed URL from a
  `getInvoiceUrl` callable (never a public Storage URL).
- The same history view, scoped by driverId, in the driver app.

Note in the README that DGII e-CF (electronic invoicing) certification is a
separate compliance project — this produces the document, not the filing.
```

**Done when:** two concurrent completions get distinct sequential NCFs and downloadable PDFs.

---

## Phase 8 — Panel admin

Flutter Web. A dispatcher lives in this screen all shift — density and keyboard speed beat animation.

**Depends on:** Phases 4, 5, 7

### Prompt 8.1 — Web shell and layout

```
Build the admin_web shell around the existing screens.

- CanvasKit renderer, deferred loading, and a real loading screen in
  index.html so the first paint is not a blank white page.
- Persistent left navigation: Operaciones (live map), Servicios, Choferes,
  Grúas, Documentos, Reportes, Configuración. Collapsible; remembers state.
- Top bar: environment badge (DEV/STG/PROD in colour), signed-in admin,
  a global search over service code / client phone / driver name / plate, and
  an alerts bell fed by needs_manual services and expiring documents.
- Responsive down to 1024 px; below that show a "usa una pantalla más grande"
  notice rather than a broken layout.
- GoRouter with URL-addressable routes (/servicios/GR-260908-0431 must be
  linkable and shareable), browser back/forward, and per-route permission
  guards from 2.3.
- Keyboard shortcuts: / focuses search, g+o goes to operations, Esc closes
  drawers.
- A shared DataTable component with server-side pagination, column sorting,
  sticky header and CSV export — every list screen uses it.
```

**Done when:** deep links work on refresh and an `ops` user sees only permitted routes.

### Prompt 8.2 — CRUD de choferes

```
Full driver management on top of the Phase 2 callables.

- List: name, cédula, phone, assigned truck, status chip, online indicator,
  acceptance rate, services this month, cash owed. Filters by status, truck
  type and zone; sortable; CSV export.
- Create: a form calling `createDriver` with client- and server-side
  validation of cédula (RD 11-digit format with check digit) and RD phone
  format. On success show the generated credentials once, with a copy button
  and a clear warning that they will not be shown again.
- Edit: name, phone, email, licence data, assigned truck. Changing the email
  updates the Auth user too.
- Activate / deactivate / suspend calling `setDriverStatus`, each requiring a
  typed reason, with a confirmation dialog that names the driver. Refuse
  deactivation while the driver has an active service and offer a
  "reassign first" link.
- Detail page: profile, documents (8.5), the last 50 services, earnings
  summary, cash-owed balance with a settle action, a live position map when
  online, and a full audit trail.
- No hard deletes. Deleting means status='inactive' plus an archived flag —
  service history must stay intact.
```

**Done when:** every mutation goes through a callable; the panel never writes `drivers/` directly.

### Prompt 8.3 — CRUD de grúas

```
Manage the fleet and its relationship to drivers.

- Callables `createTruck`, `updateTruck`, `setTruckActive`,
  `assignTruckToDriver` — admin only, each audited.
- Truck fields: placa (RD format, unique — enforce with a
  trucks_by_plate/{plate} uniqueness document written in the same
  transaction), marca, modelo, año, tipo (plataforma | gancho | pesada),
  capacidadKg, año de matrícula, seguro expiry, marbete expiry, photos.
- Assignment invariants, enforced server-side: a truck has at most one active
  driver and a driver at most one active truck; unassigning is refused while
  the driver is on service.
- The truck type is what dispatch filters on, so changing it must be blocked
  while its driver is online — force offline first with a clear message.
- List with photos, status, assigned driver, and a red badge when seguro or
  marbete expires within 30 days.
- Detail page: specs, photo gallery uploaded to Storage trucks/{id}/,
  assignment history, and services performed.
```

**Done when:** duplicate plates are impossible and a type change cannot happen mid-shift.

### Prompt 8.4 — Mapa de operaciones en vivo

```
The dispatcher's main screen — everything happening right now on one map.

- google_maps_flutter_web centered on the operating region, with:
  · every online driver, icon coloured by state (verde idle, ámbar on_service,
    gris stale) and shaped by truck type
  · every active service: pickup pin, dropoff pin, and a line between them
  · marker clustering above ~50 markers
- A left panel listing active services grouped by status, sorted by age, with
  needs_manual pinned to the top in red and a live "esperando Xm Ys" counter.
  Ring an audible alert when a new needs_manual appears.
- Selecting a service opens a right drawer: full detail, the event timeline,
  the chat transcript (read-only), payment state, and actions —
  asignar manualmente, cancelar, contactar cliente, contactar chofer,
  override arrival/completion with a mandatory reason.
- Manual assignment: a driver picker showing distance to pickup, current
  state, truck type match and acceptance rate, sorted by the same score the
  dispatcher uses. Calls `assignServiceManually`.
- Efficient data: listen to /live filtered to online drivers only, and to
  services where status is in the active set — never stream all history.
  Throttle marker rebuilds to 2 Hz.
- Auto-refresh must never move the map or close the drawer under the
  dispatcher's cursor.
```

**Done when:** a `needs_manual` service is visible and assignable within seconds of the cascade giving up.

### Prompt 8.5 — Documentos de choferes

```
Document management with expiry enforcement.

- Types: licencia de conducir, cédula, seguro del vehículo, marbete,
  matrícula, certificado médico. Configure the required set in config/app.
- Upload from the panel (and from the driver app) to
  drivers/{uid}/docs/{docType}_{timestamp}.{ext}. Max 10 MB, jpeg/png/pdf,
  validated in the Storage rules. Store metadata at
  drivers/{uid}/documents/{docType}: storagePath, uploadedAt, uploadedBy,
  issuedAt, expiresAt, state (pending | verified | rejected), reviewedBy,
  rejectionReason.
- Admin review UI: side-by-side viewer (PDF and image), approve/reject with
  a reason, and a required expiry date on approval.
- A scheduled daily function that: notifies the driver at 30, 15 and 7 days
  before expiry; on the expiry date sets the document to expired; and if a
  REQUIRED document is expired, sets drivers/{uid}.status='inactive', forces
  isOnline=false and alerts admins. A grúa on the road with expired seguro is
  a liability, so this must be automatic, not a reminder.
- A Documentos screen listing everything expiring in 30 days across the fleet,
  sorted by urgency.
- Signed URLs with a 15-minute TTL for every document view; never a public URL.
```

**Done when:** advancing the emulator clock past an expiry date takes the driver offline automatically.

---

## Phase 9 — Reportes

Pre-aggregate everything. Querying raw `services` from a dashboard is how a Firestore bill goes from tens to thousands of dollars.

**Depends on:** Phases 7, 8

### Prompt 9.1 — Rollups agregados

```
Build the aggregation layer.

- A scheduled function `rollupDaily`, 00:15 America/Santo_Domingo, writing
  reports/daily/{yyyy-MM-dd}:
  · counts by final status (completed, cancelled_by_client,
    cancelled_by_driver, needs_manual, expired)
  · grossCents, commissionCents, itbisCents; split card vs efectivo
  · median and p90 for: time to accept, time to arrive, service duration
  · dispatch health: offers sent, accept rate, average rounds to accept,
    average final radius
  · per-driver: services, gross, net, acceptance rate, average rating
  · per-zone and per-hour heat buckets
  · new clients, repeat clients
- A `rollupMonthly` composing the dailies, and a `backfillRollups(from, to)`
  callable for reprocessing.
- Idempotent: rerunning a date must overwrite, not accumulate.
- Also maintain a live reports/today document updated by the completion
  trigger so the dashboard has current-day numbers without scanning.

Everything in integer cents. Timezone bucketing in America/Santo_Domingo,
which is UTC-4 with no DST — assert that in a test.
```

**Done when:** re-running `rollupDaily` for a date produces byte-identical output.

### Prompt 9.2 — Pantalla de reportes

```
Build the Reportes screen on the rollups only.

- Date-range picker with presets: hoy, ayer, últimos 7 días, este mes,
  mes pasado, personalizado.
- KPI row: servicios completados, ingresos brutos, ticket promedio, tasa de
  cancelación, tiempo promedio de llegada, tasa de aceptación. Each with a
  delta vs the previous equivalent period.
- Charts (fl_chart): services per day (bar), revenue card vs cash (stacked),
  hourly demand heat map, and a top-10-drivers table by net earnings.
- A per-driver report with a settlement view: services, gross, commission,
  cash owed, amount settled, balance — the sheet the office actually uses to
  pay people.
- CSV and PDF export of any view, generated in a callable and delivered as a
  signed URL. Include the date range and generation timestamp in the file.
- An empty state that says which dates have no rollup yet and offers a
  backfill button for admins.

Read only from reports/**. If a number you need is not in a rollup, add it to
9.1 rather than querying services from the client.
```

**Done when:** loading a 90-day report costs a handful of document reads, not thousands.

---

## Phase 10 — Endurecimiento y release

The gap between "it works on my device" and "it works for a chofer at 3 a.m. on the Autopista Duarte with one bar of signal."

**Depends on:** everything

### Prompt 10.1 — Notificaciones, endurecidas

```
Make push delivery reliable, which it is not by default.

- Token lifecycle: store tokens at users/{uid}/tokens/{tokenId} and
  drivers/{uid}/tokens/{tokenId} with platform, appVersion, updatedAt.
  Refresh on onTokenRefresh and on every app start; delete on sign-out; and
  prune tokens the FCM response reports as UNREGISTERED or INVALID_ARGUMENT.
- A single `sendPush(target, payload)` helper handling multicast, per-token
  error handling, and structured logging of every send with its result.
- Notification categories with distinct channels, sounds and priorities:
  offers (critical, full-screen), service_updates, chat, payments, admin.
  Let users mute chat and marketing but never service_updates.
- Deep links: every payload carries { type, serviceId } and the app routes to
  the right screen from cold start, background and foreground, including the
  case where the user is not yet authenticated (queue the link until sign-in).
- Foreground presentation via flutter_local_notifications so a push is not
  silently swallowed while the app is open.
- Android 13+ POST_NOTIFICATIONS runtime request with a rationale screen;
  detect denial and show a persistent banner in the driver app explaining that
  offers will be missed.
- An in-app inbox at users/{uid}/notifications as a fallback for anything
  the OS dropped.
- A `sendTestPush` admin callable for support to debug a specific device.
```

**Done when:** every notification type is verified from cold start, background and foreground on both platforms.

### Prompt 10.2 — Observabilidad y controles

```
Instrument the system so you find out about problems before the client calls.

- Crashlytics in all three apps with the user id, role, active serviceId and
  app flavor as custom keys. Non-fatal reports for every handled callable
  failure.
- Structured JSON logging in every function: { severity, event, serviceId,
  driverId, clientId, durationMs, outcome }. Never log phone numbers, tokens
  or card data.
- Log-based metrics and alerting policies on: dispatch failure rate,
  needs_manual count per hour, offer acceptance rate below 40%, payment
  authorization failure rate, function p95 latency, and any function error
  rate above 1%. Route to email and a WhatsApp/Slack webhook.
- A /health callable checking Firestore, RTDB, the gateway and the Routes API,
  polled by an uptime check.
- Remote Config kill switches, read at startup and on every foreground:
  maintenanceMode (blocks new requests with a message), minSupportedVersion
  (forces update), enableCardPayments, enableChat, dispatchRadiusOverride.
  A force-update screen that cannot be dismissed.
- Firebase Analytics events for the request funnel: request_started,
  location_confirmed, quote_viewed, service_requested, driver_assigned,
  service_completed — so you can see where clients drop off.
- A daily ops summary function posting yesterday's KPIs to the ops channel.
```

**Done when:** killing card payments via Remote Config takes effect in running apps without a release.

### Prompt 10.3 — Pruebas y CI

```
Build the test suite and pipeline that lets you ship on a Friday.

Functions (vitest + emulator):
- Unit: pricing (every surcharge, boundary at exactly 22:00 and 06:00 local),
  truck-type inference, geo helpers, NCF allocation, state machine guards.
- Integration: the full happy path request → dispatch → accept → arrive →
  start → complete → capture → invoice; plus every cancellation branch,
  offer expiry cascade, needs_manual, double-accept race, and duplicate
  webhook delivery.
- Rules tests from 1.4.

Flutter:
- Unit tests for controllers with fake repositories.
- Widget tests for the request flow, the offer screen and the state buttons.
- Golden tests for the offer screen in both themes and two text scales.
- Integration tests (integration_test) for sign-in → request → track on the
  client app against the emulator.

CI (GitHub Actions):
- On PR: melos analyze, format check, all tests with the emulator, and a
  coverage report gate.
- On merge to main: build dev flavors, deploy functions + rules + indexes to
  the dev project, deploy admin_web to Firebase Hosting preview.
- On tag: build stg/prod, deploy to those projects behind a manual approval.
- Codemagic or Fastlane lanes for TestFlight and Play internal testing.

Target: 80% coverage on functions/, 60% on grua_core. Fail CI below that.
```

**Done when:** a PR that breaks the double-accept guarantee fails CI without a human noticing.

### Prompt 10.4 — Lanzamiento

```
Prepare all three products for release.

Stores:
- Background location is the highest-risk review item. Prepare a demo video
  showing the foreground-service notification and the dispatch use case,
  plus a written justification for both stores. Apple will ask; answer before
  they do.
- App Store: privacy nutrition labels, the driver app as a separate listing,
  and a demo account with a seeded active service for the reviewer.
- Play: data safety form, foreground-service-location declaration, target API
  level, and a signed AAB per app.
- Screenshots and store copy in es-DO for the RD market.

Legal and policy:
- Términos y condiciones and Política de privacidad in Spanish, covering
  location collection, retention (positions purged after 90 days), payment
  data handling, call recording if any, and the masked-number policy.
- Consent screens on first run with an explicit accept, stored with the
  version accepted.

Production readiness:
- Firestore backup schedule and a documented restore drill you have actually
  performed once.
- Budget alerts on the GCP project; quotas reviewed against a 3x traffic spike.
- A runbook: how to manually assign a stuck service, how to force a driver
  offline, how to refund, how to rotate the quote-signing secret, how to roll
  back functions.
- A staged rollout: 3 drivers in one zone for a week, then the full fleet.
  Add a config/app.launchZones allowlist so dispatch is geographically
  limited during the pilot.
```

**Done when:** the pilot runs a week in one zone with a runbook the office can follow without you.

---

## Sequencing and risk

**Sequencing.** Phases 0–4 are strictly serial — everything downstream depends on the schema and the dispatch engine. From Phase 5 onward you can parallelise: the driver app (5), tracking and chat (6), and the admin panel (8) touch different code. Payments (7) should not start until the merchant entity question is settled, and reports (9) need real completed services to be worth building.

**Riskiest items, in order:**

1. **iOS offer delivery on a locked phone (5.2)** — prototype on a real device early; it can change the driver app's architecture.
2. **Background location surviving Android battery optimisation (5.1)** — test on a real mid-range device, not an emulator.
3. **The card-gateway entity question (7.1)** — a business decision that blocks a whole phase.
4. **Dispatch concurrency (4.2–4.4)** — cheap to get right with emulator tests, expensive to debug in production.

---

## Checklist

### Phase 0 — Cimientos
- [ ] 0.1 Monorepo scaffold
- [ ] 0.2 Firebase + App Check
- [ ] 0.3 CLAUDE.md, the spec of record
- [ ] 0.4 Emulator suite + seed data

### Phase 1 — Modelo de datos
- [ ] 1.1 Dart models in grua_core
- [ ] 1.2 Paths, converters, repositories
- [ ] 1.3 Security rules + indexes
- [ ] 1.4 Rules unit tests

### Phase 2 — Auth y roles
- [ ] 2.1 Client phone OTP
- [ ] 2.2 Driver accounts + custom claims
- [ ] 2.3 Admin claims + route guards

### Phase 3 — Solicitud del cliente
- [ ] 3.1 Location, permissions, geocoding
- [ ] 3.2 Pickup / dropoff selection
- [ ] 3.3 Vehicle + condition → truck type
- [ ] 3.4 quoteService + requestService

### Phase 4 — Motor de despacho
- [ ] 4.1 Live driver index
- [ ] 4.2 State machine + dispatchNext
- [ ] 4.3 Offer expiry + cascade
- [ ] 4.4 accept / reject / manual assign

### Phase 5 — App chofer
- [ ] 5.1 Online toggle + background location
- [ ] 5.2 Incoming offer, the ringing screen
- [ ] 5.3 Navigation to pickup
- [ ] 5.4 Llegué · Iniciar · Finalizar
- [ ] 5.5 Ganancias del chofer

### Phase 6 — Tracking, chat y llamadas
- [ ] 6.1 Live tracking for the client
- [ ] 6.2 In-app chat
- [ ] 6.3 Calling, with number masking

### Phase 7 — Pagos y facturación
- [ ] 7.1 PaymentGateway abstraction + Stripe setup
- [ ] 7.2 Authorize on accept, capture on complete
- [ ] 7.3 Efectivo + comisiones
- [ ] 7.4 Facturas con NCF + historial

### Phase 8 — Panel admin
- [ ] 8.1 Web shell and layout
- [ ] 8.2 CRUD de choferes
- [ ] 8.3 CRUD de grúas
- [ ] 8.4 Mapa de operaciones en vivo
- [ ] 8.5 Documentos de choferes

### Phase 9 — Reportes
- [ ] 9.1 Rollups agregados
- [ ] 9.2 Pantalla de reportes

### Phase 10 — Endurecimiento y release
- [ ] 10.1 Notificaciones, endurecidas
- [ ] 10.2 Observabilidad y controles
- [ ] 10.3 Pruebas y CI
- [ ] 10.4 Lanzamiento
