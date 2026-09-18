import { readFileSync } from 'node:fs';

/**
 * Emulator plumbing shared by the suites that run against it.
 */

/**
 * Points this test file's Admin SDK at a project of its own.
 *
 * `dispatch.emulator.test.ts` wipes `services`, `drivers` and `users` between
 * its cases, in the default project, while other files run in parallel. A
 * suite that needs those collections to hold still gets its own project; the
 * emulators keep each project's data apart. Call before importing anything
 * that touches the Admin SDK.
 */
export function useIsolatedProject(projectId: string): void {
  process.env['GCLOUD_PROJECT'] = projectId;
  process.env['FIREBASE_CONFIG'] = JSON.stringify({
    projectId,
    databaseURL: `https://${projectId}-default-rtdb.firebaseio.com`,
    storageBucket: `${projectId}.appspot.com`,
  });
  // Skips Cloud Tasks and allows the emulator-only signing secret.
  process.env['FUNCTIONS_EMULATOR'] = 'true';
}

/**
 * Loads `database.rules.json` into the namespace the Admin SDK talks to.
 *
 * The emulator applies the file to `<project>-default-rtdb`, but
 * `emulators:exec` hands the SDK a `databaseURL` of `<project>.firebaseio.com`
 * when it cannot look the real instance up — so the SDK lands in a namespace
 * with no rules, and every `orderByChild('isOnline')` fails with "Index not
 * defined". Rules for the Admin SDK are otherwise moot; the indexes are not.
 */
export async function loadRtdbRulesForAdmin(): Promise<void> {
  const host = process.env['FIREBASE_DATABASE_EMULATOR_HOST'];
  if (!host) return;

  const config = JSON.parse(process.env['FIREBASE_CONFIG'] ?? '{}') as {
    databaseURL?: string;
  };
  const url =
    config.databaseURL ??
    `https://${process.env['GCLOUD_PROJECT']}-default-rtdb.firebaseio.com`;
  const namespace = new URL(url).hostname.split('.')[0];
  const rules = readFileSync(new URL('../../../database.rules.json', import.meta.url), 'utf8');

  const res = await fetch(`http://${host}/.settings/rules.json?ns=${namespace}`, {
    method: 'PUT',
    headers: { Authorization: 'Bearer owner' },
    body: rules,
  });
  if (!res.ok) {
    throw new Error(`Could not load RTDB rules into ${namespace}: ${res.status} ${await res.text()}`);
  }
}
