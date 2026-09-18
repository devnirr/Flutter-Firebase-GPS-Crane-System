import { readFileSync } from 'node:fs';

import { describe, expect, it } from 'vitest';

import { InsurerRole, InsurerStatus, UserRole } from '../src/lib/enums.js';
import {
  canManageMembers,
  createInsurerInput,
  createInsurerUserInput,
  describeInvalidInput,
  generateTemporaryPassword,
  insurerClaims,
  isValidCompanyRnc,
  memberChangeRefusal,
  updateInsurerUserInput,
} from '../src/lib/insurers.js';
import { VehicleClass } from '../src/lib/zonePricing.js';
import { withRncCheckDigit } from './support/rnc.js';

/**
 * The rules for insurance companies that need no database: what an RNC is,
 * what the callables accept, and who may manage whose people.
 */

describe('isValidCompanyRnc', () => {
  it('accepts RNCs whose check digit is right', () => {
    // Worked by hand, independently of `withRncCheckDigit`.
    expect(isValidCompanyRnc('130000001')).toBe(true);
    expect(isValidCompanyRnc('131000002')).toBe(true);
    // A published RNC (Banco Popular Dominicano), to pin the DGII weighting
    // itself rather than only agreeing with ourselves.
    expect(isValidCompanyRnc('101010632')).toBe(true);
  });

  it('accepts the dashes people type', () => {
    expect(isValidCompanyRnc('1-30-00000-1')).toBe(true);
  });

  it('rejects a wrong check digit', () => {
    expect(isValidCompanyRnc('130000002')).toBe(false);
    expect(isValidCompanyRnc('101010633')).toBe(false);
  });

  it('rejects anything that is not nine digits', () => {
    expect(isValidCompanyRnc('')).toBe(false);
    expect(isValidCompanyRnc('13000000')).toBe(false);
    // A cédula is eleven digits: a person, not an insurance company.
    expect(isValidCompanyRnc('00114272360')).toBe(false);
  });

  it('agrees with the test helper across many values', () => {
    for (let i = 0; i < 500; i++) {
      const eight = String(10000000 + i * 1777).padStart(8, '0').slice(0, 8);
      expect(isValidCompanyRnc(withRncCheckDigit(eight))).toBe(true);
    }
  });
});

describe('createInsurerInput', () => {
  const valid = {
    name: 'Seguros Ejemplo, S.A.',
    rnc: '1-30-00000-1',
    billingEmail: 'facturas@ejemplo.do',
  };

  it('normalizes the RNC to digits and fills the optional fields', () => {
    const parsed = createInsurerInput.parse(valid);
    expect(parsed.rnc).toBe('130000001');
    expect(parsed.contactName).toBe('');
    expect(parsed.contactEmail).toBe('');
    expect(parsed.contactPhone).toBe('');
  });

  it('refuses an invalid RNC, naming the field', () => {
    const result = createInsurerInput.safeParse({ ...valid, rnc: '130000002' });
    expect(result.success).toBe(false);
    if (!result.success) expect(result.error.issues[0]?.path[0]).toBe('rnc');
  });

  it('requires a billing email', () => {
    const { billingEmail: _, ...rest } = valid;
    expect(createInsurerInput.safeParse(rest).success).toBe(false);
    expect(createInsurerInput.safeParse({ ...valid, billingEmail: 'no' }).success).toBe(false);
  });

  it('does not let the caller set the status', () => {
    const parsed = createInsurerInput.parse({ ...valid, status: InsurerStatus.suspended });
    expect(parsed).not.toHaveProperty('status');
  });
});

describe('describeInvalidInput', () => {
  const describeFor = (data: unknown) => {
    const result = createInsurerInput.safeParse(data);
    if (result.success) throw new Error('expected a refusal');
    return describeInvalidInput(result.error, 'fallback');
  };

  it('names the RNC when it is wrong, even if other fields are too', () => {
    expect(describeFor({ name: 'X', rnc: '130000002', billingEmail: 'no' })).toMatch(/RNC/);
  });

  it('names the billing email when the RNC is fine', () => {
    expect(
      describeFor({ name: 'X', rnc: '130000001', billingEmail: 'no' }),
    ).toMatch(/facturación/);
  });

  it('names the name when that is the only problem', () => {
    expect(
      describeFor({ name: 'X', rnc: '130000001', billingEmail: 'f@x.do' }),
    ).toMatch(/nombre/);
  });

  it('falls back when no field is recognised', () => {
    expect(describeFor('not an object')).toBe('fallback');
  });
});

describe('createInsurerUserInput', () => {
  const valid = {
    insurerId: 'ins-1',
    name: 'Ana Pérez',
    email: '  Ana.Perez@Ejemplo.DO ',
    insurerRole: InsurerRole.operator,
  };

  it('lower-cases and trims the email', () => {
    expect(createInsurerUserInput.parse(valid).email).toBe('ana.perez@ejemplo.do');
  });

  it('refuses a role that is not an insurer role', () => {
    expect(createInsurerUserInput.safeParse({ ...valid, insurerRole: 'admin' }).success).toBe(false);
  });

  it('refuses a short first password', () => {
    expect(
      createInsurerUserInput.safeParse({ ...valid, initialPassword: 'short' }).success,
    ).toBe(false);
  });
});

