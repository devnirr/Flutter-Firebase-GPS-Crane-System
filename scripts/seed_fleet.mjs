#!/usr/bin/env node
/**
 * Puts a sample fleet on a real project: ten grúas and ten choferes, each
 * chofer on one grúa, every account active and able to sign in.
 *
 * Why this calls the deployed callables instead of writing Firestore with the
 * Admin SDK: `createTruck`, `createDriver` and `setDriverStatus` are where the
 * plate uniqueness index, the cédula check, the custom claims and the driver
 * document's defaults all live. Writing the documents directly would produce a
 * roster that looks right and a fleet that dispatch cannot use.
 *
 * It signs in as a human admin, so it needs no service account:
 *
 *   ADMIN_EMAIL=you@example.com ADMIN_PASSWORD=... node scripts/seed_fleet.mjs
 *
 * Options:
 *   COUNT=10                how many of each
 *   PASSWORD=123123         the password every chofer gets
 *   PROJECT_ID / REGION / WEB_API_KEY   to point it somewhere else
 *   DRY_RUN=1               print what it would create and stop
 */

const PROJECT_ID = process.env.PROJECT_ID ?? 'gruasrd-ce2ae';
const REGION = process.env.REGION ?? 'us-east1';
// The web key from `firebase_options.dart`: public by design, it only lets you
// attempt a sign-in.
const WEB_API_KEY =
  process.env.WEB_API_KEY ?? 'AIzaSyAw6Hw78cHjWARv7RKN1qjJsnHL9qyOM_4';

const COUNT = Number(process.env.COUNT ?? 10);
const PASSWORD = process.env.PASSWORD ?? '123123';
const DRY_RUN = process.env.DRY_RUN === '1';

const ADMIN_EMAIL = process.env.ADMIN_EMAIL;
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD;

/** The JCE's check digit: alternating 1/2 weights over the first ten. */
function cedulaCheckDigit(first10) {
  let sum = 0;
  for (let i = 0; i < 10; i++) {
    let product = Number(first10[i]) * (i % 2 === 0 ? 1 : 2);
    if (product > 9) product -= 9;
    sum += product;
  }
  return (10 - (sum % 10)) % 10;
}

const cedulaFor = (index) => {
  const first10 = `402300${String(index).padStart(4, '0')}`;
  return `${first10}${cedulaCheckDigit(first10)}`;
};

const inYears = (years) => {
  const date = new Date();
  date.setFullYear(date.getFullYear() + years);
  return date.toISOString();
};

/** Ten grúas that read like a real yard: three types, plausible capacities. */
const TRUCK_SPECS = [
  ['Isuzu', 'NPR 75', 'plataforma', 3500, 'Blanco', 2019],
  ['Hino', '300 916', 'gancho', 3000, 'Amarillo', 2020],
  ['Mitsubishi Fuso', 'Canter FE85', 'plataforma', 4000, 'Blanco', 2021],
  ['Ford', 'F-350 Super Duty', 'gancho', 2800, 'Rojo', 2018],
  ['Freightliner', 'M2 106', 'pesada', 18000, 'Azul', 2017],
  ['Isuzu', 'FTR', 'plataforma', 6500, 'Blanco', 2022],
  ['Chevrolet', 'NPR 4500', 'gancho', 3200, 'Gris', 2019],
  ['International', 'DuraStar 4300', 'pesada', 22000, 'Blanco', 2016],
  ['Hino', '500 1726', 'plataforma', 8000, 'Verde', 2021],
  ['Kenworth', 'T370', 'pesada', 25000, 'Negro', 2018],
];

const DRIVER_NAMES = [
  'Ramón Peralta Núñez',
  'Luis Alberto Mejía',
  'Jorge Encarnación Díaz',
  'Elvin Santana Reyes',
  'Junior Castillo Mota',
  'Pedro Aybar Ventura',
  'Wilson Jiménez Cruz',
  'Manuel Guzmán Polanco',
  'Félix de la Rosa',
  'Ángel Batista Solano',
];

const ZONES = [
  ['Distrito Nacional'],
  ['Santo Domingo Este'],
  ['Santo Domingo Norte'],
  ['Santo Domingo Oeste'],
  ['Distrito Nacional', 'Santo Domingo Este'],
];

