import { describe, expect, it } from 'vitest';
import { decisionLabel } from '../lib/review.js';

describe('decisionLabel', () => {
  it('returns null for empty/null/undefined so the badge renders nothing', () => {
    for (const input of ['', null, undefined]) {
      expect(decisionLabel(input)).toBeNull();
    }
  });

  it('returns null for unknown states rather than a mystery pill', () => {
    // Guards against rendering whatever GitHub might add in the future
    // (e.g. a new state constant) without explicit opt-in.
    expect(decisionLabel('UNKNOWN_STATE')).toBeNull();
  });

  it('maps APPROVED to the green "Approved" pill', () => {
    const d = decisionLabel('APPROVED');
    expect(d?.label).toBe('Approved');
    expect(d?.class).toContain('bg-green-100');
    expect(d?.class).toContain('text-green-700');
  });

  it('maps CHANGES_REQUESTED to the red "Changes requested" pill', () => {
    const d = decisionLabel('CHANGES_REQUESTED');
    expect(d?.label).toBe('Changes requested');
    expect(d?.class).toContain('bg-red-100');
    expect(d?.class).toContain('text-red-700');
  });

  it('maps COMMENTED to the blue "Commented" pill', () => {
    const d = decisionLabel('COMMENTED');
    expect(d?.label).toBe('Commented');
    expect(d?.class).toContain('bg-blue-100');
  });

  it('maps DISMISSED to a muted, strikethrough pill', () => {
    const d = decisionLabel('DISMISSED');
    expect(d?.label).toBe('Dismissed');
    expect(d?.class).toContain('line-through');
  });

  it('maps PENDING to an amber pill', () => {
    const d = decisionLabel('PENDING');
    expect(d?.label).toBe('Pending');
    expect(d?.class).toContain('bg-amber-100');
  });

  it('is case-sensitive — states arrive uppercase from GitHub', () => {
    // GitHub emits uppercase constants (APPROVED, CHANGES_REQUESTED, …).
    // Lowercasing them would mean we lost fidelity upstream — surface as
    // null so the drift is visible instead of silently matching.
    expect(decisionLabel('approved')).toBeNull();
  });

  it('includes dark-mode variants for every mapped state', () => {
    for (const state of ['APPROVED', 'CHANGES_REQUESTED', 'COMMENTED', 'DISMISSED', 'PENDING']) {
      const d = decisionLabel(state);
      expect(d, `no decision for ${state}`).not.toBeNull();
      expect(d!.class).toMatch(/dark:bg-/);
      expect(d!.class).toMatch(/dark:text-/);
    }
  });
});
