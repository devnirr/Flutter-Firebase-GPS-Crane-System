# Grúas RD 24/7

Tow-truck dispatch for the Dominican Republic: a customer app, a chofer app and
an operations panel, sharing one domain layer.

See [prompt.md](prompt.md) for the full build playbook — the Firestore schema,
the service state machine and the dispatch algorithm.

---

## Running it

Everything runs today against an **in-memory demo backend** that implements the
real state machine and the real pricing. No Firebase project, no API keys, no
account. You can walk the whole flow — request, dispatch, tow, cash — offline.

```bash
flutter pub get          # once, from the repo root
```

Then pick an app:

```bash
cd apps/client_app && flutter run -d chrome    # customer
cd apps/driver_app && flutter run -d chrome --web-port 50166   # chofer
cd apps/admin_web  && flutter run -d chrome --web-port 5000    # operations panel
```

Or from the repo root, via Melos:

```bash
dart pub global activate melos   # once
melos run run:client
melos run run:driver
melos run run:admin
```

**The two phone apps also run on Android and iOS** — `flutter run` with a
device or emulator attached. Chrome is just the fastest way to look at them:
they frame themselves at phone size in a desktop browser, because a
portrait-locked layout stretched across a 1920-px window is not the product.

The operations panel needs a window at least 1024 px wide. Below that it says
so rather than reflowing — a live dispatch map squeezed onto a phone is a worse
tool than an honest message.

### What you'll see

| App | Signs in as | Try this |
|---|---|---|
| **client_app** | Any RD phone number, then **any 6 digits** as the code | Pedir grúa → pick the two points on the map → confirm the price. A chofer is assigned after ~6 s and the truck moves across the map. |
| **driver_app** | Any email, any password ≥ 4 chars | Go **En línea**, accept a pedido, then walk Llegué → Iniciar → Finalizar → Cobrar. |
| **admin_web** | Any email, any password ≥ 4 chars | The live map, the queue with `needs_manual` pinned to the top, the driver roster and the fleet. |

The demo backend accepts anything that looks valid because it enforces nothing —
authorisation, concurrency and money are the server's job. It exists so the UI
can be built and reviewed before the backend is deployed, and so widget tests
run without a network. Never point it at a real customer.

---

## Tests

```bash
melos run test           # all packages
melos run analyze        # static analysis
```

Or per package: `cd packages/grua_core && flutter test`.

The suite covers the pricing boundaries most likely to be wrong without anyone
noticing (the night surcharge at exactly 22:00 and 06:00 *local*, ITBIS,
cancellation grace), the full service lifecycle through its real guards, and
the rule that a chofer cannot go offline while holding a job.

---

## Connecting Firebase

The Firestore, Realtime Database and Storage rules, the indexes, the emulator
config and the real repository implementations are all written. What is missing
is a project, which needs your Google account.

The apps fall back to the demo backend when Firebase is not configured, so
nothing breaks while you work through this.

### 1. Install the CLIs

```bash
npm install -g firebase-tools          # already installed here
dart pub global activate flutterfire_cli
```

The emulator suite also needs **Java 11+** (`java -version`). Install a JDK if
you do not have one — Firestore and Database emulators are Java processes.

### 2. Sign in and create the project

```bash
firebase login
firebase projects:create grua-rd-dev --display-name "Grúas RD (dev)"
```

Then in the Firebase console, enable:

- **Authentication** → Phone (customers) and Email/Password (choferes, staff)
- **Firestore** → production mode, region `nam5` or `us-east1`
- **Realtime Database** → the live-position index is in `database.rules.json`
- **Storage**
- **Blaze plan** — Cloud Functions and the Routes API both require it

### 3. Generate the Dart config

```bash
cd apps/client_app && flutterfire configure --project=grua-rd-dev
cd ../driver_app  && flutterfire configure --project=grua-rd-dev
cd ../admin_web   && flutterfire configure --project=grua-rd-dev
```

This writes `lib/firebase_options.dart` in each app. Those files are
gitignored — they carry per-project keys, and every developer regenerates them.

Then pass the options into the shared bootstrap, in each app's `main.dart`:

```dart
import 'firebase_options.dart';

void main() => runGruaApp(
      appKind: AppKind.client,
      builder: ClientApp.new,
      firebaseOptions: DefaultFirebaseOptions.currentPlatform,   // add this
    );
```

That one argument is the whole switch. With it the apps use Firestore; without
it they use the demo backend, and neither the screens nor the tests change.

### 4. Enable the services

Five steps in the console, one click each. Firestore rules deploy without
them, but the rest do not:

| Console page | Why |
|---|---|
| **Authentication** → Sign-in method → enable **Phone** and **Email/Password** | Customers sign in by phone; choferes and staff by email |
| **Authentication** → Settings → **SMS region policy** → allow **Dominican Republic** | Every SMS is refused until the region is allowed, test numbers included |
| **Realtime Database** → Create Database → **us-central1** | Live truck positions |
| **Storage** → Get Started | Driver documents and service photos |
| **Upgrade to Blaze** | Cloud Functions, the Routes API, and Storage on projects created after Oct 2024 |

