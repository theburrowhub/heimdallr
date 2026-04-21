# Repositories tab — filters, bulk actions, grid view, auto-discovery

**Date:** 2026-04-21
**Scope:** GitHub issue [#112](https://github.com/theburrowhub/heimdallm/issues/112) + bulk per-feature toggles for quick management across many repos.

---

## Overview

Overhaul the Repositories tab so it scales to users with 30+ repos:

1. Remove the manual **Discover** button; auto-discover repos from the daemon's poll cycle.
2. Add filter chips (**All / Monitored / Not monitored**) and a **List / Grid** view toggle.
3. Introduce **multi-select + a bulk-actions bar** to toggle *PR Review*, *Issue Tracking*, and *Develop* for any subset of repos without opening each detail page.
4. Unify the visual language: each of the three features has a dedicated colour used on LEDs, detail-screen section headers and switches, and the bulk bar.

The detail screen itself stays mostly the same; the only change is a coloured accent per section.

---

## 1. Feature palette

Three features, three persistent colours. Grey is shared for "off".

| Feature | Hex | Usage |
|---|---|---|
| PR Review | `#58a6ff` (blue) | LED · detail section border + switch · bulk bar label + switch |
| Issue Tracking | `#a371f7` (purple) | same |
| Develop | `#c79a87` (muted terracotta) | same |
| Off | `#2e333b` + 1px inset `#3b424c` outline | LEDs only (hollow grey) |

These colours appear everywhere the feature is referenced, so users learn the mapping once.

---

## 2. Toolbar

```
[ 🔍 Filter repos… ] [ All (N) | Monitored (N) | Not monitored (N) ] [ ☰ | ▦ ] [ ☁ Saved ]
```

- **Search** — unchanged.
- **Filter chips** — segmented control. Default **All**. Ephemeral: resets on tab switch, not persisted. (Per issue.)
- **View toggle** — List / Grid. Default **List**. Persists in `SharedPreferences`.
- **Saved indicator** — unchanged.
- **Discover button removed.**

---

## 3. List view

Unchanged from today except:

- **Checkbox** on the left of each card (always visible, always active).
- **LEDs simplified to 2 states** — on (feature colour) / off (hollow grey). Top→bottom order: PR Review, Issue Tracking, Develop.
- **LED tooltip** gets richer text (see §6).
- Monitored / Not monitored sections with org sub-headers (collapsible, state held only for the session).

Row layout:
```
[ ☐ ] [🔵🟣🟠] repo-name                       📁 local-dir   ›
```

---

## 4. Grid view

Responsive grid using `GridView.builder` with a `SliverGridDelegateWithMaxCrossAxisExtent` (max ~200 px per tile). Tile layout:

```
┌─────────────────────────┐
│ ☐            🔵 🟣 🟠   │
│                         │
│ repo-short-name         │
│ org-name                │
│                         │
│ 📁 local-dir            │
└─────────────────────────┘
```

- **Tap tile** (outside checkbox/LEDs) → navigate to detail (same as list).
- **Tap checkbox** → toggle selection.
- **Selected tile** gets the same blue accent as a selected list row.
- **LEDs** are horizontal on the tile (not vertical), in PR/IT/Dev order.
- Not-monitored tiles render at `opacity: 0.72` (same as list).
- Tiles use the existing section headers (Monitored / Not monitored) — each section is its own `SliverGrid` inside the scroll view.

---

## 5. Bulk actions bar

Appears above the sections when `selection.isNotEmpty`. Slides down; not modal.

```
┌──────────────────────────────────────────────────┐
│ [3 selected]   Bulk actions            [Clear]   │
├──────────────────────────────────────────────────┤
│ ● PR Review                                 [⚫━] │   ← switch on (blue)
│ ● Issue Tracking              [ MIXED ]   [~━~]  │   ← switch mixed (amber dash)
│ ● Develop                                   [━⚫] │   ← switch off (grey)
└──────────────────────────────────────────────────┘
```

- **Three rows**, one per feature. Each row: coloured dot prefix, feature name, Material switch (identical widget to the detail screen).
- **Aggregate states** (computed over the selection):
  - *all on* → switch on, coloured per feature
  - *all off* → switch off, grey
  - *mixed* → switch thumb in the middle with amber tint and a dash mark; a tiny amber **MIXED** pill appears to the left of the switch
- **Click behaviour:**
  - off → on: write `<feature>Enabled = true` to every selected repo
  - on → off: write `<feature>Enabled = false` to every selected repo
  - mixed → on: write `true` to all; next click → `false` (converges up first)
- **Clear** — dismisses the selection without any changes.
- **No text badges** like "all on (3/3)" — the switch carries the signal.
- The bar auto-saves using the same debounce pattern as the rest of the repos screen (`800 ms`).

---

## 6. LED tooltip

Each LED gets a Material `Tooltip` with a three-part body:

```
PR Review · On
The daemon auto-reviews PRs in this repo.
Source: repo-level (prEnabled = true)
```

Sources the tooltip can show:

| Feature | State | Source line |
|---|---|---|
| any | on | `Source: repo-level (<field> = true)` |
| any | on | `Source: inherited from global monitored list` |
| any | on | `Source: implied by per-repo labels` |
| any | off | `Source: disabled per-repo (<field> = false)` |
| any | off | `Source: globally disabled` |
| Develop | off | `Reason: no local directory configured (Develop requires one)` |

The on/off decision logic is the existing `prLedStatus / itLedStatus / devLedStatus`, collapsed to a boolean (`'off' → off`, `'repo' | 'global' → on`). The *source* string is derived from the same inputs.

---

## 7. Daemon-side auto-discovery

### 7.1 Review-requested auto-upsert (new)

`daemon/cmd/heimdallm/main.go` already calls `FetchPRsToReview()` each poll cycle. After the call, iterate the result set and, for any repo not in the known list, upsert it.

- Writes go through `config.Store` so they persist.
- Thread-safe: grab `cfgMu` before mutating.
- Emits an SSE event (`repo-discovered`) so the Flutter app can refresh without polling.
- **Initial state** is controlled by a new TOML field:

```toml
[github]
auto_enable_pr_review_on_discovery = true   # default true
```

  - `true` → `prEnabled: true` (matches the old manual Discover button's behaviour)
  - `false` → `prEnabled: false` (safer — repo appears in *Not monitored*)

### 7.2 Topic-based discovery (unchanged)

Remains as-is: `discovery_topic` + `discovery_orgs` + `discovery_interval`. Runs on its own timer, uses GitHub Search API, cache preserved on transient errors. Operates alongside the new review-requested upsert; both add, neither removes.

### 7.3 NEW badge

When a repo is first discovered (by either mechanism), the daemon marks it with a `first_seen_at` timestamp. The Flutter app shows a small blue **NEW** badge on the card/tile until the user interacts with it (toggles anything, opens the detail page, or dismisses the badge explicitly). State is kept in `SharedPreferences`.

---

## 8. Data model changes

### 8.1 Flutter

No changes to `RepoConfig`. New UI-only state in `ReposScreen`:

```dart
Set<String> _selected = {};     // selected repo keys
bool _isGridView = false;       // persisted in SharedPreferences
String _filter = 'all';         // 'all' | 'monitored' | 'not_monitored', ephemeral
Set<String> _seenNew = {};      // repos the user has already interacted with
```

### 8.2 Daemon

```go
type GitHubConfig struct {
    // ... existing fields ...
    AutoEnablePROnDiscovery *bool `toml:"auto_enable_pr_review_on_discovery"`  // nil = default true
}
```

Per-repo metadata gets a new field in `config.Store`:

```go
FirstSeenAt time.Time  // zero value = existed before this feature shipped
```

---

## 9. Component breakdown

New / updated files:

```
flutter_app/lib/features/repositories/
  repos_screen.dart               (rewrite — toolbar, bulk bar, selection state)
  widgets/
    bulk_actions_bar.dart         (new)
    repo_list_tile.dart           (extracted — used by list view)
    repo_grid_tile.dart           (new — used by grid view)
    feature_led.dart              (new — 2-state LED with tooltip)
    feature_palette.dart          (new — colour constants)
  repo_detail_screen.dart         (small change — coloured section accents)

daemon/internal/
  config/config.go                (add AutoEnablePROnDiscovery + first-seen tracking)
  server/handlers.go              (SSE event: repo-discovered)
daemon/cmd/heimdallm/main.go      (upsert after FetchPRsToReview)
```

Each widget is self-contained: `FeatureLed`, `BulkActionsBar`, `RepoListTile`, `RepoGridTile` all take plain data + callbacks, no direct Riverpod access. They can be previewed and tested independently.

---

## 10. Accessibility

- LEDs are not the only carrier — tooltip text is available to screen readers via `Semantics(label:)`.
- Colour choices tested against WCAG AA on `#1c1f24` background (dark theme) and `#ffffff` (light theme).
- Selection checkboxes reachable via keyboard; bulk bar switches participate in the normal focus ring.
- **MIXED** tag uses both colour and text — not colour alone.

---

## 11. Backwards compatibility

- Filter chips are additive — no existing config changes.
- View toggle defaults to List — users who don't touch it see nothing different in layout.
- The auto-discovery setting defaults to `true`, which matches today's manual-Discover behaviour (`prEnabled: true`). No existing user will see a behavioural regression.
- Topic-based discovery and all existing `[github]` fields are untouched.
- LED simplification (3→2 states) only removes the blue "inherited" colour; inheritance is still surfaced via the tooltip source line, so no information is lost.
- Bulk bar is purely new; it coexists with single-row navigation.

---

## 12. Testing notes

- **Widget tests** for `FeatureLed`, `BulkActionsBar`, `RepoGridTile`, `RepoListTile` — state transitions, tap handlers, tooltips.
- **Golden tests** for list and grid layouts with realistic repo sets (monitored/not, with/without local dir, NEW badge present).
- **Integration test** for the daemon upsert: feed a fake `FetchPRsToReview` response containing a new repo, assert the store receives it with the right `prEnabled` based on `AutoEnablePROnDiscovery`.
- **Store migration test** — reading an existing config written before this feature must not break.
- Manual walkthrough: start daemon with 0 repos, open Flutter app, request a review on a fresh repo, verify it appears within one poll cycle with a NEW badge.

---

## 13. Out of scope

- Changing what the detail screen offers (beyond coloured section accents).
- Exposing topic-based discovery in the app UI.
- Removing a repo via any automatic path.
- Cross-org bulk operations different from a manual multi-select (e.g. "disable everything in this org") — the user can always select everything in a section with one click, which covers it.

---

## 14. Open questions

None currently — all decisions captured above. Questions that surface during implementation should be flagged in the PR.
