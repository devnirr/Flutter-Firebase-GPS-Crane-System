import { readFileSync } from 'node:fs';

import type { RulesTestEnvironment } from '@firebase/rules-unit-testing';
import { afterAll, beforeAll, describe, it } from 'vitest';

/**
 * Who may put a photo in a job's folder.
 *
 * Needs the Storage emulator next to Firestore's:
 *
 *     firebase emulators:exec --only firestore,database,auth,storage "vitest run"
 */

const FIRESTORE = process.env['FIRESTORE_EMULATOR_HOST'];
const STORAGE = process.env['FIREBASE_STORAGE_EMULATOR_HOST'];
const describeEmulator = FIRESTORE && STORAGE ? describe : describe.skip;

function hostPort(value: string): { host: string; port: number } {
  const clean = value.replace(/^https?:\/\//, '');
  const at = clean.lastIndexOf(':');
  return { host: clean.slice(0, at), port: Number(clean.slice(at + 1)) };
}

let rut: typeof import('@firebase/rules-unit-testing');
let env: RulesTestEnvironment;

const photo = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]);

describeEmulator('service photo storage rules', () => {
  beforeAll(async () => {
    rut = await import('@firebase/rules-unit-testing');
    env = await rut.initializeTestEnvironment({
      // The Storage emulator reads Firestore in this project for its rules.
      projectId: process.env['GCLOUD_PROJECT'] ?? 'demo-grua',
      firestore: {
        ...hostPort(FIRESTORE!),
        rules: readFileSync(new URL('../../firestore.rules', import.meta.url), 'utf8'),
      },
      storage: {
        ...hostPort(STORAGE!),
        rules: readFileSync(new URL('../../storage.rules', import.meta.url), 'utf8'),
      },
    });
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc('services/photo-job').set({ driverId: 'd1', status: 'arrived' });
    });
  }, 60_000);

  afterAll(async () => {
    await env?.cleanup();
  });

  const upload = async (uid: string | null, path: string, contentType = 'image/jpeg') => {
    const ctx = uid ? env.authenticatedContext(uid) : env.unauthenticatedContext();
    return await ctx.storage().ref(path).put(photo, { contentType });
  };

  it('lets the chofer on the job upload its photos', async () => {
    await rut.assertSucceeds(upload('d1', 'service_photos/photo-job/pickup-1.jpg'));
  });

  it('refuses anyone else, and a job that does not exist', async () => {
    await rut.assertFails(upload('d2', 'service_photos/photo-job/pickup-2.jpg'));
    await rut.assertFails(upload('client-1', 'service_photos/photo-job/x.jpg'));
    await rut.assertFails(upload(null, 'service_photos/photo-job/x.jpg'));
    await rut.assertFails(upload('d1', 'service_photos/no-such-job/x.jpg'));
  });

  it('refuses a file that is not a photo or a PDF', async () => {
    await rut.assertFails(upload('d1', 'service_photos/photo-job/x.exe', 'application/octet-stream'));
  });

  it('keeps the photos from being read directly', async () => {
    await rut.assertFails(
      env.authenticatedContext('d1').storage().ref('service_photos/photo-job/pickup-1.jpg').getMetadata(),
    );
  });
});
