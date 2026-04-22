# State Tracking & Filterable Views Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Track open/closed state of PRs and issues, filter by state in the Activity view, persist all filters across sessions, and add list/grid view modes.

**Architecture:** The Tier 3 watch cycle already fetches each item from GitHub via `GetIssue` — we piggyback state reconciliation on that existing call. Closed items are excluded from future polling. The API gains a `?state=` query param. Flutter persists all activity filters in SharedPreferences and adds state chips + grid/list toggle.

**Tech Stack:** Go (SQLite store, chi router, SSE), Dart/Flutter (Riverpod, SharedPreferences)

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `daemon/internal/store/prs.go` | Modify | `ListPRs(states)`, `UpdatePRState` |
| `daemon/internal/store/issues.go` | Modify | `ListIssues(states)`, `UpdateIssueState` |
| `daemon/internal/store/prs_test.go` | Modify | Tests for state filter and update |
| `daemon/internal/store/issues_test.go` | Modify | Tests for state filter and update |
| `daemon/internal/sse/broker.go` | Modify | Add `EventPRStateChanged`, `EventIssueStateChanged` |
| `daemon/cmd/heimdallm/main.go` | Modify | State reconciliation in `CheckItem`, exclude closed from Tier 2 |
| `daemon/internal/server/handlers.go` | Modify | Parse `?state=` on GET /prs and GET /issues |
| `daemon/internal/server/handlers_test.go` | Modify | Tests for state filter param |
| `flutter_app/lib/shared/widgets/state_badge.dart` | Create | Open/Closed badge widget |
| `flutter_app/lib/features/dashboard/activity_filters.dart` | Modify | Add `states`, `viewMode` fields; persistence |
| `flutter_app/lib/features/dashboard/dashboard_providers.dart` | Modify | Persist filters; pass state to API |
| `flutter_app/lib/features/dashboard/activity_filter_bar.dart` | Modify | State chips + grid/list toggle |
| `flutter_app/lib/features/dashboard/dashboard_screen.dart` | Modify | Grid view builder; state badge; SSE state listener; opacity for closed |
| `flutter_app/lib/core/api/api_client.dart` | Modify | Pass `?state=` param on fetchPRs/fetchIssues |

---

### Task 1: Store — State Filter and Update Methods

**Files:**
- Modify: `daemon/internal/store/prs.go`
- Modify: `daemon/internal/store/issues.go`
- Modify: `daemon/internal/store/prs_test.go` (if exists) or `daemon/internal/store/store_test.go`

- [ ] **Step 1: Add `UpdatePRState` method**

Add to `daemon/internal/store/prs.go`:

```go
// UpdatePRState sets the state of a PR by its store ID.
func (s *Store) UpdatePRState(id int64, state string) error {
	_, err := s.db.Exec("UPDATE prs SET state = ? WHERE id = ?", state, id)
	return err
}
```

- [ ] **Step 2: Modify `ListPRs` to accept state filter**

Change the signature and SQL in `daemon/internal/store/prs.go`. The current `ListPRs()` has no params. Change to:

```go
// ListPRs returns non-dismissed PRs, optionally filtered by state.
// If no states are provided, all non-dismissed PRs are returned.
func (s *Store) ListPRs(states ...string) ([]*PR, error) {
	query := `SELECT id, github_id, repo, number, title, author, url, state, updated_at, fetched_at, dismissed
		FROM prs WHERE dismissed = 0`
	var args []any
	if len(states) > 0 {
		placeholders := make([]string, len(states))
		for i, st := range states {
			placeholders[i] = "?"
			args = append(args, st)
		}
		query += " AND state IN (" + strings.Join(placeholders, ",") + ")"
	}
	query += " ORDER BY updated_at DESC"
	rows, err := s.db.Query(query, args...)
	// ... rest unchanged (scan loop)
```

Add `"strings"` to imports if not present.

- [ ] **Step 3: Add `ListOpenPRs` convenience method**

```go
// ListOpenPRs returns all non-dismissed PRs with state="open".
// Used by state reconciliation to know which items need checking.
func (s *Store) ListOpenPRs() ([]*PR, error) {
	return s.ListPRs("open")
}
```

