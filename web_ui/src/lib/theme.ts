export type ThemeChoice = 'system' | 'light' | 'dark';

const STORAGE_KEY = 'heimdallm-theme';
const VALID_CHOICES: readonly ThemeChoice[] = ['system', 'light', 'dark'] as const;

function isBrowser(): boolean {
  return typeof window !== 'undefined' && typeof document !== 'undefined';
}

export function loadThemeChoice(): ThemeChoice {
  if (!isBrowser()) return 'system';
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY);
    if (raw && (VALID_CHOICES as readonly string[]).includes(raw)) {
      return raw as ThemeChoice;
    }
  } catch {
    // localStorage blocked (Safari private mode, tightened site settings).
  }
  return 'system';
}

function saveThemeChoice(choice: ThemeChoice): void {
  if (!isBrowser()) return;
  try {
    window.localStorage.setItem(STORAGE_KEY, choice);
  } catch {
    // Best-effort — the in-memory choice still drives the UI this session.
  }
}

function systemPrefersDark(): boolean {
  if (!isBrowser()) return false;
  return window.matchMedia('(prefers-color-scheme: dark)').matches;
}

function resolveDark(choice: ThemeChoice): boolean {
  if (choice === 'dark') return true;
  if (choice === 'light') return false;
  return systemPrefersDark();
}

function applyDarkClass(isDark: boolean): void {
  if (!isBrowser()) return;
  document.documentElement.classList.toggle('dark', isDark);
}

// Track the single active media listener so setThemeChoice('system') after
// setThemeChoice('light') re-subscribes without leaking the previous one.
let mediaListener: ((event: MediaQueryListEvent) => void) | null = null;

function unsubscribeSystem(): void {
  if (!isBrowser() || !mediaListener) return;
  window.matchMedia('(prefers-color-scheme: dark)').removeEventListener('change', mediaListener);
  mediaListener = null;
}

function subscribeSystem(): void {
  if (!isBrowser() || mediaListener) return;
  const mq = window.matchMedia('(prefers-color-scheme: dark)');
  mediaListener = (event: MediaQueryListEvent) => {
    applyDarkClass(event.matches);
  };
  mq.addEventListener('change', mediaListener);
}

/**
 * Apply the given theme choice: toggle the `dark` class on <html>, persist
 * the choice, and (for 'system') keep the UI in sync with OS changes.
 *
 * Idempotent and safe to call on every page load.
 */
export function setThemeChoice(choice: ThemeChoice): void {
  saveThemeChoice(choice);
  applyDarkClass(resolveDark(choice));
  if (choice === 'system') {
    subscribeSystem();
  } else {
    unsubscribeSystem();
  }
}

/**
 * Initialise the theme system on client mount. Re-reads the stored choice
 * and re-applies it — the inline script in app.html already set the class
 * pre-paint, so this is mainly about wiring up the system media listener.
 */
export function initTheme(): ThemeChoice {
  const choice = loadThemeChoice();
  setThemeChoice(choice);
  return choice;
}

// Test hook: clears the media listener so tests can observe clean state.
export function __resetThemeForTests(): void {
  unsubscribeSystem();
}
