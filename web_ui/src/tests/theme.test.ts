import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  STORAGE_KEY,
  __resetThemeForTests,
  initTheme,
  loadThemeChoice,
  setThemeChoice
} from '../lib/theme.js';

type MqListener = (event: MediaQueryListEvent) => void;

interface FakeMq {
  matches: boolean;
  listeners: Set<MqListener>;
  addEventListener: (type: 'change', cb: MqListener) => void;
  removeEventListener: (type: 'change', cb: MqListener) => void;
  dispatchEvent: (matches: boolean) => void;
}

function installFakeMatchMedia(defaultMatches: boolean): FakeMq {
  const mq: FakeMq = {
    matches: defaultMatches,
    listeners: new Set(),
    addEventListener: (type, cb) => {
      if (type === 'change') mq.listeners.add(cb);
    },
    removeEventListener: (type, cb) => {
      if (type === 'change') mq.listeners.delete(cb);
    },
    dispatchEvent: (matches) => {
      mq.matches = matches;
      for (const cb of mq.listeners) cb({ matches } as MediaQueryListEvent);
    }
  };
  vi.stubGlobal(
    'matchMedia',
    // jsdom's Window.matchMedia isn't present — return our fake regardless of query.
    vi.fn(() => mq as unknown as MediaQueryList)
  );
  return mq;
}

beforeEach(() => {
  localStorage.clear();
  document.documentElement.classList.remove('dark');
  __resetThemeForTests();
});

afterEach(() => {
  __resetThemeForTests();
  vi.unstubAllGlobals();
});

describe('loadThemeChoice', () => {
  it('returns system when nothing is stored', () => {
    expect(loadThemeChoice()).toBe('system');
  });

  it('returns stored value when valid', () => {
    localStorage.setItem('heimdallm-theme', 'dark');
    expect(loadThemeChoice()).toBe('dark');
  });

  it('falls back to system for unknown values', () => {
    localStorage.setItem('heimdallm-theme', 'sparkly');
    expect(loadThemeChoice()).toBe('system');
  });
});

describe('setThemeChoice', () => {
  it('adds the dark class when choice is dark', () => {
    installFakeMatchMedia(false);
    setThemeChoice('dark');
    expect(document.documentElement.classList.contains('dark')).toBe(true);
  });

  it('removes the dark class when choice is light, even if system is dark', () => {
    installFakeMatchMedia(true);
    document.documentElement.classList.add('dark');
    setThemeChoice('light');
    expect(document.documentElement.classList.contains('dark')).toBe(false);
  });

  it('follows the system preference when choice is system', () => {
    const mq = installFakeMatchMedia(true);
    setThemeChoice('system');
    expect(document.documentElement.classList.contains('dark')).toBe(true);

    mq.dispatchEvent(false);
    expect(document.documentElement.classList.contains('dark')).toBe(false);
  });

  it('persists the choice in localStorage', () => {
    installFakeMatchMedia(false);
    setThemeChoice('dark');
    expect(localStorage.getItem('heimdallm-theme')).toBe('dark');
  });

  it('unsubscribes from system changes when switching away from system', () => {
    const mq = installFakeMatchMedia(false);
    setThemeChoice('system');
    expect(mq.listeners.size).toBe(1);

    setThemeChoice('light');
    expect(mq.listeners.size).toBe(0);

    // System flipping to dark must no longer drag the UI along.
    mq.dispatchEvent(true);
    expect(document.documentElement.classList.contains('dark')).toBe(false);
  });
});

describe('initTheme', () => {
  it('applies and returns the stored choice', () => {
    installFakeMatchMedia(false);
    localStorage.setItem('heimdallm-theme', 'dark');
    const choice = initTheme();
    expect(choice).toBe('dark');
    expect(document.documentElement.classList.contains('dark')).toBe(true);
  });
});

describe('STORAGE_KEY', () => {
  it('stays in sync with the inline pre-paint script in app.html', () => {
    // src/app.html can't import TypeScript, so its inline script hardcodes
    // the storage key. If the module constant changes and the HTML isn't
    // updated, the pre-paint script and the runtime helper disagree and
    // users see a flash of the wrong theme on first load.
    const appHtml = readFileSync(resolve(__dirname, '..', 'app.html'), 'utf8');
    expect(appHtml).toContain(`'${STORAGE_KEY}'`);
  });
});