function truckInput(index) {
  const [make, model, type, capacityKg, color, year] =
    TRUCK_SPECS[(index - 1) % TRUCK_SPECS.length];
  return {
    // One or two letters and five or six digits, as `isValidPlate` requires.
    plate: `L3010${String(index).padStart(2, '0')}`,
    make,
    model,
    year,
    color,
    type,
    capacityKg,
    registrationNumber: `RV-3010${String(index).padStart(2, '0')}`,
    insurancePolicy: `POL-2026-${String(index).padStart(4, '0')}`,
    insuranceExpiry: inYears(1),
    marbeteExpiry: inYears(1),
  };
}

function driverInput(index, truckId) {
  const padded = String(index).padStart(2, '0');
  return {
    name: DRIVER_NAMES[(index - 1) % DRIVER_NAMES.length],
    cedula: cedulaFor(index),
    phone: `+18095557${padded}0`,
    email: `chofer${padded}@gruasrd.test`,
    licenseNumber: `LIC-3010${padded}`,
    licenseExpiry: inYears(2),
    truckId,
    zones: ZONES[(index - 1) % ZONES.length],
    companyName: 'Grúas RD 24/7',
    rnc: '',
    initialPassword: PASSWORD,
  };
}

async function signIn() {
  const response = await fetch(
    `https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=${WEB_API_KEY}`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        email: ADMIN_EMAIL,
        password: ADMIN_PASSWORD,
        returnSecureToken: true,
      }),
    },
  );
  const body = await response.json();
  if (!response.ok) {
    throw new Error(
      `Sign-in failed: ${body?.error?.message ?? response.statusText}`,
    );
  }
  return body.idToken;
}

/** Calls one callable the way the apps do, and unwraps its error shape. */
async function call(name, data, idToken) {
  const response = await fetch(
    `https://${REGION}-${PROJECT_ID}.cloudfunctions.net/${name}`,
    {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${idToken}`,
      },
      body: JSON.stringify({ data }),
    },
  );

  const body = await response.json().catch(() => ({}));
  if (!response.ok || body.error) {
    const error = body.error ?? {};
    throw new Error(
      `${name} refused: ${error.status ?? response.status} ${
        error.message ?? response.statusText
      }`,
    );
  }
  return body.result;
}

async function main() {
  if (DRY_RUN) {
    for (let i = 1; i <= COUNT; i++) {
      const truck = truckInput(i);
      const driver = driverInput(i, '<truckId>');
      console.log(
        `${truck.plate.padEnd(8)} ${truck.type.padEnd(11)} ${String(
          truck.capacityKg,
        ).padStart(6)} kg   ${driver.email.padEnd(26)} ${driver.cedula}  ${
          driver.name
        }`,
      );
    }
    return;
  }

  if (!ADMIN_EMAIL || !ADMIN_PASSWORD) {
    console.error(
      'Set ADMIN_EMAIL and ADMIN_PASSWORD (an admin of this project).',
    );
    process.exit(1);
  }

  console.log(`Signing in as ${ADMIN_EMAIL} on ${PROJECT_ID}…`);
  const idToken = await signIn();

  const who = await call('whoAmI', {}, idToken);
  if (who?.role !== 'admin' && who?.role !== 'ops') {
    throw new Error(`That account is "${who?.role ?? 'unknown'}", not admin.`);
  }

  const created = [];
  for (let index = 1; index <= COUNT; index++) {
    const truck = truckInput(index);
    let truckId;
    try {
      ({ truckId } = await call('createTruck', truck, idToken));
      console.log(`grúa  ${truck.plate}  ${truck.type}  ${truckId}`);
    } catch (error) {
      // A plate already on the fleet is not a reason to stop; the chofer for
      // this slot is skipped with it, since they would have no grúa.
      console.warn(`grúa  ${truck.plate}  skipped — ${error.message}`);
      continue;
    }

    const driver = driverInput(index, truckId);
    try {
      const { driverId } = await call('createDriver', driver, idToken);
      // Created accounts land `inactive` on purpose. Sample data is only
      // useful once it can take work.
      await call(
        'setDriverStatus',
        {
          driverId,
          status: 'active',
          reason: 'Datos de prueba',
        },
        idToken,
      );
      created.push({ ...driver, driverId, plate: truck.plate });
      console.log(`chofer ${driver.email}  ${driver.name}  ${driverId}`);
    } catch (error) {
      console.warn(`chofer ${driver.email}  skipped — ${error.message}`);
    }
  }

  console.log(`\n${created.length} chofer(es) listos. Contraseña: ${PASSWORD}`);
  for (const driver of created) {
    console.log(
      `  ${driver.email.padEnd(26)} ${driver.cedula}  ${driver.phone}  ${
        driver.plate
      }  ${driver.name}`,
    );
  }
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