- [ ] **Step 4: Add `UpdateIssueState` method**

Add to `daemon/internal/store/issues.go`:

```go
// UpdateIssueState sets the state of an issue by its store ID.
func (s *Store) UpdateIssueState(id int64, state string) error {
	_, err := s.db.Exec("UPDATE issues SET state = ? WHERE id = ?", state, id)
	return err
}
```

- [ ] **Step 5: Modify `ListIssues` to accept state filter**

Same pattern as `ListPRs`:

```go
func (s *Store) ListIssues(states ...string) ([]*Issue, error) {
	query := `SELECT id, github_id, repo, number, title, body, author, assignees, labels,
		state, created_at, fetched_at, dismissed
		FROM issues WHERE dismissed = 0`
	var args []any
	if len(states) > 0 {
		placeholders := make([]string, len(states))
		for i, st := range states {
			placeholders[i] = "?"
			args = append(args, st)
		}
		query += " AND state IN (" + strings.Join(placeholders, ",") + ")"
	}
	query += " ORDER BY fetched_at DESC"
	rows, err := s.db.Query(query, args...)
	// ... rest unchanged (scan loop)
```

- [ ] **Step 6: Add `ListOpenIssues` convenience method**

```go
func (s *Store) ListOpenIssues() ([]*Issue, error) {
	return s.ListIssues("open")
}
```

- [ ] **Step 7: Run tests**

Run: `cd daemon && go test ./internal/store/ -v -count=1`
Expected: all existing tests pass (the no-arg `ListPRs()` call still works because `states` is variadic)

- [ ] **Step 8: Write tests for new methods**

Add to the store test file:

```go
func TestListPRs_StateFilter(t *testing.T) {
	s := setupTestStore(t)
	// Insert two PRs with different states
	s.UpsertPR(&store.PR{GithubID: 1, Repo: "org/a", Number: 1, State: "open", UpdatedAt: time.Now()})
	s.UpsertPR(&store.PR{GithubID: 2, Repo: "org/a", Number: 2, State: "closed", UpdatedAt: time.Now()})

	all, _ := s.ListPRs()
	assert(len(all) == 2)

	open, _ := s.ListPRs("open")
	assert(len(open) == 1 && open[0].Number == 1)

	closed, _ := s.ListPRs("closed")
	assert(len(closed) == 1 && closed[0].Number == 2)
}

func TestUpdatePRState(t *testing.T) {
	s := setupTestStore(t)
	id, _ := s.UpsertPR(&store.PR{GithubID: 1, Repo: "org/a", Number: 1, State: "open", UpdatedAt: time.Now()})
	s.UpdatePRState(id, "closed")
	prs, _ := s.ListPRs("closed")
	assert(len(prs) == 1 && prs[0].State == "closed")
}
```

Adapt to match existing test patterns in the file. Same pattern for issues.

- [ ] **Step 9: Run all tests and commit**

Run: `cd daemon && go test ./... -count=1`

```bash
git add daemon/internal/store/
git commit -m "feat(store): add state filter to ListPRs/ListIssues, add UpdatePRState/UpdateIssueState"
```

---

### Task 2: SSE Events + GitHub PR State

**Files:**
- Modify: `daemon/internal/sse/broker.go`
- Modify: `daemon/internal/github/client.go`

- [ ] **Step 1: Add SSE event type constants**

Add to `daemon/internal/sse/broker.go` after the existing constants:

```go
EventPRStateChanged    = "pr_state_changed"
EventIssueStateChanged = "issue_state_changed"
```

- [ ] **Step 2: Add `GetPRState` to GitHub client**

