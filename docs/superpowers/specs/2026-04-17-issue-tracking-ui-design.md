# Issue Tracking UI — Design Spec

**Date**: 2026-04-17
**Issues**: [#28](https://github.com/theburrowhub/heimdallm/issues/28) (daemon endpoints), [#29](https://github.com/theburrowhub/heimdallm/issues/29) (Flutter UI)
**Scope**: Daemon HTTP endpoints for issues + Flutter desktop screens + unified dashboard

---

## Overview

Add issue tracking views to the Heimdallm desktop app. The daemon already has the store layer (`store.Issue`, `store.IssueReview`), the issue pipeline (`internal/issues/pipeline.go`), and SSE events for issues. What's missing:

1. **Daemon**: HTTP endpoints to serve issues and trigger reviews from the UI
2. **Flutter**: Models, API client methods, providers, screens, and dashboard unification

The dashboard's "Reviews" tab becomes a unified activity feed (PRs + Issues), and a new dedicated "Issues" tab provides filtered issue browsing.

---

## 1. Daemon — HTTP Endpoints

### 1.1 New Routes

Add to `buildRouter()` in `internal/server/handlers.go`:

| Method | Path | Handler | Auth |
|--------|------|---------|------|
| GET | `/issues` | `handleListIssues` | Token (add to `sensitiveGETPaths`) |
| GET | `/issues/{id}` | `handleGetIssue` | Token (prefix match in `sensitiveGETPaths`) |
| POST | `/issues/{id}/review` | `handleTriggerIssueReview` | Token |
| POST | `/issues/{id}/dismiss` | `handleDismissIssue` | Token |
| POST | `/issues/{id}/undismiss` | `handleUndismissIssue` | Token |

### 1.2 Handler Implementations

**`handleListIssues`** — follows `handleListPRs` pattern:
- `store.ListIssues()` returns non-dismissed issues
- For each issue, attach `LatestIssueReview()` as `latest_review` (nullable)
- Response: JSON array of `{...issue fields, "latest_review": {...} | null}`

**`handleGetIssue`** — follows `handleGetPR` pattern:
- `store.GetIssue(id)` + `store.ListIssueReviews(id)`
- Response: `{"issue": {...}, "reviews": [...]}`

**`handleDismissIssue` / `handleUndismissIssue`** — identical pattern to PR handlers:
- Parse `{id}` from URL, call `store.DismissIssue(id)` / `store.UndismissIssue(id)`
- Response: `{"status": "dismissed"}` / `{"status": "undismissed"}`

**`handleTriggerIssueReview`** — follows `handleTriggerReview` pattern:
- Uses the same `reviewSem` semaphore for concurrency limiting
- Calls a new `triggerIssueReviewFn` callback (wired in main.go)
- Returns `202 Accepted` with `{"status": "review queued"}`

### 1.3 Server Wiring

Add to `Server` struct:
- `triggerIssueReviewFn func(issueID int64) error`
- `SetTriggerIssueReviewFn(fn)` setter

### 1.4 main.go Wiring

Wire `SetTriggerIssueReviewFn` in main.go:
1. Load issue from store by ID
2. Reconstruct `github.Issue` from stored data
3. Build `issues.RunOptions` from config (same `buildRunOpts` pattern adapted for issues)
4. Call `issuePipeline.Run()`
5. Publish SSE events (`issue_review_started`, `issue_review_completed` or `issue_review_error`)

Create the issue pipeline instance in main.go:
```go
issuePipeline := issues.New(s, ghClient, exec, broker, &notifyWithSSE{notifier: notifier})
```

### 1.5 Scope Boundary

**NOT in scope**: Integrating issue fetching into the automatic poll cycle. That requires the full #28 + #27 dependency chain. This spec only adds HTTP endpoints + manual trigger, which is sufficient for the Flutter UI to be fully functional.

---

## 2. Flutter — Models

### 2.1 Naming Conflict

The existing `Issue` class (`core/models/issue.dart`) represents a code finding within a PR review (file, line, description, severity). The new model represents a GitHub Issue entity. To avoid collision:

- **Keep** existing `Issue` unchanged (used by `Review` model)
- **Create** `TrackedIssue` and `TrackedIssueReview` in a new file

### 2.2 TrackedIssue Model

File: `lib/core/models/tracked_issue.dart`

```dart
@JsonSerializable()
class TrackedIssue {
  final int id;
  @JsonKey(name: 'github_id')
  final int githubId;
  final String repo;
  final int number;
  final String title;
  final String body;
  final String author;
  final List<String> assignees;   // JSON array from daemon
  final List<String> labels;      // JSON array from daemon
  final String state;
  @JsonKey(name: 'created_at')
  final DateTime createdAt;
  @JsonKey(name: 'fetched_at')
  final DateTime fetchedAt;
  @JsonKey(defaultValue: false)
  final bool dismissed;
  @JsonKey(name: 'latest_review', includeIfNull: false)
  final TrackedIssueReview? latestReview;
}
```

### 2.3 TrackedIssueReview Model

Same file:

```dart
@JsonSerializable()
class TrackedIssueReview {
  final int id;
  @JsonKey(name: 'issue_id')
  final int issueId;
  @JsonKey(name: 'cli_used')
  final String cliUsed;
  final String summary;
  final Map<String, dynamic> triage;   // {severity, category, suggested_assignee}
  final List<dynamic> suggestions;
  @JsonKey(name: 'action_taken')
  final String actionTaken;            // "review_only" | "auto_implement"
  @JsonKey(name: 'pr_created')
  final int prCreated;
  @JsonKey(name: 'created_at')
  final DateTime createdAt;
}
```

Both use `@JsonSerializable()` + `build_runner`, matching the existing `PR` and `Review` pattern.

### 2.4 Daemon JSON Parsing

The daemon's `store.Issue` stores `assignees` and `labels` as JSON strings (`"[]"` when empty). The `handleListIssues` handler must parse these into arrays before serializing, OR the Flutter client must handle string→list conversion (same pattern as `_parseReviewMap` does for `issues`/`suggestions` in reviews).

**Decision**: Parse in the daemon handler (cleaner API contract). The handler will json.Unmarshal the strings before writing the response.

---

## 3. Flutter — API Client

### 3.1 New Methods in `api_client.dart`

```dart
Future<List<TrackedIssue>> fetchIssues()
Future<Map<String, dynamic>> fetchIssue(int id)    // {issue, reviews}
Future<void> triggerIssueReview(int issueId)
Future<void> dismissIssue(int issueId)
Future<void> undismissIssue(int issueId)
```

All follow the exact pattern of existing PR methods. `fetchIssues` and `fetchIssue` use `_authHeaders()`. `triggerIssueReview` returns 202 (accepted, not 200).

### 3.2 JSON Parsing

`fetchIssue` needs to parse `triage` (JSON string → Map) and `suggestions` (JSON string → List) for each review, same pattern as `_parseReviewMap`. Add `_parseIssueReviewMap` helper.

---

## 4. Flutter — Providers & SSE

### 4.1 New Providers

File: `lib/features/issues/issues_providers.dart`

```
issuesProvider          — FutureProvider<List<TrackedIssue>>
issueDetailProvider(id) — FutureProvider.family<Map<String, dynamic>, int>
reviewingIssuesProvider — StateProvider<Set<String>>  (keyed by "repo:issueNumber")
issueListRefreshProvider — StateProvider<int>  (same counter pattern as prListRefreshProvider)
```

`issuesProvider` watches `issueListRefreshProvider` to refresh on SSE events.

### 4.2 SSE Event Handling

Extend `_handleSseEvent` in `dashboard_providers.dart` to handle issue events:

| Event | Action |
|-------|--------|
| `issue_detected` | Increment `issueListRefreshProvider` |
| `issue_review_started` | Add to `reviewingIssuesProvider` |
| `issue_review_completed` | Remove from `reviewingIssuesProvider`, increment refresh counter |
| `issue_review_error` | Remove from `reviewingIssuesProvider` |

---

## 5. Flutter — Screens

### 5.1 IssuesScreen (dedicated tab)

File: `lib/features/issues/issues_screen.dart`

- Watches `issuesProvider`
- Shows filterable list of tracked issues
- **Filters**: repo dropdown, triage severity (from `latestReview.triage.severity`)
- Each issue rendered as `_IssueTile` card with:
  - Severity color bar (from triage, or grey if no review)
  - Title, repo, issue number, author
  - Labels as chips
  - Review status badge (triage severity) or "PENDING"
  - "Review" button + dismiss icon (same pattern as `_PRTile`)
- Tap navigates to `/issues/{id}`

### 5.2 IssueDetailScreen

File: `lib/features/issues/issue_detail_screen.dart`

- Two-panel layout (same as `PRDetailScreen`):
  - Left: review history (list of `TrackedIssueReview` cards)
  - Right: issue metadata (repo, number, author, labels, assignees, state, link to GitHub)
- AppBar with "Review" / "Re-review" button + "Dismiss" button
- SSE listener for real-time review progress
- Review card shows: summary, triage block (severity/category/suggested_assignee), suggestions list

### 5.3 Router

Add to `shared/router.dart`:
```dart
GoRoute(
  path: '/issues/:id',
  builder: (context, state) {
    final id = int.parse(state.pathParameters['id']!);
    return IssueDetailScreen(issueId: id);
  },
),
```

---

## 6. Dashboard Unification

### 6.1 Tab Changes

Dashboard goes from 5 to 6 tabs:

| # | Icon | Label | Content |
|---|------|-------|---------|
| 1 | `Icons.dashboard` | Activity | **Unified feed** — PRs + Issues sorted by activity |
| 2 | `Icons.bug_report` | Issues | **Dedicated** issue list with filters |
| 3 | `Icons.folder_outlined` | Repositories | Existing |
| 4 | `Icons.auto_awesome` | Prompts | Existing |
| 5 | `Icons.smart_toy` | Agents | Existing |
| 6 | `Icons.bar_chart` | Stats | Existing |

### 6.2 Activity Tab (unified feed)

Replaces the current "Reviews" tab. Combines:
- PRs from `prsProvider`
- Issues from `issuesProvider`

Both are wrapped in a common `ActivityItem` union:
```dart
sealed class ActivityItem {
  DateTime get activityDate;
}
class PRActivity extends ActivityItem { ... }
class IssueActivity extends ActivityItem { ... }
```

Sorted by `activityDate` descending (PR: `updatedAt`, Issue: `fetchedAt`). Each renders its own tile widget. The "My Reviews" / "My PRs" collapsible sections remain for PRs; issues get their own "Issues" section.

### 6.3 Refresh Button

The existing refresh button in the AppBar invalidates both `prsProvider` and `issuesProvider` (currently only invalidates `prsProvider` and `statsProvider`).

---

## 7. Testing

### 7.1 Daemon Tests

- `TestHandleListIssues` — insert issues + reviews, verify JSON response shape
- `TestHandleGetIssue` — verify issue + reviews returned
- `TestHandleDismissIssue` / `TestHandleUndismissIssue` — verify store state changes
- `TestHandleTriggerIssueReview` — verify 202 response, mock pipeline
- Auth tests: all issue endpoints require token

### 7.2 Flutter Tests

- `flutter analyze` passes (zero errors)
- Widget tests for `IssuesScreen` and `IssueDetailScreen` using provider overrides
- Verify SSE events trigger refresh

---

## 8. Files Changed

### Daemon (Go)
| File | Change |
|------|--------|
| `internal/server/handlers.go` | Add 5 issue handlers + routes + `sensitiveGETPaths` |
| `internal/server/handlers_test.go` | Tests for new handlers |
| `cmd/heimdallm/main.go` | Wire `triggerIssueReviewFn`, create issue pipeline |

### Flutter (Dart)
| File | Change |
|------|--------|
| `lib/core/models/tracked_issue.dart` | **New** — `TrackedIssue` + `TrackedIssueReview` models |
| `lib/core/models/tracked_issue.g.dart` | **New** — generated by build_runner |
| `lib/core/api/api_client.dart` | Add 5 issue methods |
| `lib/features/issues/issues_providers.dart` | **New** — Riverpod providers |
| `lib/features/issues/issues_screen.dart` | **New** — issues list with filters |
| `lib/features/issues/issue_detail_screen.dart` | **New** — issue detail two-panel view |
| `lib/features/dashboard/dashboard_screen.dart` | Add "Issues" tab, unify "Activity" tab |
| `lib/features/dashboard/dashboard_providers.dart` | Handle issue SSE events |
| `lib/shared/router.dart` | Add `/issues/:id` route |
