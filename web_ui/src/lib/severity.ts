// Default (and `low`) palette — also returned for unknown severities so
// they blend into the neutral UI chrome. Extracted as a constant so the
// two consumers below can't drift apart.
const NEUTRAL_BADGE = 'bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-400';

const CLASSES: Record<string, string> = {
  critical: 'bg-red-100 text-red-700 dark:bg-red-950 dark:text-red-300',
  high: 'bg-orange-100 text-orange-700 dark:bg-orange-950 dark:text-orange-300',
  medium: 'bg-amber-100 text-amber-700 dark:bg-amber-950 dark:text-amber-300',
  low: NEUTRAL_BADGE
};

const ORDER: Record<string, number> = {
  critical: 4,
  high: 3,
  medium: 2,
  low: 1
};

export function severityClass(sev: string): string {
  return CLASSES[sev.toLowerCase()] ?? NEUTRAL_BADGE;
}

export function severityOrder(sev: string): number {
  return ORDER[sev.toLowerCase()] ?? 0;
}