The `GetIssue` method works for both PRs and issues (GitHub's Issues API handles both), but for PRs it returns "open"/"closed" — not "merged". To detect merged, we need the Pulls API. Add to `daemon/internal/github/client.go`:

```go
// GetPRState returns the state of a PR: "open", "closed", or "merged".
// Uses the Pulls API which distinguishes merged from closed.
func (c *Client) GetPRState(repo string, number int) (string, error) {
	path := fmt.Sprintf("/repos/%s/pulls/%d", repo, number)
	resp, err := c.do("GET", path, "application/vnd.github+json")
	if err != nil {
		return "", fmt.Errorf("github: get PR state %s#%d: %w", repo, number, err)
	}
	body, _ := io.ReadAll(io.LimitReader(resp.Body, maxBodyBytes))
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("github: get PR state %s#%d: status %d", repo, number, resp.StatusCode)
	}
	var pr struct {
		State    string `json:"state"`
		MergedAt *string `json:"merged_at"`
	}
	if err := json.Unmarshal(body, &pr); err != nil {
		return "", fmt.Errorf("github: decode PR state %s#%d: %w", repo, number, err)
	}
	// GitHub PR state is "open" or "closed"; merged is inferred from merged_at
	if pr.MergedAt != nil {
		return "closed", nil // Unified: merged → closed per spec
	}
	return pr.State, nil
}
```

- [ ] **Step 3: Verify and commit**

Run: `cd daemon && go build ./...`

```bash
git add daemon/internal/sse/broker.go daemon/internal/github/client.go
git commit -m "feat: add SSE state change events and GetPRState helper"
```

---

### Task 3: State Reconciliation in Tier 3

**Files:**
- Modify: `daemon/cmd/heimdallm/main.go`

- [ ] **Step 1: Modify `CheckItem` to detect state changes**

The current `CheckItem` in `tier2Adapter` (main.go ~line 1320) fetches the issue from GitHub and checks `UpdatedAt`. Extend it to also detect state changes and update the store:

```go
func (a *tier2Adapter) CheckItem(ctx context.Context, item *scheduler.WatchItem) (bool, error) {
	issue, err := a.ghClient.GetIssue(item.Repo, item.Number)
	if err != nil {
		return false, err
	}

	// State reconciliation: detect open → closed transitions.
	// For PRs, use the Pulls API to distinguish merged from closed.
	if item.Type == "pr" {
		prState, err := a.ghClient.GetPRState(item.Repo, item.Number)
		if err != nil {
			slog.Warn("tier3: could not fetch PR state", "repo", item.Repo, "number", item.Number, "err", err)
		} else if prState != "open" {
			// PR was closed or merged — update store, emit SSE, exclude from future polling.
			if err := a.store.UpdatePRState(item.GithubID, "closed"); err != nil {
				slog.Warn("tier3: update PR state failed", "err", err)
			}
			a.broker.Publish(sse.Event{
				Type: sse.EventPRStateChanged,
				Data: fmt.Sprintf(`{"pr_id":%d,"state":"closed"}`, item.GithubID),
			})
			slog.Info("tier3: PR state changed to closed", "repo", item.Repo, "number", item.Number)
			// Don't re-enqueue — item drops out of the watch queue.
			return false, nil
		}
	} else {
		// Issue state from the Issues API response.
		if issue.State != "open" {
			if err := a.store.UpdateIssueState(item.GithubID, "closed"); err != nil {
				slog.Warn("tier3: update issue state failed", "err", err)
			}
			a.broker.Publish(sse.Event{
				Type: sse.EventIssueStateChanged,
				Data: fmt.Sprintf(`{"issue_id":%d,"state":"closed"}`, item.GithubID),
			})
			slog.Info("tier3: issue state changed to closed", "repo", item.Repo, "number", item.Number)
			return false, nil
		}
	}

	changed := issue.UpdatedAt.After(item.LastSeen)
	return changed, nil
}
```

**IMPORTANT:** The `return false, nil` for closed items means Tier 3 won't call `HandleChange` and the item won't be re-enqueued — it naturally drops out of the watch queue.

**IMPORTANT:** `item.GithubID` is the GitHub ID used as the PR/issue store key. Verify that `UpdatePRState` and `UpdateIssueState` use the correct ID column. If the store uses the local `id` (auto-increment) instead of `github_id`, we need a different method. Check the store's `GetPR(githubID)` pattern — if it exists, use it to resolve the local ID first. Otherwise, add `UpdatePRStateByGithubID`:

```go
func (s *Store) UpdatePRStateByGithubID(githubID int64, state string) error {
	_, err := s.db.Exec("UPDATE prs SET state = ? WHERE github_id = ?", state, githubID)
	return err
}
```

Same for issues. Use the `ByGithubID` variants in `CheckItem`.

- [ ] **Step 2: Verify and commit**

Run: `cd daemon && go build ./... && go test ./... -count=1`

```bash
git add daemon/cmd/heimdallm/main.go daemon/internal/store/prs.go daemon/internal/store/issues.go
git commit -m "feat: state reconciliation in Tier 3 — detect closed PRs/issues, emit SSE events"
```

---

### Task 4: API Handlers — State Query Param

**Files:**
- Modify: `daemon/internal/server/handlers.go`
- Modify: `daemon/internal/server/handlers_test.go`

- [ ] **Step 1: Modify `handleListPRs` to parse `?state=`**

```go
func (srv *Server) handleListPRs(w http.ResponseWriter, r *http.Request) {
	var states []string
	if s := r.URL.Query().Get("state"); s != "" {
		states = strings.Split(s, ",")
	}
	prs, err := srv.store.ListPRs(states...)
	// ... rest unchanged
```

- [ ] **Step 2: Modify `handleListIssues` to parse `?state=`**

Same pattern:

```go
func (srv *Server) handleListIssues(w http.ResponseWriter, r *http.Request) {
	var states []string
	if s := r.URL.Query().Get("state"); s != "" {
		states = strings.Split(s, ",")
	}
	issues, err := srv.store.ListIssues(states...)
	// ... rest unchanged
```

- [ ] **Step 3: Write integration tests**

```go
func TestHandleListPRs_StateFilter(t *testing.T) {
	s := setupTestStore(t)
	s.UpsertPR(&store.PR{GithubID: 1, Repo: "org/a", Number: 1, State: "open", ...})
	s.UpsertPR(&store.PR{GithubID: 2, Repo: "org/a", Number: 2, State: "closed", ...})

	srv := server.New(s, sse.NewBroker(), nil, "test-token")

	// No filter → all
	req := httptest.NewRequest("GET", "/prs", nil)
	req.Header.Set("X-Heimdallm-Token", "test-token")
	rec := httptest.NewRecorder()
	srv.ServeHTTP(rec, req)
	// assert 2 items

	// Filter open
	req = httptest.NewRequest("GET", "/prs?state=open", nil)
	req.Header.Set("X-Heimdallm-Token", "test-token")
	rec = httptest.NewRecorder()
	srv.ServeHTTP(rec, req)
	// assert 1 item, state=open

	// Filter closed
	req = httptest.NewRequest("GET", "/prs?state=closed", nil)
	req.Header.Set("X-Heimdallm-Token", "test-token")
	rec = httptest.NewRecorder()
	srv.ServeHTTP(rec, req)
	// assert 1 item, state=closed
}
```

- [ ] **Step 4: Verify and commit**

Run: `cd daemon && go test ./... -count=1`

```bash
git add daemon/internal/server/handlers.go daemon/internal/server/handlers_test.go
git commit -m "feat(api): add ?state= query param to GET /prs and GET /issues"
```

---

### Task 5: Flutter — State Badge Widget

**Files:**
- Create: `flutter_app/lib/shared/widgets/state_badge.dart`

- [ ] **Step 1: Create the widget**

```dart
import 'package:flutter/material.dart';

class StateBadge extends StatelessWidget {
  final String state;
  const StateBadge({super.key, required this.state});

  bool get _isOpen => state == 'open';

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: _isOpen ? Colors.green.shade700 : Colors.grey.shade600,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _isOpen ? Icons.circle_outlined : Icons.check_circle,
            size: 12,
            color: Colors.white,
          ),
          const SizedBox(width: 4),
          Text(
            _isOpen ? 'Open' : 'Closed',
            style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 2: Verify and commit**

Run: `cd flutter_app && flutter analyze --no-fatal-infos`

```bash
git add flutter_app/lib/shared/widgets/state_badge.dart
git commit -m "feat(flutter): add StateBadge widget (Open/Closed)"
```

---

### Task 6: Flutter — API Client State Param

**Files:**
- Modify: `flutter_app/lib/core/api/api_client.dart`

- [ ] **Step 1: Modify `fetchPRs` to accept state filter**

Change `fetchPRs` to accept optional states:

```dart
Future<List<PR>> fetchPRs({List<String> states = const []}) async {
  var path = '/prs';
  if (states.isNotEmpty) {
    path += '?state=${states.join(',')}';
  }
  final resp = await _client.get(_uri(path), headers: await _authHeaders());
  // ... rest unchanged
}
```

- [ ] **Step 2: Modify `fetchIssues` to accept state filter**

Same pattern for `fetchIssues`.

- [ ] **Step 3: Verify and commit**

Run: `cd flutter_app && flutter analyze --no-fatal-infos`

```bash
git add flutter_app/lib/core/api/api_client.dart
git commit -m "feat(flutter): pass ?state= param on fetchPRs/fetchIssues"
```

---

### Task 7: Flutter — Persistent Activity Filters

**Files:**
- Modify: `flutter_app/lib/features/dashboard/activity_filters.dart`
- Modify: `flutter_app/lib/features/dashboard/dashboard_providers.dart`

- [ ] **Step 1: Extend `ActivityFilters` with states and viewMode**

```dart
class ActivityFilters {
  final Set<String> types;
  final Set<String> orgs;
  final Set<String> repos;
  final Set<String> states;    // 'open', 'closed' — empty = all
  final String search;
  final String viewMode;       // 'list' or 'grid'

  const ActivityFilters({
    this.types = const {},
    this.orgs = const {},
    this.repos = const {},
    this.states = const {'open'},  // default: only open
    this.search = '',
    this.viewMode = 'list',
  });

  ActivityFilters copyWith({
    Set<String>? types, Set<String>? orgs, Set<String>? repos,
    Set<String>? states, String? search, String? viewMode,
  }) => ActivityFilters(
    types: types ?? this.types,
    orgs: orgs ?? this.orgs,
    repos: repos ?? this.repos,
    states: states ?? this.states,
    search: search ?? this.search,
    viewMode: viewMode ?? this.viewMode,
  );

  bool get hasFilters =>
    types.isNotEmpty || orgs.isNotEmpty || repos.isNotEmpty ||
    states != const {'open'} || search.isNotEmpty;
}
```

- [ ] **Step 2: Create persistent `ActivityFiltersNotifier`**

Replace the `StateProvider` with a `Notifier` that persists to SharedPreferences. Add to `dashboard_providers.dart`:

```dart
class ActivityFiltersNotifier extends Notifier<ActivityFilters> {
  static const _typesKey = 'activity_type_filter';
  static const _orgsKey = 'activity_org_filter';
  static const _reposKey = 'activity_repo_filter';
  static const _statesKey = 'activity_state_filter';
  static const _viewModeKey = 'activity_view_mode';

  @override
  ActivityFilters build() {
    _loadAsync();
    return const ActivityFilters(); // default until prefs load
  }

  Future<void> _loadAsync() async {
    final prefs = await SharedPreferences.getInstance();
    state = ActivityFilters(
      types: _loadSet(prefs, _typesKey),
      orgs: _loadSet(prefs, _orgsKey),
      repos: _loadSet(prefs, _reposKey),
      states: _loadSet(prefs, _statesKey, defaultVal: {'open'}),
      viewMode: prefs.getString(_viewModeKey) ?? 'list',
    );
  }

  Set<String> _loadSet(SharedPreferences p, String key, {Set<String>? defaultVal}) {
    final v = p.getString(key);
    if (v == null || v.isEmpty) return defaultVal ?? {};
    return v.split(',').toSet();
  }

  void update(ActivityFilters filters) {
    state = filters;
    _saveAsync(filters);
  }

  Future<void> _saveAsync(ActivityFilters f) async {
    final prefs = await SharedPreferences.getInstance();
    prefs.setString(_typesKey, f.types.join(','));
    prefs.setString(_orgsKey, f.orgs.join(','));
    prefs.setString(_reposKey, f.repos.join(','));
    prefs.setString(_statesKey, f.states.join(','));
    prefs.setString(_viewModeKey, f.viewMode);
  }
}

final activityFiltersProvider =
    NotifierProvider<ActivityFiltersNotifier, ActivityFilters>(
        ActivityFiltersNotifier.new);
```

- [ ] **Step 3: Update `prsProvider` and `issuesProvider` to pass state filter**

In `dashboard_providers.dart`, modify the providers to read the state filter and pass it to the API:

```dart
final prsProvider = FutureProvider<List<PR>>((ref) async {
  ref.watch(prListRefreshProvider);
  ref.watch(meProvider);
  final filters = ref.watch(activityFiltersProvider);
  final api = ref.watch(apiClientProvider);
  final prs = await api.fetchPRs(states: filters.states.toList());
  // ... rest unchanged
});
```

Same for `issuesProvider`.

- [ ] **Step 4: Update all filter consumers**

Replace `ref.read(activityFiltersProvider.notifier).state = ...` with `ref.read(activityFiltersProvider.notifier).update(...)` in `activity_filter_bar.dart` and `dashboard_screen.dart`.

- [ ] **Step 5: Verify and commit**

Run: `cd flutter_app && flutter analyze --no-fatal-infos`

```bash
git add flutter_app/lib/features/dashboard/
git commit -m "feat(flutter): persistent activity filters with state and viewMode"
```

---

### Task 8: Flutter — Activity Filter Bar Extensions

**Files:**
- Modify: `flutter_app/lib/features/dashboard/activity_filter_bar.dart`

- [ ] **Step 1: Add state chips**

After the type chips (PR/IT/DEV), add Open/Closed chips:

```dart
const SizedBox(width: 8),
_stateChip('Open', 'open', Colors.green),
_stateChip('Closed', 'closed', Colors.grey),
```

Where `_stateChip` follows the same pattern as `_typeChip`:

```dart
Widget _stateChip(String label, String value, Color color) {
  final filters = ref.watch(activityFiltersProvider);
  final selected = filters.states.contains(value);
  return FilterChip(
    label: Text(label, style: TextStyle(fontSize: 11, color: selected ? Colors.white : null)),
    selected: selected,
    selectedColor: color,
    checkmarkColor: Colors.white,
    onSelected: (v) {
      final current = Set<String>.from(filters.states);
      v ? current.add(value) : current.remove(value);
      ref.read(activityFiltersProvider.notifier).update(
        filters.copyWith(states: current),
      );
    },
  );
}
```

- [ ] **Step 2: Add list/grid toggle**

At the right end of the filter bar:

```dart
const Spacer(),
_ViewToggleButton(
  icon: Icons.view_list,
  active: filters.viewMode == 'list',
  onTap: () => ref.read(activityFiltersProvider.notifier).update(
    filters.copyWith(viewMode: 'list'),
  ),
),
_ViewToggleButton(
  icon: Icons.grid_view,
  active: filters.viewMode == 'grid',
  onTap: () => ref.read(activityFiltersProvider.notifier).update(
    filters.copyWith(viewMode: 'grid'),
  ),
),
```

Copy `_ViewToggleButton` from `repos_screen.dart` (it's a small styled `IconButton`).

- [ ] **Step 3: Verify and commit**

Run: `cd flutter_app && flutter analyze --no-fatal-infos`

```bash
git add flutter_app/lib/features/dashboard/activity_filter_bar.dart
git commit -m "feat(flutter): state chips (Open/Closed) and list/grid toggle in Activity filter bar"
```

---

### Task 9: Flutter — Grid View and State Badge in Activity Tab

**Files:**
- Modify: `flutter_app/lib/features/dashboard/dashboard_screen.dart`

- [ ] **Step 1: Add StateBadge to `_PRTile`**

Import `state_badge.dart`. In the `_PRTile` build method, add the `StateBadge` next to the type badge:

```dart
// After the existing type badge:
const SizedBox(width: 4),
StateBadge(state: widget.pr.state),
```

Apply reduced opacity for closed items — wrap the tile's Card in an `Opacity` widget:

```dart
Opacity(
  opacity: widget.pr.state == 'open' ? 1.0 : 0.6,
  child: Card(... existing tile ...),
)
```

- [ ] **Step 2: Add StateBadge to `_IssueActivityTile`**

Same pattern — add `StateBadge` and opacity wrapper.

- [ ] **Step 3: Create `_ActivityGridTile` widget**

A compact card for the grid view:

```dart
class _ActivityGridTile extends StatelessWidget {
  final _ActivityItem item;
  const _ActivityGridTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final (type, color, state, title, subtitle, severity, timestamp) = switch (item) {
      _PRItem(:final pr) => ('PR', Colors.blue, pr.state, pr.title,
          '${pr.repo} #${pr.number} · ${pr.author}',
          pr.latestReview?.severity, pr.updatedAt),
      _IssueItem(:final issue) => (
          issue.latestReview?.actionTaken == 'auto_implement' ? 'DEV' : 'IT',
          issue.latestReview?.actionTaken == 'auto_implement' ? Colors.green : Colors.orange,
          issue.state, issue.title,
          '${issue.repo} #${issue.number} · ${issue.author}',
          issue.latestReview?.severity, issue.fetchedAt),
    };
    return Opacity(
      opacity: state == 'open' ? 1.0 : 0.6,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
                  child: Text(type, style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
                ),
                const Spacer(),
                StateBadge(state: state),
              ]),
              const SizedBox(height: 6),
              Text(title, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
              const SizedBox(height: 4),
              Text(subtitle, style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
              const Spacer(),
              Row(children: [
                if (severity != null)
                  SeverityBadge(severity: severity),
                const Spacer(),
                Text(_timeAgo(timestamp), style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Switch between list and grid in `_ActivityTab.build`**

Replace the current item rendering with a view mode switch:

```dart
final viewMode = filters.viewMode;
if (viewMode == 'grid')
  SliverGrid(
    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 280,
      childAspectRatio: 1.6,
      crossAxisSpacing: 8,
      mainAxisSpacing: 8,
    ),
    delegate: SliverChildBuilderDelegate(
      (ctx, i) => _ActivityGridTile(item: filtered[i]),
      childCount: filtered.length,
    ),
  )
else
  SliverList(
    delegate: SliverChildBuilderDelegate(
      (ctx, i) => switch (filtered[i]) {
        _PRItem(:final pr) => _PRTile(pr: pr),
        _IssueItem(:final issue) => _IssueActivityTile(issue: issue),
      },
      childCount: filtered.length,
    ),
  )
```

Note: this may require converting the current `Column` + `ListView` to a `CustomScrollView` with `SliverList`/`SliverGrid`. Follow the pattern from `repos_screen.dart` which already does this.

- [ ] **Step 5: Add SSE listener for state changes**

In the `_ActivityTab`, add listeners for the new SSE events:

```dart
ref.listen(sseStreamProvider, (_, next) {
  next.whenData((event) {
    if (event.type == 'pr_state_changed' || event.type == 'issue_state_changed') {
      // Refresh the lists to pick up the state change
      ref.invalidate(prsProvider);
      ref.invalidate(issuesProvider);
    }
  });
});
```

- [ ] **Step 6: Verify and commit**

Run: `cd flutter_app && flutter analyze --no-fatal-infos && flutter test`

```bash
git add flutter_app/lib/features/dashboard/dashboard_screen.dart flutter_app/lib/shared/widgets/state_badge.dart
git commit -m "feat(flutter): grid view, state badges, opacity for closed items, SSE state listener"
```

---

### Task 10: End-to-End Verification

**Files:** None (testing only)

- [ ] **Step 1: Run all daemon tests**

Run: `cd daemon && go test ./... -count=1`
Expected: all pass

- [ ] **Step 2: Run Flutter analysis and tests**

Run: `cd flutter_app && flutter analyze --no-fatal-infos && flutter test`
Expected: no issues, all tests pass

- [ ] **Step 3: Build daemon binary**

Run: `cd daemon && go build -o bin/heimdallm ./cmd/heimdallm`
Expected: clean build

- [ ] **Step 4: Build Flutter app**

Run: `cd flutter_app && flutter build macos --release`
Expected: clean build
