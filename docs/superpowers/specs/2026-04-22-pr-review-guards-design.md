# PR Review Guards — Design

**Date:** 2026-04-22
**Status:** Draft, awaiting user review
**Owner:** Víctor Bueno

## Problem

The PR review pipeline is re-reviewing PRs that should never have been reviewed. Two observed cases:

1. **Closed and merged PRs have been reviewed.** The Tier 2 search uses `is:pr is:open`, so Tier 2 is safe. But Tier 3 (the watch queue) never re-checks PR state before calling the review pipeline. A PR that was open when enqueued can be closed/merged by the time Tier 3 ticks; if its HEAD SHA also changed (push + close), the AI runs on a non-open PR and burns tokens.
2. **Yesterday's HEAD-SHA dedup fix (commit d16e51e) needs verification.** The unit test `TestPipeline_Run_SkipsReviewOnSameHeadSHA` covers the pipeline entry point, but there is no test confirming the Tier 3 path also short-circuits on an unchanged SHA.

Beyond these, the review process has no guards against obvious token-wasters: draft PRs and self-authored PRs (the daemon's own `auto_implement` output). The goal of this work is to close the correctness gap and add cheap token-economy guards, while making skip decisions observable via the existing activity log.

## Scope

In scope (guards G1–G5 from the brainstorming session):

- **G1.** Refresh PR state in Tier 3 before calling `runReview`; skip if not `open`.
- **G2.** Defense-in-depth state assert inside `pipeline.Run`.
- **G3.** Verification of yesterday's HEAD-SHA dedup fix via a Tier 3 path test and production log check.
- **G4.** Skip draft PRs, default **on**, operator-overridable.
- **G5.** Skip self-authored PRs (author == daemon's GitHub login), default **on**.

Out of scope for this spec (explicitly deferred):

- Reordering `FetchDiff` vs HEAD-SHA dedup (G7).
- Max diff size cap (G8).
- Per-hour review cap (G9).
- Skip-label (G6).
- Lockfile-only PR skip (G10).

## Architecture

### Guard evaluator

A new pure function `pipeline.Evaluate` owns the caller-side guards (state, draft, self-author). It does not touch the store or the network, so it is trivially testable and callable from both Tier 2 and Tier 3 before any PR enters `pipeline.Run`.

```go
// daemon/internal/pipeline/guards.go
package pipeline

type SkipReason string

const (
    SkipReasonNone         SkipReason = ""
    SkipReasonNotOpen      SkipReason = "not_open"
    SkipReasonDraft        SkipReason = "draft"
    SkipReasonSelfAuthored SkipReason = "self_authored"
)

type PRGate struct {
    State  string
    Draft  bool
    Author string
}

type GateConfig struct {
    SkipDrafts     bool
    SkipSelfAuthor bool
    BotLogin       string // empty disables the self-author check
}

func Evaluate(pr PRGate, cfg GateConfig) SkipReason
```

**Priority order** when multiple rules apply: `not_open` > `draft` > `self_authored`. `not_open` wins because it is the correctness guard; the others are policy.

### Where the evaluator runs

| Caller | Where | On skip |
|---|---|---|
| `tier2Adapter.FetchPRsToReview` | After the GitHub search returns PRs | Emit `EventReviewSkipped`; drop the PR from the returned slice |
| `tier2Adapter.HandleChange` (Tier 3) | After state refresh (see below), before `runReview` | Emit `EventReviewSkipped`; return nil |
| `pipeline.Run` | Top of the function, after `UpsertPR` | Log a structured warning and return `(prevReview-or-nil, nil)` without invoking the CLI |

The HEAD-SHA dedup stays where it is in `pipeline.Run` because it needs store access and on-demand SHA resolution — not a good fit for `Evaluate`.

### Tier 3 state refresh

Today `CheckItem` returns `(changed bool, err error)` and `HandleChange` builds its `gh.PullRequest` from `stored.State`, which is whatever Tier 2 last observed. For a PR that has merged since the last Tier 2 cycle, this is stale.

Change:

- `Tier3ItemChecker.CheckItem` returns `(changed bool, snap *ItemSnapshot, err error)`.
- `ItemSnapshot` carries the freshly-fetched `State`, `Draft`, `Author`, `UpdatedAt`.
- `RunTier3` threads `snap` into `HandleChange`.
- `tier2Adapter.HandleChange` uses `snap.State` to both call `Evaluate` and to populate the `gh.PullRequest` passed to `runReview`.

No extra GitHub call: the snapshot is built from the same API response `CheckItem` already makes.

### Config surface

```toml
[github.review_guards]
skip_drafts      = true
skip_self_author = true
```

Go:

```go
// daemon/internal/config/config.go
type GitHubConfig struct {
    // ...existing fields...
    ReviewGuards ReviewGuardsConfig `toml:"review_guards"`
}

type ReviewGuardsConfig struct {
    SkipDrafts     *bool `toml:"skip_drafts"`
    SkipSelfAuthor *bool `toml:"skip_self_author"`
}
```

Pointer-to-bool distinguishes unset (use default) from explicit `false`. Both defaults are `true`. A helper `(c *Config) ReviewGuards(botLogin string) pipeline.GateConfig` resolves defaults and returns the `GateConfig` callers pass into `Evaluate` and `RunOptions.Guards`.

### Activity log integration

- New SSE event type `EventReviewSkipped` in `daemon/internal/sse/events.go`, payload:

  ```json
  {"repo": "...", "pr_number": N, "pr_title": "...", "reason": "not_open|draft|self_authored"}
  ```

- `activity/recorder.go` gains `recordReviewSkipped(ev)` wired into `handle`. It inserts an activity row with `action="review_skipped"` and `outcome=<reason>`. The Flutter Activity tab needs a quick check during implementation to confirm it renders unknown action types (or that we add `review_skipped` to its known set and label map).

## Per-component changes

**`daemon/internal/github/models.go`** — verify `PullRequest.Draft` is present; add if missing.

**`daemon/internal/pipeline/guards.go`** (new) — `SkipReason`, `PRGate`, `GateConfig`, `Evaluate`.

**`daemon/internal/pipeline/pipeline.go`** — `RunOptions` gains `Guards GateConfig`. `Run` calls `Evaluate` after `UpsertPR`; on skip, logs and returns `(prevReview-or-nil, nil)` without invoking the CLI.

**`daemon/internal/scheduler/tier2.go`** — `Tier2PR` gains `Draft bool`. `Tier3ItemChecker.CheckItem` returns `(changed bool, snap *ItemSnapshot, err error)`. New `ItemSnapshot` struct with `State`, `Draft`, `Author`, `UpdatedAt`. `HandleChange(ctx, item, snap)`.

**`daemon/internal/scheduler/tier3.go`** — `RunTier3` captures `snap` from `CheckItem` and threads it into `HandleChange`.

**`daemon/cmd/heimdallm/main.go`** —
- `FetchPRsToReview`: populate `Draft` from the search result; call `Evaluate` per PR; skipped PRs emit `EventReviewSkipped` and are dropped.
- `CheckItem`: fetch the PR (switch from `GetIssue` to `GetPR` if the Issues API does not return `draft` for PRs); return `ItemSnapshot`.
- `HandleChange`: call `Evaluate` against the snapshot; skipped PRs emit `EventReviewSkipped` and return nil. Use `snap.State` when building the `gh.PullRequest`.
- `runReview`: build `GateConfig` from `a.cfg` and pass via `RunOptions.Guards`.

**`daemon/internal/sse/events.go`** — add `EventReviewSkipped = "review_skipped"`.

**`daemon/internal/activity/recorder.go`** — add `recordReviewSkipped` handler.

## Testing

**Unit tests:**

- `pipeline/guards_test.go` — table-driven test for `Evaluate` covering state × draft × author × config combinations; asserts the priority order.
- `pipeline/pipeline_test.go` — `TestPipeline_Run_SkipsWhenGatesFail`: executor not invoked, no review row inserted.
- `pipeline/pipeline_test.go` — `TestPipeline_Run_Tier3PathSkipsOnSameHeadSHA`: closes the gap in yesterday's fix by covering the Tier 3 re-entry path.
- `scheduler/tier3_test.go` — verify `RunTier3` threads the snapshot into `HandleChange`.
- `cmd/heimdallm` adapter tests — `FetchPRsToReview` filters out draft/self/closed PRs; `EventReviewSkipped` published per skip.
- `activity/recorder_test.go` — new event type inserts `action="review_skipped"`, `outcome=<reason>`.

**Integration smoke test (`daemon/integration_test.go`):**

- PR goes through Tier 2, gets reviewed, then appears in Tier 3 with snapshot state flipped to `"closed"`. Expect zero CLI executor calls on the second pass and an activity row with `outcome=not_open`.

**Manual verification of yesterday's HEAD-SHA fix:**

- After the guards land in a running daemon, grep logs for `"pipeline: skipping re-review, HEAD SHA unchanged"`. At least one hit from the next bot-feedback-loop scenario confirms the fix is live.

## Rollout

- All guard defaults are on. Operators who want the old behavior set `skip_drafts = false` and/or `skip_self_author = false` explicitly.
- Behavior-visible changes (drafts no longer reviewed by default, self-authored PRs no longer reviewed) documented in the next CHANGELOG entry.
