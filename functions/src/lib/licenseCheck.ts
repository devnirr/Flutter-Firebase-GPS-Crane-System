import { LicenseVerificationState } from './enums.js';
import { dateKey } from './time.js';

/**
 * Deciding a licence check from what the model read off the card.
 *
 * The model only reads: it says what is printed and whether the faces look
 * alike. Every comparison with what the chofer typed, and the verdict itself,
 * happens here in plain code. A model can be talked into saying "verified" by
 * a photo of a note that says so; it cannot be talked into making two cédula
 * numbers equal.
 */

/** What the model reports about the two sides and the profile photo. */
export interface LicenseReading {
  /** The front is a Dominican driver's licence. */
  frontIsLicense: boolean;
  /** The back is the back of a Dominican driver's licence. */
  backIsLicense: boolean;
  /** How readable the two photos are, taken together. */
  imageQuality: 'good' | 'poor' | 'unreadable';
  fullName: string;
  cedula: string;
  licenseNumber: string;
  /** `YYYY-MM-DD`, or '' when it cannot be read. */
  expiryDate: string;
  /** The face on the licence against the profile photo. */
  faceMatch: 'match' | 'no_match' | 'unclear' | 'no_face';
  /** Signs of editing, a screen photo, a printout or a paper copy. */
  tamperingSuspected: boolean;
  notes: string;
}

/** What the chofer typed at registration. */
export interface LicenseClaim {
  name: string;
  cedula: string;
  licenseNumber: string;
  licenseExpiry: Date | null;
}

export type CheckResult = 'pass' | 'fail' | 'unclear';

export interface LicenseCheck {
  key: string;
  label: string;
  result: CheckResult;
  detail: string;
}

export interface LicenseVerdict {
  state:
    | typeof LicenseVerificationState.verified
    | typeof LicenseVerificationState.rejected
    | typeof LicenseVerificationState.manualReview;
  /** Shown to the chofer, so it says what to do rather than what went wrong. */
  reason: string;
  checks: LicenseCheck[];
}

/** Automatic tries before the office takes over. */
export const MAX_LICENSE_ATTEMPTS = 3;

/** Uppercase letters and spaces, accents dropped: `José  Núñez` → `JOSE NUNEZ`. */
export function normalizeName(raw: string): string[] {
  return raw
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toUpperCase()
    .replace(/[^A-Z\s]/g, ' ')
    .split(/\s+/)
    .filter((t) => t.length > 0);
}

const digits = (raw: string): string => raw.replace(/\D/g, '');
const alnum = (raw: string): string => raw.toUpperCase().replace(/[^A-Z0-9]/g, '');

/**
 * Every name the chofer typed appears on the card: a chofer who leaves out a
 * second surname still passes, one who types somebody else's does not. Two
 * shared names with a stray one is left to a person rather than refused.
 */
export function compareNames(typed: string, printed: string): CheckResult {
  const want = normalizeName(typed);
  const have = new Set(normalizeName(printed));
  if (have.size === 0 || want.length === 0) return 'unclear';
  const found = want.filter((t) => have.has(t)).length;
  if (found === want.length) return 'pass';
  if (found >= 2) return 'unclear';
  return 'fail';
}

export function compareCedula(typed: string, printed: string): CheckResult {
  const card = digits(printed);
  if (card.length !== 11) return 'unclear';
  return card === digits(typed) ? 'pass' : 'fail';
}

/**
 * Dominican licences have used the cédula as the licence number, so a card
 * showing the cédula where the chofer typed it counts as a match.
 */
export function compareLicenseNumber(
  typed: string,
  printed: string,
  cedula: string,
): CheckResult {
  const card = alnum(printed);
  if (card.length === 0) return 'unclear';
  const want = alnum(typed);
  if (card === want) return 'pass';
  if (digits(card) !== '' && digits(card) === digits(want)) return 'pass';
  if (digits(card) === digits(cedula) && digits(want) === digits(cedula)) return 'pass';
  return 'fail';
}

const isoDate = /^\d{4}-\d{2}-\d{2}$/;

