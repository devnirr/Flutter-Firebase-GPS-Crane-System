import { describe, expect, it } from 'vitest';

import {
  type LicenseClaim,
  type LicenseReading,
  afterAttempt,
  compareLicenseNumber,
  compareNames,
  decideLicense,
  parsePrintedDate,
} from '../src/lib/licenseCheck.js';

const now = new Date('2026-09-24T15:00:00Z');

const claim: LicenseClaim = {
  name: 'Wilfredo Antonio Reyes',
  cedula: '40200123459',
  licenseNumber: '402-0012345-9',
  // Picked on a Dominican phone: local midnight, sent as UTC.
  licenseExpiry: new Date('2028-03-15T04:00:00Z'),
};

const clean: LicenseReading = {
  frontIsLicense: true,
  backIsLicense: true,
  issuer: 'República Dominicana',
  isDominican: true,
  imageQuality: 'good',
  fullName: 'WILFREDO ANTONIO REYES MARTÍNEZ',
  cedula: '402-0012345-9',
  licenseNumber: '40200123459',
  expiryPrinted: '15/03/2028',
  expiryDate: '2028-03-15',
  faceMatch: 'match',
  tamperingSuspected: false,
  notes: '',
};

const decide = (reading: Partial<LicenseReading>, hasProfilePhoto = true) =>
  decideLicense({ ...clean, ...reading }, claim, now, { hasProfilePhoto });

describe('license check', () => {
  it('verifies a clean licence that matches what was typed', () => {
    const verdict = decide({});
    expect(verdict.state).toBe('verified');
    expect(verdict.checks.every((c) => c.result === 'pass')).toBe(true);
  });

  it('accepts a typed name missing the second surname, but not another name', () => {
    expect(compareNames('Wilfredo Reyes', 'WILFREDO ANTONIO REYES MARTINEZ')).toBe('pass');
    expect(compareNames('José Núñez', 'JOSE NUNEZ')).toBe('pass');
    expect(compareNames('Pedro Gómez', 'WILFREDO ANTONIO REYES')).toBe('fail');
  });

  it('matches a licence number printed as the cédula', () => {
    expect(compareLicenseNumber('402-0012345-9', '40200123459', '40200123459')).toBe('pass');
    expect(compareLicenseNumber('L-884213', '40200123459', '40200123459')).toBe('fail');
  });

  it('rejects photos that are not a licence before anything else', () => {
    const verdict = decide({ backIsLicense: false, cedula: '00100000001' });
    expect(verdict.state).toBe('rejected');
    expect(verdict.reason).toContain('no parecen una licencia');
  });

  it('tells a foreign licence it is foreign, not that it is no licence', () => {
    const verdict = decide({ isDominican: false, issuer: 'Texas, EE. UU.' });
    expect(verdict.state).toBe('rejected');
    expect(verdict.reason).toBe(
      'Esta licencia es de Texas, EE. UU. Solo aceptamos licencias de conducir ' +
        'emitidas en la República Dominicana.',
    );
    expect(verdict.checks.find((c) => c.key === 'document')?.result).toBe('pass');
  });

  it('rejects an unreadable photo', () => {
    expect(decide({ imageQuality: 'unreadable' }).state).toBe('rejected');
  });

  it('reads printed dates day first', () => {
    expect(parsePrintedDate('26/11/2029')).toBe('2029-11-26');
    expect(parsePrintedDate('Vence 2/9/2025')).toBe('2025-09-02');
    expect(parsePrintedDate('31/02/2029')).toBe('');
    expect(parsePrintedDate('')).toBe('');
  });

  it('does not call a licence expired when the model mixes up its dates', () => {
    // The card says 26/11/2029, but the model converted the issue date.
    const verdict = decide({ expiryPrinted: '26/11/2029', expiryDate: '2025-09-02' });
    expect(verdict.state).toBe('manual_review');
    expect(verdict.checks.find((c) => c.key === 'notExpired')?.result).toBe('unclear');
  });

  it('trusts the printed text over a missing conversion', () => {
    const verdict = decide({ expiryPrinted: '15/03/2028', expiryDate: '' });
    expect(verdict.state).toBe('verified');
  });

  it('rejects an expired licence', () => {
    const verdict = decide({ expiryPrinted: '23/09/2026', expiryDate: '2026-09-23' });
    expect(verdict.state).toBe('rejected');
    expect(verdict.reason).toContain('vencida');
  });

  it('names every field that does not match', () => {
    const verdict = decide({ cedula: '00100000001', fullName: 'PEDRO GOMEZ' });
    expect(verdict.state).toBe('rejected');
    expect(verdict.reason).toContain('el nombre y la cédula');
  });

  it('rejects a face that belongs to somebody else', () => {
    expect(decide({ faceMatch: 'no_match' }).state).toBe('rejected');
  });

  it('sends anything uncertain to a person', () => {
    expect(decide({ faceMatch: 'unclear' }).state).toBe('manual_review');
    expect(decide({ tamperingSuspected: true }).state).toBe('manual_review');
    expect(decide({ imageQuality: 'poor' }).state).toBe('manual_review');
    expect(decide({ cedula: '' }).state).toBe('manual_review');
    expect(decide({}, false).state).toBe('manual_review');
  });

  it('hands the third rejection to the office', () => {
    const rejected = decide({ faceMatch: 'no_match' });
    expect(afterAttempt(rejected, 2).state).toBe('rejected');
    expect(afterAttempt(rejected, 3).state).toBe('manual_review');
    expect(afterAttempt(decide({}), 3).state).toBe('verified');
  });
});
