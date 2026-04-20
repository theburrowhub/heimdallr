// Review-decision presentation helpers.
//
// The daemon stores the GitHub review state verbatim (APPROVED,
// CHANGES_REQUESTED, COMMENTED, DISMISSED, PENDING — see
// daemon/internal/store/reviews.go). We deliberately do NOT derive the
// badge from severity here; the web UI renders exactly what GitHub reports.

export interface ReviewDecision {
  label: string;
  class: string;
}

const DECISIONS: Record<string, ReviewDecision> = {
  APPROVED: {
    label: 'Approved',
    class: 'bg-green-100 text-green-700 dark:bg-green-950 dark:text-green-300'
  },
  CHANGES_REQUESTED: {
    label: 'Changes requested',
    class: 'bg-red-100 text-red-700 dark:bg-red-950 dark:text-red-300'
  },
  COMMENTED: {
    label: 'Commented',
    class: 'bg-blue-100 text-blue-700 dark:bg-blue-950 dark:text-blue-300'
  },
  DISMISSED: {
    label: 'Dismissed',
    class: 'bg-gray-100 text-gray-500 line-through dark:bg-gray-800 dark:text-gray-400'
  },
  PENDING: {
    label: 'Pending',
    class: 'bg-amber-100 text-amber-700 dark:bg-amber-950 dark:text-amber-300'
  }
};

// decisionLabel returns the pill styling for a GitHub review state.
// Returns null for empty / unknown values so callers can simply not
// render the badge — e.g. reviews that never published (legacy rows or
// the -1 sentinel the pipeline writes for orphaned PRs).
export function decisionLabel(state: string | null | undefined): ReviewDecision | null {
  if (!state) return null;
  return DECISIONS[state] ?? null;
}