**App Check is not enforced, in two places.** The callables read
`ENFORCE_APP_CHECK` and leave it off by default, and `ok()` in `firestore.rules`
checks only `isSignedIn()`. Neither is an oversight: no client calls
`FirebaseAppCheck.instance.activate()` yet, so requiring a token rejects every
callable and denies every read and write the apps make. It protects nothing and
takes the product offline.

Turning it on is one change with four parts, all together or none: provision App
Check in the console, call `activate()` in the Flutter bootstrap, put
`hasAppCheck()` back into `ok()`, and set `ENFORCE_APP_CHECK=true` on the
functions. Do it before real customers, not after — retrofitting it later means
a forced-update release.

**Granting the first admin.** Staff access is a custom claim, not a field, and
nothing in the panel can grant it to itself. Put the address on the allowlist
the `bootstrapFirstAdmin` callable reads — `functions/.env` is gitignored, so
each machine needs its own:

```
ADMIN_BOOTSTRAP_EMAILS=you@example.com
```

Deploy, then sign in on the panel with that account. It will refuse you once and
offer **"Soy el primer administrador"**; that button claims the role and is
permanently inert afterwards. Further staff are granted with `setAdminRole`.

The Realtime Database and Storage buckets cannot be created from the CLI —
`firebase database:instances:create` refuses to make the *default* instance and
points you at `firebase init database`, which is interactive.

### 5. Push the rules

```bash
firebase deploy --only "firestore:rules,firestore:indexes,database,storage"
```

**Quote the target in PowerShell.** Always, even for a single one. Without
quotes PowerShell eats the commas in a list, and it also treats a bare
`firestore:rules` as a scope-qualified name rather than an argument. Either way
the CLI never sees the target and answers
`Cannot understand what targets to deploy`. So `--only "firestore:rules"`, not
`--only firestore:rules`.

### 6. Or skip the cloud and use the emulator

Nothing above is needed to run the real Firestore code locally:

```bash
firebase emulators:start          # needs Java
```

Then run any app with `--dart-define=USE_EMULATORS=true`. The SDKs are pointed
at localhost automatically, and the emulator UI is at http://localhost:4000.

### What the rules enforce

The governing rule is that **the apps read and the server writes**. Every field
that decides who is assigned, who gets paid, or what a tow costs is written only
by a Cloud Function through the Admin SDK, which bypasses rules entirely — so
those collections are `allow write: if false` rather than a clever condition. A
rule that can be reasoned about wrongly is worse than one that cannot be written
at all.

Chat is the single exception: messages are written straight from the apps so
they land instantly, and the constraints on that one write are correspondingly
specific — the sender must be the author, the service must be theirs and still
open, the text 1–1000 characters, and no other field may appear.

App Check is required on every rule. Retrofitting it after launch means a
forced-update release.

---

## Turning on real maps

Without a Maps API key the apps draw a schematic map — a correctly projected
street grid with the markers in the right places. It is a real fallback, not a
placeholder: every screen is honest about its layout without a billed key.

To use Google Maps instead:

1. In Google Cloud Console, create an API key and enable **Maps SDK for
   Android**, **Maps SDK for iOS**, **Geocoding API** and **Routes API**.
2. Restrict it — Android by package name + SHA-1, iOS by bundle ID, web by
   HTTP referrer.
3. Supply it in three places:

```bash
# Dart side (all platforms)
flutter run --dart-define=GOOGLE_MAPS_API_KEY=YOUR_KEY

# Android native SDK
MAPS_API_KEY=YOUR_KEY flutter build apk

# iOS native SDK: add MAPS_API_KEY to the Xcode build settings / xcconfig
```

The native wiring is already applied. If you ever re-run `flutter create`,
re-apply it with:

```bash
node scripts/configure_platforms.mjs   # idempotent
```

---

## Configuration

`config/dev.json` is committed and holds no secrets — empty keys and the dev
project id — so a fresh clone runs with no setup. Copy
`config/prod.example.json` to `config/prod.json` for real keys;
`config/stg.json` and `config/prod.json` are gitignored.

```bash
flutter run --dart-define-from-file=../../config/dev.json
```

`AppConfig.assertProductionReady()` throws at startup if a production build is
missing a key or still points at dev, so a misconfigured release fails loudly
rather than quietly talking to the wrong project.

---

## Layout

```
packages/grua_core/   models, state machine, pricing, repositories, brand, maps
apps/client_app/      customer  — Android, iOS, web
apps/driver_app/      chofer    — Android, iOS, web
apps/admin_web/       operations panel — web
config/               per-environment build settings
scripts/              native platform configuration
```

`grua_core` is the only thing the three apps share. Anything that must behave
identically in more than one of them — the service state machine, the pricing
formula, money formatting, the brand — lives there so it cannot drift.

---

## Not built yet

- **Cloud Functions**: the dispatch cascade, the transition guards, payments.
  The demo backend stands in for these and implements the same rules.
- **Firestore security rules** and the emulator suite.
- **Places Autocomplete**: the picker resolves an address from the pin rather
  than searching for one.
- **Routes API**: distance is a straight line × 1.35 in the demo. The real call
  belongs server-side in `quoteService`, so it lands with the functions.
- **Gradle product flavors**: they only exist to point builds at different
  Firebase projects, so they land with the projects.