describe('updateInsurerUserInput', () => {
  it('refuses a request that changes nothing', () => {
    expect(updateInsurerUserInput.safeParse({ insurerId: 'a', uid: 'b' }).success).toBe(false);
  });

  it('accepts a deactivation on its own', () => {
    expect(
      updateInsurerUserInput.safeParse({ insurerId: 'a', uid: 'b', active: false }).success,
    ).toBe(true);
  });
});

describe('insurerClaims', () => {
  it('carries the role, the company and the role inside it', () => {
    expect(insurerClaims('ins-1', InsurerRole.manager)).toEqual({
      role: 'insurer',
      insurerId: 'ins-1',
      insurerRole: 'manager',
    });
  });
});

describe('canManageMembers', () => {
  const manager = {
    uid: 'm',
    role: UserRole.insurer,
    insurerId: 'ins-1',
    insurerRole: InsurerRole.manager,
  };

  it('lets the office manage any company', () => {
    expect(canManageMembers({ uid: 'x', role: UserRole.admin }, 'ins-1')).toBe(true);
  });

  it('does not let dispatchers manage companies', () => {
    expect(canManageMembers({ uid: 'x', role: UserRole.ops }, 'ins-1')).toBe(false);
  });

  it('lets a manager manage their own company only', () => {
    expect(canManageMembers(manager, 'ins-1')).toBe(true);
    expect(canManageMembers(manager, 'ins-2')).toBe(false);
  });

  it('does not let an operator manage anyone', () => {
    expect(
      canManageMembers({ ...manager, insurerRole: InsurerRole.operator }, 'ins-1'),
    ).toBe(false);
  });

  it('does not let a client or chofer manage anyone, even with a stray company id', () => {
    expect(canManageMembers({ ...manager, role: UserRole.client }, 'ins-1')).toBe(false);
    expect(canManageMembers({ ...manager, role: UserRole.driver }, 'ins-1')).toBe(false);
  });
});

describe('memberChangeRefusal', () => {
  const manager = {
    uid: 'm',
    role: UserRole.insurer,
    insurerId: 'ins-1',
    insurerRole: InsurerRole.manager,
  };

  it('stops a manager deactivating themselves', () => {
    expect(memberChangeRefusal(manager, 'm', { active: false })).toMatch(/desactivar/);
  });

  it('stops a manager demoting themselves', () => {
    expect(
      memberChangeRefusal(manager, 'm', { insurerRole: InsurerRole.operator }),
    ).toMatch(/rol/);
  });

  it('lets a manager edit their own name, or confirm their own role', () => {
    expect(memberChangeRefusal(manager, 'm', {})).toBeNull();
    expect(memberChangeRefusal(manager, 'm', { insurerRole: InsurerRole.manager })).toBeNull();
  });

  it('lets a manager deactivate or demote a colleague', () => {
    expect(memberChangeRefusal(manager, 'other', { active: false })).toBeNull();
    expect(
      memberChangeRefusal(manager, 'other', { insurerRole: InsurerRole.operator }),
    ).toBeNull();
  });

  it('does not bind the office', () => {
    expect(
      memberChangeRefusal({ uid: 'a', role: UserRole.admin }, 'a', { active: false }),
    ).toBeNull();
  });
});

describe('generateTemporaryPassword', () => {
  it('is long, mixed, and different every time', () => {
    const seen = new Set<string>();
    for (let i = 0; i < 200; i++) {
      const password = generateTemporaryPassword();
      expect(password.length).toBeGreaterThanOrEqual(16);
      expect(password).toMatch(/[a-z]/);
      expect(password).toMatch(/[A-Z]/);
      expect(password).toMatch(/\d/);
      expect(password).toMatch(/[^A-Za-z0-9]/);
      seen.add(password);
    }
    expect(seen.size).toBe(200);
  });
});

describe('the insurer wire values', () => {
  // The Dart enums are what the panel decodes. A value spelled differently
  // there resolves to `unknown` and the person sees a panel with nothing in it.
  const dart = readFileSync(
    new URL('../../packages/grua_core/lib/src/domain/enums.dart', import.meta.url),
    'utf8',
  );

  function dartWires(enumName: string): string[] {
    const body = dart.match(new RegExp(`enum ${enumName} \\{([\\s\\S]*?)\\n\\}`))?.[1];
    if (!body) throw new Error(`enum ${enumName} not found in enums.dart`);
    return [...body.matchAll(/@JsonValue\('([^']+)'\)/g)]
      .map((m) => m[1]!)
      .filter((wire) => wire !== 'unknown');
  }

  it('match for UserRole', () => {
    expect(dartWires('UserRole').sort()).toEqual(Object.values(UserRole).sort());
  });

  it('match for InsurerRole', () => {
    expect(dartWires('InsurerRole').sort()).toEqual(Object.values(InsurerRole).sort());
  });

  it('match for VehicleClass', () => {
    expect(dartWires('VehicleClass').sort()).toEqual(Object.values(VehicleClass).sort());
  });

  it('match for InsurerStatus', () => {
    expect(dartWires('InsurerStatus').sort()).toEqual(Object.values(InsurerStatus).sort());
  });
});
