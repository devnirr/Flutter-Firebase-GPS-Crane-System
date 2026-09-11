/**
 * Pure rules for the fleet, kept apart from the callables so they can be
 * tested without Firestore.
 */

/** The heaviest recovery truck in the country is well under this. */
export const MAX_CAPACITY_KG = 60_000;

/** Older than this is not a grúa anybody insures. */
export const MIN_TRUCK_YEAR = 1970;

/**
 * A plate as it is keyed and compared: uppercase, no spaces or dashes.
 *
 * The office types what is on the metal — "l-123 456", "L123456" — and all of
 * those have to land on the same `trucks_by_plate` document, or the uniqueness
 * check is a formality.
 */
export function normalizePlate(raw: string): string {
  return raw.toUpperCase().replace(/[^A-Z0-9]/g, '');
}

/**
 * Dominican plates are a series of one or two letters and five or six digits:
 * `L123456` for a commercial vehicle, `EX12345` for some older series. Anything
 * else is a typo, and a typo here is a grúa the customer cannot identify.
 */
export function isValidPlate(normalized: string): boolean {
  return /^[A-Z]{1,2}\d{5,6}$/.test(normalized);
}

/** The newest model year a truck can have: dealers sell next year's in autumn. */
export function maxTruckYear(now: Date = new Date()): number {
  return now.getFullYear() + 1;
}
