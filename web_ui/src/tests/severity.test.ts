import { describe, expect, it } from 'vitest';
import { severityClass, severityOrder } from '../lib/severity.js';

describe('severityClass', () => {
  it('returns red classes for critical', () => {
    expect(severityClass('critical')).toContain('bg-red-100');
    expect(severityClass('critical')).toContain('text-red-700');
  });
  it('returns orange classes for high', () => {
    expect(severityClass('high')).toContain('bg-orange-100');
    expect(severityClass('high')).toContain('text-orange-700');
  });
  it('returns amber classes for medium', () => {
    expect(severityClass('medium')).toContain('bg-amber-100');
    expect(severityClass('medium')).toContain('text-amber-700');
  });
  it('returns gray classes for low and for unknown', () => {
    for (const input of ['low', 'whatever', '']) {
      expect(severityClass(input)).toContain('bg-gray-100');
      expect(severityClass(input)).toContain('text-gray-600');
    }
  });
  it('includes dark-mode variants for every bucket', () => {
    // Regression guard for #73: any future palette change must keep both
    // the light and dark variants side-by-side so the badges stay legible
    // under `.dark` on <html>.
    for (const sev of ['critical', 'high', 'medium', 'low', 'unknown']) {
      const cls = severityClass(sev);
      expect(cls).toMatch(/dark:bg-/);
      expect(cls).toMatch(/dark:text-/);
    }
  });
  it('is case-insensitive', () => {
    expect(severityClass('HIGH')).toContain('bg-orange-100');
    expect(severityClass('Critical')).toContain('bg-red-100');
  });
});

describe('severityOrder', () => {
  it('ranks critical highest, unknown lowest', () => {
    const sorted = ['low', 'critical', 'medium', 'unknown', 'high'].sort(
      (a, b) => severityOrder(b) - severityOrder(a)
    );
    expect(sorted).toEqual(['critical', 'high', 'medium', 'low', 'unknown']);
  });
});
