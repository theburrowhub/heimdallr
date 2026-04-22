# PR & Issue State Tracking with Filterable Views

**Date**: 2026-04-22
**Status**: Design approved

## Problem

Heimdallm only fetches open PRs/issues from GitHub (`state=open`). Once a PR is merged or an issue is closed, there's no record of the state change — the item stays as "open" in the DB forever. The Activity view has no state filter, no list/grid toggle, and filters reset on every app restart.

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| State check process | Integrated in Tier 3 watch cycle | No new config, reuses existing infrastructure (1min cycle) |
| Filter persistence | SharedPreferences (Flutter-only) | Simple, each client has its own filters |
| View modes | Lista/mosaico in unified Activity tab | PRs + issues together, badge indicates type (PR/IT/DEV) |
| State values | Open / Closed (merged → closed) | Unified for PRs and issues, simpler UI |

## Daemon — State Reconciliation in Tier 3

### Watch cycle state refresh

Each Tier 3 cycle (~1min) adds a state reconciliation step before processing changes:

For each PR in DB with `state="open"`:
1. `GET /repos/{owner}/{repo}/pulls/{number}` → read current state
2. If state changed (closed/merged) → `UPDATE prs SET state='closed' WHERE id=<id>`
3. Merged PRs are stored as `state="closed"` (unified per design decision)

For each issue in DB with `state="open"`:
1. `GET /repos/{owner}/{repo}/issues/{number}` → read current state
2. If state changed → `UPDATE issues SET state='closed' WHERE id=<id>`

### Polling exclusion

Items with `state != "open"` are excluded from:
- Tier 2 (PR review triggering) — don't review closed PRs
- Tier 3 (watch cycle) — don't re-check items already closed
- Issue fetcher — don't re-process closed issues

### Rate limit protection

- Only verify items with `state="open"` and `fetched_at` older than 5 minutes
- Maximum 50 items per cycle (oldest first, round-robin)
- Uses the existing rate limiter accounting

### SSE events for real-time UI updates

When state changes are detected, the daemon emits:
- `pr_state_changed` with `{pr_id, state}`
- `issue_state_changed` with `{issue_id, state}`

## API — State Filter

### GET /prs and GET /issues — `state` query parameter

```
GET /prs?state=open          → only open
GET /prs?state=closed        → only closed
GET /prs                     → all (no filter)
GET /issues?state=open,closed → explicit multi-value
```

### Store layer

```go
func (s *Store) ListPRs(states ...string) ([]*PR, error)
func (s *Store) ListIssues(states ...string) ([]*TrackedIssue, error)
```

Empty `states` returns all. Non-empty filters with `WHERE state IN (?)`. Dismissed items remain excluded by default: `WHERE dismissed = 0 AND state IN (?)`.

## Flutter — Persistent Filters and List/Grid View

### Extended Activity filter bar

The existing `ActivityFilterBar` gains:

1. **State chips**: `Open` / `Closed` — multi-select (both active = all). Default: `Open` active.
2. **View toggle**: list/grid icons at the right end of the bar (same pattern as Repos tab).

Bar layout: `[Sort] [Type chips: PR/IT/DEV] [State chips: Open/Closed] [Org] [Repo] [Search] [List/Grid toggle]`

### Persistence (SharedPreferences)

New keys:
- `activity_state_filter` → `"open"`, `"closed"`, `"open,closed"` (default: `"open"`)
- `activity_view_mode` → `"list"` or `"grid"` (default: `"list"`)

Existing ephemeral filters migrate to SharedPreferences:
- `activity_type_filter` → `"pr,it,dev"` (default: empty = all)
- `activity_org_filter` → `"org1,org2"` (default: empty = all)
- `activity_repo_filter` → `"org/repo1,org/repo2"` (default: empty = all)

All loaded on build, saved on every change.

### Grid mode (mosaic)

Each grid item is a compact card:
- Type badge (PR/IT/DEV) with color — top left
- State badge (Open/Closed) — top right
- Title (truncated to 2 lines)
- `repo#number` + author
- Severity badge if review exists
- Relative timestamp

### List mode

Current list tiles gain a state badge (Open/Closed) inline next to the existing type badge.

### State badge styling

- **Open**: green background, white text, open circle icon
- **Closed**: grey/purple background, white text, check icon

### Closed items visual treatment

- Items with `state=closed` render at **reduced opacity** (0.6) in both modes
- Action buttons (Review, Promote, Dismiss) remain available on closed items
- Default filter is `Open` — user must activate `Closed` chip to see them

### Real-time state updates

Flutter listens for `pr_state_changed` and `issue_state_changed` SSE events and updates the tile inline without reloading the entire list.

## Files Affected

### Daemon (Go)

| File | Change |
|------|--------|
| `daemon/internal/pipeline/pipeline.go` | State reconciliation in Tier 3 watch cycle; exclude closed from polling |
| `daemon/internal/github/client.go` | Add `FetchPRState(repo, number)` and `FetchIssueState(repo, number)` helpers |
| `daemon/internal/store/prs.go` | `ListPRs(states ...string)` with optional WHERE clause; `UpdatePRState(id, state)` |
| `daemon/internal/store/issues.go` | `ListIssues(states ...string)` with optional WHERE clause; `UpdateIssueState(id, state)` |
| `daemon/internal/server/handlers.go` | Parse `?state=` query param on GET /prs and GET /issues |
| `daemon/internal/sse/broker.go` | Add `EventPRStateChanged` and `EventIssueStateChanged` event types |

### Flutter (Dart)

| File | Change |
|------|--------|
| `flutter_app/lib/features/dashboard/dashboard_providers.dart` | Persist all filters to SharedPreferences; add state filter and view mode providers |
| `flutter_app/lib/features/dashboard/activity_filter_bar.dart` | Add state chips (Open/Closed) and list/grid toggle |
| `flutter_app/lib/features/dashboard/activity_filters.dart` | Add `states` and `viewMode` fields to `ActivityFilters` |
| `flutter_app/lib/features/dashboard/dashboard_screen.dart` | Grid view builder; state badge on tiles; SSE listener for state changes; opacity for closed items |
| `flutter_app/lib/shared/widgets/state_badge.dart` | New widget: Open/Closed badge with icon + color |
| `flutter_app/lib/core/api/api_client.dart` | Pass `?state=` param on fetchPRs and fetchIssues |

## Testing Strategy

### Daemon
- Unit test for state reconciliation: mock GitHub returning closed/merged → verify DB updated
- Unit test for `ListPRs(states...)`: verify SQL WHERE clause
- Unit test for polling exclusion: closed items skipped in Tier 2/3
- Integration test for GET /prs?state=open: only open returned

### Flutter
- Unit test for filter persistence: save/load SharedPreferences round-trip
- Widget test for state chips: toggle, verify filter updates
- Widget test for grid/list toggle: verify view mode changes
- Widget test for state badge: correct color/icon for open vs closed
