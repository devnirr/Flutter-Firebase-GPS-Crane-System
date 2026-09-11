/**
 * Dominican time.
 *
 * The Dominican Republic is UTC-4 year round — Atlantic Standard Time, no
 * daylight saving since 2000. That one fact lets the backend avoid a timezone
 * database, but it has to be applied deliberately: the night surcharge, the
 * daily rollup boundary and every displayed timestamp all depend on it, and a
 * UTC hour used as a local hour bills the 22:00 surcharge from 6 p.m.
 *
 * Ported from `packages/grua_core/lib/src/utils/date_time_do.dart`.
 */

const OFFSET_MS = -4 * 60 * 60 * 1000;

/** Dominican wall-clock time for an instant. */
export const toLocal = (instant: Date): Date =>
  new Date(instant.getTime() + OFFSET_MS);

/** The UTC instant for Dominican wall-clock fields. */
export const fromLocal = (local: Date): Date =>
  new Date(local.getTime() - OFFSET_MS);

/** Local hour, 0-23. What the night surcharge is decided on. */
export const localHour = (instant: Date): number => toLocal(instant).getUTCHours();

/**
 * `2026-09-08` in Dominican local time.
 *
 * Daily rollups key on this, so "yesterday's revenue" means the day the office
 * actually worked rather than a UTC window straddling two of them.
 */
export function dateKey(instant: Date): string {
  const local = toLocal(instant);
  const y = local.getUTCFullYear().toString().padStart(4, '0');
  const m = (local.getUTCMonth() + 1).toString().padStart(2, '0');
  const d = local.getUTCDate().toString().padStart(2, '0');
  return `${y}-${m}-${d}`;
}

/** Local midnight starting the day containing [instant], as a UTC instant. */
export function startOfLocalDay(instant: Date): Date {
  const local = toLocal(instant);
  return fromLocal(
    new Date(
      Date.UTC(local.getUTCFullYear(), local.getUTCMonth(), local.getUTCDate()),
    ),
  );
}

export const endOfLocalDay = (instant: Date): Date =>
  new Date(startOfLocalDay(instant).getTime() + 24 * 60 * 60 * 1000);

/**
 * `GR-260908-0431` — the code both parties quote on the phone.
 *
 * Dated in local time so a code minted at 9 p.m. carries the day the customer
 * would name. The suffix is random rather than sequential: a counter would need
 * a transaction on every request, and the code only has to be unambiguous in
 * conversation, not unique forever.
 */
export function serviceCode(instant: Date, random = Math.random): string {
  const local = toLocal(instant);
  const yy = (local.getUTCFullYear() % 100).toString().padStart(2, '0');
  const mm = (local.getUTCMonth() + 1).toString().padStart(2, '0');
  const dd = local.getUTCDate().toString().padStart(2, '0');

  // Crockford-ish: no I, L, O or U, so nothing is misread over a bad line.
  const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  let suffix = '';
  for (let i = 0; i < 4; i++) {
    suffix += alphabet[Math.floor(random() * alphabet.length)];
  }

  return `GR-${yy}${mm}${dd}-${suffix}`;
}