/** Builds the checks and decides. [now] is injected for the tests. */
export function decideLicense(
  reading: LicenseReading,
  claim: LicenseClaim,
  now: Date,
  options: { hasProfilePhoto: boolean },
): LicenseVerdict {
  const checks: LicenseCheck[] = [];
  const add = (key: string, label: string, result: CheckResult, detail = '') =>
    checks.push({ key, label, result, detail });

  const isLicense = reading.frontIsLicense && reading.backIsLicense;
  add(
    'document',
    'Es una licencia de conducir (frente y reverso)',
    isLicense ? 'pass' : 'fail',
    !reading.frontIsLicense
      ? 'El frente no parece una licencia dominicana.'
      : !reading.backIsLicense
        ? 'El reverso no parece el de una licencia dominicana.'
        : '',
  );

  add(
    'legible',
    'Las fotos se leen con claridad',
    reading.imageQuality === 'good'
      ? 'pass'
      : reading.imageQuality === 'poor'
        ? 'unclear'
        : 'fail',
    reading.imageQuality === 'good' ? '' : 'Foto borrosa, oscura o cortada.',
  );

  add(
    'integrity',
    'Sin señales de alteración',
    reading.tamperingSuspected ? 'unclear' : 'pass',
    reading.tamperingSuspected ? reading.notes || 'Posible edición o copia.' : '',
  );

  add(
    'name',
    'El nombre coincide',
    compareNames(claim.name, reading.fullName),
    `Escrito: ${claim.name} · En la licencia: ${reading.fullName || '—'}`,
  );

  add(
    'cedula',
    'La cédula coincide',
    compareCedula(claim.cedula, reading.cedula),
    `Escrita: ${claim.cedula} · En la licencia: ${reading.cedula || '—'}`,
  );

  add(
    'licenseNumber',
    'El número de licencia coincide',
    compareLicenseNumber(claim.licenseNumber, reading.licenseNumber, claim.cedula),
    `Escrito: ${claim.licenseNumber} · En la licencia: ${reading.licenseNumber || '—'}`,
  );

  const printedExpiry = isoDate.test(reading.expiryDate) ? reading.expiryDate : '';
  const typedExpiry = claim.licenseExpiry ? dateKey(claim.licenseExpiry) : '';
  add(
    'expiryMatches',
    'La fecha de vencimiento coincide',
    printedExpiry === '' || typedExpiry === ''
      ? 'unclear'
      : printedExpiry === typedExpiry
        ? 'pass'
        : 'fail',
    `Escrita: ${typedExpiry || '—'} · En la licencia: ${printedExpiry || '—'}`,
  );

  // The card is the authority on its own expiry; the typed date only stands
  // in when the card could not be read.
  const effectiveExpiry = printedExpiry || typedExpiry;
  add(
    'notExpired',
    'La licencia está vigente',
    effectiveExpiry === '' ? 'unclear' : effectiveExpiry >= dateKey(now) ? 'pass' : 'fail',
    effectiveExpiry === '' ? '' : `Vence: ${effectiveExpiry}`,
  );

  const face: CheckResult = !options.hasProfilePhoto
    ? 'unclear'
    : reading.faceMatch === 'match'
      ? 'pass'
      : reading.faceMatch === 'no_match'
        ? 'fail'
        : 'unclear';
  add(
    'face',
    'La cara coincide con la foto de perfil',
    face,
    !options.hasProfilePhoto
      ? 'No hay foto de perfil para comparar.'
      : reading.faceMatch === 'no_face'
        ? 'No se ve una cara en la licencia.'
        : '',
  );

  const failed = (key: string) => checks.some((c) => c.key === key && c.result === 'fail');

  // Photo problems first: when the card cannot be read, every mismatch below
  // is noise and the fix is the same — take the photo again.
  if (failed('document')) {
    return {
      state: LicenseVerificationState.rejected,
      reason: 'Las fotos no parecen una licencia de conducir. Sube el frente y el reverso de tu licencia.',
      checks,
    };
  }
  if (failed('legible')) {
    return {
      state: LicenseVerificationState.rejected,
      reason: 'No pudimos leer tu licencia. Toma las fotos con buena luz, sin reflejos y con la licencia completa.',
      checks,
    };
  }
  if (failed('notExpired')) {
    return {
      state: LicenseVerificationState.rejected,
      reason: 'Tu licencia está vencida. Solo se aceptan licencias vigentes.',
      checks,
    };
  }

  const mismatches = [
    ['name', 'el nombre'],
    ['cedula', 'la cédula'],
    ['licenseNumber', 'el número de licencia'],
    ['expiryMatches', 'la fecha de vencimiento'],
  ]
    .filter(([key]) => failed(key!))
    .map(([, words]) => words!);
  if (mismatches.length > 0) {
    return {
      state: LicenseVerificationState.rejected,
      reason:
        `Lo que escribiste no coincide con tu licencia: ${joinSpanish(mismatches)}. ` +
        'Sube fotos de tu propia licencia, o llama a la oficina si tus datos están mal escritos.',
      checks,
    };
  }
  if (failed('face')) {
    return {
      state: LicenseVerificationState.rejected,
      reason: 'La cara de la licencia no coincide con tu foto de perfil. Sube fotos de tu propia licencia.',
      checks,
    };
  }

  if (checks.some((c) => c.result === 'unclear')) {
    return {
      state: LicenseVerificationState.manualReview,
      reason: 'La oficina revisará tus documentos.',
      checks,
    };
  }

  return { state: LicenseVerificationState.verified, reason: '', checks };
}

/** `a`, `a y b`, `a, b y c`. */
function joinSpanish(items: string[]): string {
  if (items.length <= 1) return items[0] ?? '';
  return `${items.slice(0, -1).join(', ')} y ${items[items.length - 1]}`;
}

/**
 * After [attempt] tries ending in [verdict]: a rejection on the last allowed
 * try goes to a person instead, so a chofer is never stuck retrying forever.
 */
export function afterAttempt(verdict: LicenseVerdict, attempt: number): LicenseVerdict {
  if (verdict.state !== LicenseVerificationState.rejected || attempt < MAX_LICENSE_ATTEMPTS) {
    return verdict;
  }
  return {
    ...verdict,
    state: LicenseVerificationState.manualReview,
    reason: 'La oficina revisará tus documentos.',
  };
}
