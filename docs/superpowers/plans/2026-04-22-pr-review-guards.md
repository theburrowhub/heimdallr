# PR Review Guards Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the closed/merged-PR review hole, verify yesterday's HEAD-SHA dedup covers the Tier 3 path, and add default-on guards that skip draft and self-authored PRs. Every skip is emitted as an SSE event and lands in the activity log.

**Architecture:** Introduce a pure `pipeline.Evaluate(PRGate, GateConfig) SkipReason` called at Tier 2 filter time, after Tier 3 state refresh, and again at the top of `pipeline.Run` for defense in depth. Tier 3 `CheckItem` is extended to return an `ItemSnapshot` (fresh state/draft/author) so `HandleChange` has live data instead of using the stale DB copy.

**Tech Stack:** Go 1.x, BurntSushi/toml, modernc.org/sqlite, existing SSE broker and activity recorder.

**Spec:** `docs/superpowers/specs/2026-04-22-pr-review-guards-design.md`

---

## File Structure

**New files:**
- `daemon/internal/pipeline/guards.go` — `SkipReason`, `PRGate`, `GateConfig`, `Evaluate`.
- `daemon/internal/pipeline/guards_test.go` — table-driven coverage for `Evaluate`.

**Modified:**
- `daemon/internal/github/models.go` — add `Draft bool` to `PullRequest`.
- `daemon/internal/github/client.go` — new `GetPRSnapshot` helper for Tier 3.
- `daemon/internal/config/config.go` — `ReviewGuardsConfig` + `(c *Config) ReviewGuards(botLogin string) pipeline.GateConfig`.
- `daemon/internal/sse/broker.go` — new `EventReviewSkipped` constant.
- `daemon/internal/activity/recorder.go` — `recordReviewSkipped` handler.
- `daemon/internal/pipeline/pipeline.go` — `RunOptions.Guards` + defense-in-depth `Evaluate` call.
- `daemon/internal/scheduler/tier2.go` — `Tier2PR.Draft`, `ItemSnapshot`, new `CheckItem` and `HandleChange` signatures.
- `daemon/internal/scheduler/tier3.go` — thread snapshot through.
- `daemon/cmd/heimdallm/main.go` — populate Draft, call `Evaluate` in `FetchPRsToReview` and `HandleChange`, swap `GetIssue` → `GetPRSnapshot` for PRs.

**Test files (modified):**
- `daemon/internal/pipeline/pipeline_test.go` — add gate-skip test + Tier 3 path HEAD-SHA test.
- `daemon/internal/scheduler/tier3_test.go` — verify snapshot is threaded.
- `daemon/internal/activity/recorder_test.go` — new event handler.
- `daemon/integration_test.go` — end-to-end closed-PR smoke.

---

## Task 1: Add `Draft` field to `PullRequest`

**Files:**
- Modify: `daemon/internal/github/models.go`

- [ ] **Step 1: Add field to struct**

Edit `daemon/internal/github/models.go`, add `Draft` to `PullRequest`:

```go
type PullRequest struct {
	ID        int64     `json:"id"`
	Number    int       `json:"number"`
	Title     string    `json:"title"`
	HTMLURL   string    `json:"html_url"`
	User      User      `json:"user"`
	State     string    `json:"state"`
	Draft     bool      `json:"draft"`
	UpdatedAt time.Time `json:"updated_at"`
	Head      Branch    `json:"head"`
	RepositoryURL string `json:"repository_url"`
	Repo string `json:"-"`
}
```

- [ ] **Step 2: Build to confirm no compile breakage**

Run: `cd daemon && go build ./...`
Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
git add daemon/internal/github/models.go
git commit -m "feat(github): add Draft field to PullRequest"
```

---

## Task 2: Create the `Evaluate` guard function + tests

**Files:**
- Create: `daemon/internal/pipeline/guards.go`
- Create: `daemon/internal/pipeline/guards_test.go`

- [ ] **Step 1: Write the failing test**

Create `daemon/internal/pipeline/guards_test.go`:

```go
package pipeline_test

import (
	"testing"

	"github.com/heimdallm/daemon/internal/pipeline"
)

func TestEvaluate(t *testing.T) {
	cases := []struct {
		name string
		pr   pipeline.PRGate
		cfg  pipeline.GateConfig
		want pipeline.SkipReason
	}{
		{
			name: "open non-draft by human — allowed",
			pr:   pipeline.PRGate{State: "open", Draft: false, Author: "alice"},
			cfg:  pipeline.GateConfig{SkipDrafts: true, SkipSelfAuthor: true, BotLogin: "heimdallm-bot"},
			want: pipeline.SkipReasonNone,
		},
		{
			name: "closed — not_open wins over everything",
			pr:   pipeline.PRGate{State: "closed", Draft: true, Author: "heimdallm-bot"},
			cfg:  pipeline.GateConfig{SkipDrafts: true, SkipSelfAuthor: true, BotLogin: "heimdallm-bot"},
			want: pipeline.SkipReasonNotOpen,
		},
		{
			name: "merged — not_open",
			pr:   pipeline.PRGate{State: "merged", Draft: false, Author: "alice"},
			cfg:  pipeline.GateConfig{SkipDrafts: true, SkipSelfAuthor: true, BotLogin: "heimdallm-bot"},
			want: pipeline.SkipReasonNotOpen,
		},
		{
			name: "open draft with skip_drafts=true — draft",
			pr:   pipeline.PRGate{State: "open", Draft: true, Author: "alice"},
			cfg:  pipeline.GateConfig{SkipDrafts: true, SkipSelfAuthor: true, BotLogin: "heimdallm-bot"},
			want: pipeline.SkipReasonDraft,
		},
		{
			name: "open draft with skip_drafts=false — allowed",
			pr:   pipeline.PRGate{State: "open", Draft: true, Author: "alice"},
			cfg:  pipeline.GateConfig{SkipDrafts: false, SkipSelfAuthor: true, BotLogin: "heimdallm-bot"},
			want: pipeline.SkipReasonNone,
		},
		{
			name: "open self-authored with skip_self_author=true — self_authored",
			pr:   pipeline.PRGate{State: "open", Draft: false, Author: "heimdallm-bot"},
			cfg:  pipeline.GateConfig{SkipDrafts: true, SkipSelfAuthor: true, BotLogin: "heimdallm-bot"},
			want: pipeline.SkipReasonSelfAuthored,
		},
		{
			name: "open self-authored with skip_self_author=false — allowed",
			pr:   pipeline.PRGate{State: "open", Draft: false, Author: "heimdallm-bot"},
			cfg:  pipeline.GateConfig{SkipDrafts: true, SkipSelfAuthor: false, BotLogin: "heimdallm-bot"},
			want: pipeline.SkipReasonNone,
		},
		{
			name: "empty bot login disables self-author check",
			pr:   pipeline.PRGate{State: "open", Draft: false, Author: ""},
			cfg:  pipeline.GateConfig{SkipDrafts: true, SkipSelfAuthor: true, BotLogin: ""},
			want: pipeline.SkipReasonNone,
		},
		{
			name: "draft + self-authored — draft wins (priority)",
			pr:   pipeline.PRGate{State: "open", Draft: true, Author: "heimdallm-bot"},
			cfg:  pipeline.GateConfig{SkipDrafts: true, SkipSelfAuthor: true, BotLogin: "heimdallm-bot"},
			want: pipeline.SkipReasonDraft,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := pipeline.Evaluate(tc.pr, tc.cfg)
			if got != tc.want {
				t.Errorf("Evaluate(%+v, %+v) = %q, want %q", tc.pr, tc.cfg, got, tc.want)
			}
		})
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd daemon && go test ./internal/pipeline/ -run TestEvaluate -v`
Expected: FAIL — `pipeline.Evaluate` undefined.

- [ ] **Step 3: Create the guard file**

Create `daemon/internal/pipeline/guards.go`:

```go
package pipeline

// SkipReason is the enumerated reason a PR was skipped by Evaluate.
// The empty string means "no skip; run the review".
type SkipReason string

const (
	SkipReasonNone         SkipReason = ""
	SkipReasonNotOpen      SkipReason = "not_open"
	SkipReasonDraft        SkipReason = "draft"
	SkipReasonSelfAuthored SkipReason = "self_authored"
)

// PRGate is the minimal PR view the guard evaluator needs. Callers synthesize
// this from whatever source they have (Tier 2 search results, Tier 3 snapshot)
// so this package does not need to import the scheduler or GitHub packages.
type PRGate struct {
	State  string
	Draft  bool
	Author string
}

// GateConfig controls which guards apply. Fields default to false; callers are
// expected to build this via config.ReviewGuards so defaults are applied once
// at the config edge.
type GateConfig struct {
	SkipDrafts     bool
	SkipSelfAuthor bool
	// BotLogin is the daemon's own GitHub login. Empty disables the
	// self-author check regardless of SkipSelfAuthor — there is nothing safe
	// to compare against.
	BotLogin string
}

// Evaluate returns the first applicable skip reason, or SkipReasonNone.
// Priority order: not_open > draft > self_authored. not_open wins because it
// is the correctness guard — the other two are policy.
func Evaluate(pr PRGate, cfg GateConfig) SkipReason {
	if pr.State != "open" {
		return SkipReasonNotOpen
	}
	if cfg.SkipDrafts && pr.Draft {
		return SkipReasonDraft
	}
	if cfg.SkipSelfAuthor && cfg.BotLogin != "" && pr.Author == cfg.BotLogin {
		return SkipReasonSelfAuthored
	}
	return SkipReasonNone
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd daemon && go test ./internal/pipeline/ -run TestEvaluate -v`
Expected: PASS, all 9 subtests green.

- [ ] **Step 5: Commit**

```bash
git add daemon/internal/pipeline/guards.go daemon/internal/pipeline/guards_test.go
git commit -m "feat(pipeline): add PR review guard evaluator"
```

---

## Task 3: Config surface for review guards

**Files:**
- Modify: `daemon/internal/config/config.go`
- Modify: `daemon/internal/config/config_test.go` (or create if absent)

- [ ] **Step 1: Write the failing test**

Append to `daemon/internal/config/config_test.go`:

```go
func TestReviewGuards_Defaults(t *testing.T) {
	c := &config.Config{} // zero config — all pointers nil
	g := c.ReviewGuards("heimdallm-bot")
	if !g.SkipDrafts {
		t.Errorf("SkipDrafts default = false, want true")
	}
	if !g.SkipSelfAuthor {
		t.Errorf("SkipSelfAuthor default = false, want true")
	}
	if g.BotLogin != "heimdallm-bot" {
		t.Errorf("BotLogin = %q, want heimdallm-bot", g.BotLogin)
	}
}

func TestReviewGuards_ExplicitFalse(t *testing.T) {
	f := false
	c := &config.Config{
		GitHub: config.GitHubConfig{
			ReviewGuards: config.ReviewGuardsConfig{
				SkipDrafts:     &f,
				SkipSelfAuthor: &f,
			},
		},
	}
	g := c.ReviewGuards("bot")
	if g.SkipDrafts {
		t.Errorf("SkipDrafts: explicit false not honoured")
	}
	if g.SkipSelfAuthor {
		t.Errorf("SkipSelfAuthor: explicit false not honoured")
	}
}
```

Add the import if needed:

```go
import "github.com/heimdallm/daemon/internal/config"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd daemon && go test ./internal/config/ -run TestReviewGuards -v`
Expected: FAIL — `ReviewGuardsConfig` / `ReviewGuards` undefined.

- [ ] **Step 3: Add the config struct**

Edit `daemon/internal/config/config.go`. Append the new type below `IssueTrackingConfig`:

```go
// ReviewGuardsConfig configures the caller-side skip rules applied before a PR
// enters the review pipeline. Pointer-to-bool lets "unset" apply the default;
// explicit false disables a guard.
type ReviewGuardsConfig struct {
	SkipDrafts     *bool `toml:"skip_drafts"`
	SkipSelfAuthor *bool `toml:"skip_self_author"`
}
```

Add the field to `GitHubConfig`:

```go
// Find GitHubConfig, add alongside IssueTracking:
ReviewGuards ReviewGuardsConfig `toml:"review_guards"`
```

Add the helper at the bottom of the file:

```go
// ReviewGuards resolves configured guard toggles against their defaults and
// returns the pipeline.GateConfig callers pass to pipeline.Evaluate and into
// pipeline.RunOptions.Guards. Both booleans default to true.
//
// The pipeline package is imported here so config can hand back a ready-to-use
// value; this is a one-way dependency (pipeline does not import config).
func (c *Config) ReviewGuards(botLogin string) pipeline.GateConfig {
	g := pipeline.GateConfig{
		SkipDrafts:     true,
		SkipSelfAuthor: true,
		BotLogin:       botLogin,
	}
	if v := c.GitHub.ReviewGuards.SkipDrafts; v != nil {
		g.SkipDrafts = *v
	}
	if v := c.GitHub.ReviewGuards.SkipSelfAuthor; v != nil {
		g.SkipSelfAuthor = *v
	}
	return g
}
```

Add the pipeline import:

```go
import (
	// ...existing imports...
	"github.com/heimdallm/daemon/internal/pipeline"
)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd daemon && go test ./internal/config/ -run TestReviewGuards -v`
Expected: PASS, 2 subtests.

- [ ] **Step 5: Run full config tests to check no other breakage**

Run: `cd daemon && go test ./internal/config/ -v`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add daemon/internal/config/config.go daemon/internal/config/config_test.go
git commit -m "feat(config): add github.review_guards section"
```

---

## Task 4: SSE event + activity recorder for skips

**Files:**
- Modify: `daemon/internal/sse/broker.go`
- Modify: `daemon/internal/activity/recorder.go`
- Modify: `daemon/internal/activity/recorder_test.go`

- [ ] **Step 1: Add the event constant**

Edit `daemon/internal/sse/broker.go`. In the first `const` block, after `EventReviewError`:

```go
EventReviewError   = "review_error"
EventReviewSkipped = "review_skipped"
```

- [ ] **Step 2: Write the failing recorder test**

Append to `daemon/internal/activity/recorder_test.go`:

```go
func TestRecorder_ReviewSkipped(t *testing.T) {
	store := &fakeStore{}
	ch := make(chan sse.Event, 1)
	r := activity.NewWithChannel(store, ch)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { r.Start(ctx); close(done) }()

	ch <- sse.Event{
		Type: sse.EventReviewSkipped,
		Data: `{"repo":"org/name","pr_number":42,"pr_title":"Fix X","reason":"draft"}`,
	}

	// Wait for the insert to happen; fakeStore records synchronously.
	time.Sleep(50 * time.Millisecond)
	cancel()
	<-done

	if store.action != "review_skipped" {
		t.Errorf("action = %q, want review_skipped", store.action)
	}
	if store.outcome != "draft" {
		t.Errorf("outcome = %q, want draft", store.outcome)
	}
	if store.itemType != "pr" || store.itemNumber != 42 {
		t.Errorf("item = %s#%d, want pr#42", store.itemType, store.itemNumber)
	}
	if store.repo != "org/name" || store.org != "org" {
		t.Errorf("repo/org = %q/%q, want org/name + org", store.repo, store.org)
	}
}
```

(If `fakeStore` and `NewWithChannel` already exist from prior tests, reuse them — check the existing file first. If the import list is missing `time` or `context`, add them.)

- [ ] **Step 3: Run test to verify it fails**

Run: `cd daemon && go test ./internal/activity/ -run TestRecorder_ReviewSkipped -v`
Expected: FAIL — `EventReviewSkipped` handler missing, outcome and action empty.

- [ ] **Step 4: Add the recorder handler**

Edit `daemon/internal/activity/recorder.go`. In the `handle` switch:

```go
case sse.EventReviewCompleted:
    return r.recordReviewCompleted(ev)
case sse.EventReviewError:
    return r.recordReviewError(ev)
case sse.EventReviewSkipped:
    return r.recordReviewSkipped(ev)
```

Append the handler at the end of the file:

```go
func (r *Recorder) recordReviewSkipped(ev sse.Event) error {
	var p struct {
		Repo     string `json:"repo"`
		PRNumber int    `json:"pr_number"`
		PRTitle  string `json:"pr_title"`
		Reason   string `json:"reason"`
	}
	if err := decode(ev.Data, &p); err != nil {
		return err
	}
	_, err := r.store.InsertActivity(time.Now(), orgOf(p.Repo), p.Repo, "pr",
		p.PRNumber, p.PRTitle, "review_skipped", p.Reason, map[string]any{
			"reason": p.Reason,
		})
	return err
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd daemon && go test ./internal/activity/ -v`
Expected: PASS including TestRecorder_ReviewSkipped.

- [ ] **Step 6: Commit**

```bash
git add daemon/internal/sse/broker.go daemon/internal/activity/recorder.go daemon/internal/activity/recorder_test.go
git commit -m "feat(activity): record review_skipped events"
```

---

## Task 5: Defense-in-depth Evaluate inside `pipeline.Run`

**Files:**
- Modify: `daemon/internal/pipeline/pipeline.go`
- Modify: `daemon/internal/pipeline/pipeline_test.go`

- [ ] **Step 1: Write the failing test**

Append to `daemon/internal/pipeline/pipeline_test.go`:

```go
// TestPipeline_Run_GateSkipsReview: when the guard evaluator returns a skip
// reason (here: state != "open"), the pipeline must not call the executor or
// submit a review. Proves the defense-in-depth layer protects future callers
// that forget the caller-side Evaluate.
func TestPipeline_Run_GateSkipsReview(t *testing.T) {
	s, err := store.Open(":memory:")
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer s.Close()

	exec := &fakeExecCounter{}
	gh := &fakeGHCounter{diff: "+line"}
	p := pipeline.New(s, gh, exec, &fakeNotify{})

	pr := &github.PullRequest{
		ID: 100, Number: 100, Title: "t", Repo: "org/repo",
		User: github.User{Login: "alice"}, State: "closed",
		UpdatedAt: time.Now(), HTMLURL: "https://github.com/org/repo/pull/100",
		Head: github.Branch{SHA: "abc"},
	}
	opts := pipeline.RunOptions{
		Primary: "claude", Fallback: "gemini",
		Guards: pipeline.GateConfig{SkipDrafts: true, SkipSelfAuthor: true, BotLogin: "heimdallm-bot"},
	}
	rev, err := p.Run(pr, opts)
	if err != nil {
		t.Fatalf("run: %v", err)
	}
	if exec.calls != 0 {
		t.Errorf("executor called on gate-skipped PR: calls=%d", exec.calls)
	}
	if gh.submits != 0 {
		t.Errorf("SubmitReview called on gate-skipped PR: submits=%d", gh.submits)
	}
	if rev != nil {
		t.Errorf("expected nil review on gate skip, got %+v", rev)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd daemon && go test ./internal/pipeline/ -run TestPipeline_Run_GateSkipsReview -v`
Expected: FAIL — `RunOptions.Guards` undefined, executor called.

- [ ] **Step 3: Add Guards field and the guard call**

Edit `daemon/internal/pipeline/pipeline.go`. In `RunOptions`:

```go
type RunOptions struct {
	Primary        string
	Fallback       string
	PromptOverride string
	AgentPromptID  string
	ReviewMode     string
	ExecOpts       executor.ExecOptions
	// Guards are evaluated at the top of Run as defense-in-depth. Callers
	// (Tier 2 / Tier 3) should have already filtered with pipeline.Evaluate
	// before pushing PRs into the pipeline; this layer prevents regressions
	// if a new caller forgets.
	Guards GateConfig
}
```

After the existing `UpsertPR` block (immediately before `p.notify.Notify("PR Review Started", ...)`), add:

```go
	// Defense-in-depth: refuse to run the CLI if the gate rejects this PR.
	// Callers publish the skip event themselves — we only log here so a
	// missed caller-side check is visible in daemon logs.
	if reason := Evaluate(PRGate{
		State:  pr.State,
		Draft:  pr.Draft,
		Author: pr.User.Login,
	}, opts.Guards); reason != SkipReasonNone {
		slog.Warn("pipeline: gate skip (caller did not filter)",
			"repo", pr.Repo, "pr", pr.Number, "reason", string(reason))
		return nil, nil
	}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd daemon && go test ./internal/pipeline/ -v`
Expected: PASS for TestPipeline_Run_GateSkipsReview; all prior tests still green (they pass an empty `Guards`, which defaults `SkipDrafts=false` / `SkipSelfAuthor=false`, and their PRs have `State:"open"`, so the gate returns SkipReasonNone).

- [ ] **Step 5: Commit**

```bash
git add daemon/internal/pipeline/pipeline.go daemon/internal/pipeline/pipeline_test.go
git commit -m "feat(pipeline): defense-in-depth guard evaluator in Run"
```

---

## Task 6: Tier 3 regression test for HEAD-SHA dedup

This closes gap G3 — proves yesterday's HEAD-SHA fix also short-circuits the Tier 3 re-entry path, not just the Tier 2 entry path.

**Files:**
- Modify: `daemon/internal/pipeline/pipeline_test.go`

- [ ] **Step 1: Write the test**

Append to `daemon/internal/pipeline/pipeline_test.go`:

```go
// TestPipeline_Run_Tier3PathSkipsOnSameHeadSHA simulates the Tier 3 re-entry:
// after Tier 2 reviewed commit X, Tier 3 calls pipeline.Run again on the same
// PR at the same SHA (because GitHub's updated_at bumped for an unrelated
// reason — merge metadata, a comment, etc.). The HEAD-SHA guard must kick in
// and short-circuit the CLI/publish steps.
func TestPipeline_Run_Tier3PathSkipsOnSameHeadSHA(t *testing.T) {
	s, err := store.Open(":memory:")
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer s.Close()

	exec := &fakeExecCounter{}
	gh := &fakeGHCounter{diff: "+line"}
	p := pipeline.New(s, gh, exec, &fakeNotify{})

	prT2 := &github.PullRequest{
		ID: 900, Number: 900, Title: "t", Repo: "org/repo",
		User: github.User{Login: "alice"}, State: "open",
		UpdatedAt: time.Now(), HTMLURL: "https://github.com/org/repo/pull/900",
		Head: github.Branch{SHA: "sha-one"},
	}
	if _, err := p.Run(prT2, pipeline.RunOptions{Primary: "claude"}); err != nil {
		t.Fatalf("tier2 run: %v", err)
	}
	if exec.calls != 1 {
		t.Fatalf("expected first run to invoke CLI, got calls=%d", exec.calls)
	}

	// Tier 3 re-entry: same PR, same SHA, bumped updated_at.
	prT3 := *prT2
	prT3.UpdatedAt = prT2.UpdatedAt.Add(2 * time.Minute)
	if _, err := p.Run(&prT3, pipeline.RunOptions{Primary: "claude"}); err != nil {
		t.Fatalf("tier3 run: %v", err)
	}
	if exec.calls != 1 {
		t.Errorf("Tier 3 re-run invoked CLI on same SHA: calls=%d", exec.calls)
	}
	if gh.submits != 1 {
		t.Errorf("Tier 3 re-run submitted review on same SHA: submits=%d", gh.submits)
	}
}
```

- [ ] **Step 2: Run the test**

Run: `cd daemon && go test ./internal/pipeline/ -run TestPipeline_Run_Tier3PathSkipsOnSameHeadSHA -v`
Expected: PASS (confirms the existing HEAD-SHA guard already covers this path).

- [ ] **Step 3: Commit**

```bash
git add daemon/internal/pipeline/pipeline_test.go
git commit -m "test(pipeline): cover Tier 3 re-entry path for HEAD-SHA dedup"
```

---

## Task 7: Add `Draft` to `Tier2PR` and thread it from the GitHub search

**Files:**
- Modify: `daemon/internal/scheduler/tier2.go`
- Modify: `daemon/cmd/heimdallm/main.go`

- [ ] **Step 1: Add Draft to Tier2PR**

Edit `daemon/internal/scheduler/tier2.go`:

```go
type Tier2PR struct {
	ID        int64
	Number    int
	Repo      string
	Title     string
	HTMLURL   string
	Author    string
	State     string
	Draft     bool
	UpdatedAt time.Time
}
```

- [ ] **Step 2: Populate Draft in the adapter**

Edit `daemon/cmd/heimdallm/main.go`, in `tier2Adapter.FetchPRsToReview` (around line 1079–1095), update the struct literal:

```go
out = append(out, scheduler.Tier2PR{
    ID:        pr.ID,
    Number:    pr.Number,
    Repo:      pr.Repo,
    Title:     pr.Title,
    HTMLURL:   pr.HTMLURL,
    Author:    pr.User.Login,
    State:     pr.State,
    Draft:     pr.Draft,
    UpdatedAt: pr.UpdatedAt,
})
```

And in `ProcessPR` (around line 1101), propagate Draft to the `gh.PullRequest`:

```go
ghPR := &gh.PullRequest{
    ID:        pr.ID,
    Number:    pr.Number,
    Repo:      pr.Repo,
    Title:     pr.Title,
    HTMLURL:   pr.HTMLURL,
    User:      gh.User{Login: pr.Author},
    State:     pr.State,
    Draft:     pr.Draft,
    UpdatedAt: pr.UpdatedAt,
}
```

- [ ] **Step 3: Build to confirm**

Run: `cd daemon && go build ./...`
Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add daemon/internal/scheduler/tier2.go daemon/cmd/heimdallm/main.go
git commit -m "feat(scheduler): thread Draft flag through Tier 2"
```

---

## Task 8: Caller-side guard in `FetchPRsToReview`

**Files:**
- Modify: `daemon/cmd/heimdallm/main.go`

- [ ] **Step 1: Emit skips for drafts/self/closed**

In `daemon/cmd/heimdallm/main.go`, inside `tier2Adapter.FetchPRsToReview`, before the `for _, pr := range prs` loop that builds `out`, resolve the bot login and guard config. Replace the existing loop (around line 1079–1095) with:

```go
// Resolve bot login for the self-author guard.
a.loginMu.Lock()
botLogin := *a.login
a.loginMu.Unlock()
if botLogin == "" {
    if u, err := a.ghClient.AuthenticatedUser(); err == nil {
        botLogin = u
        a.loginMu.Lock()
        *a.login = u
        a.loginMu.Unlock()
    }
}

a.cfgMu.Lock()
guards := (*a.cfg).ReviewGuards(botLogin)
a.cfgMu.Unlock()

out := make([]scheduler.Tier2PR, 0, len(prs))
for _, pr := range prs {
    if pr.Repo == "" {
        slog.Warn("adapter: skipping PR with empty repo", "pr_number", pr.Number)
        continue
    }
    reason := pipeline.Evaluate(pipeline.PRGate{
        State:  pr.State,
        Draft:  pr.Draft,
        Author: pr.User.Login,
    }, guards)
    if reason != pipeline.SkipReasonNone {
        a.broker.Publish(sse.Event{
            Type: sse.EventReviewSkipped,
            Data: sseData(map[string]any{
                "repo":      pr.Repo,
                "pr_number": pr.Number,
                "pr_title":  pr.Title,
                "reason":    string(reason),
            }),
        })
        slog.Info("tier2: skipping PR",
            "repo", pr.Repo, "pr", pr.Number, "reason", string(reason))
        continue
    }
    out = append(out, scheduler.Tier2PR{
        ID:        pr.ID,
        Number:    pr.Number,
        Repo:      pr.Repo,
        Title:     pr.Title,
        HTMLURL:   pr.HTMLURL,
        Author:    pr.User.Login,
        State:     pr.State,
        Draft:     pr.Draft,
        UpdatedAt: pr.UpdatedAt,
    })
}

return out, nil
```

Add the import if not already present:

```go
"github.com/heimdallm/daemon/internal/pipeline"
```

- [ ] **Step 2: Build**

Run: `cd daemon && go build ./...`
Expected: no output.

- [ ] **Step 3: Run existing tier2/main tests**

Run: `cd daemon && go test ./... -count=1`
Expected: PASS (adapter isn't unit tested directly; this change is exercised by Task 12's smoke test).

- [ ] **Step 4: Commit**

```bash
git add daemon/cmd/heimdallm/main.go
git commit -m "feat(daemon): filter PRs at Tier 2 via review guards"
```

---

## Task 9: GitHub client — `GetPRSnapshot`

Tier 3 needs state + draft + author in one call. `GetIssue` works for state/author but not draft; `GetPRHeadSHA` already hits the Pulls API. Add a small helper that returns the snapshot data the guards need.

**Files:**
- Modify: `daemon/internal/github/client.go`
- Modify: `daemon/internal/github/client_test.go` (or appropriate test file)

- [ ] **Step 1: Write the failing test**

Append to `daemon/internal/github/client_test.go`:

```go
func TestGetPRSnapshot(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/repos/org/repo/pulls/7" {
			t.Errorf("path = %q", r.URL.Path)
		}
		_, _ = w.Write([]byte(`{
			"state":"open",
			"draft":true,
			"user":{"login":"alice"},
			"updated_at":"2026-04-22T10:00:00Z",
			"head":{"sha":"deadbeef"}
		}`))
	}))
	defer srv.Close()

	c := github.NewClient(srv.URL, "token", nil)
	snap, err := c.GetPRSnapshot("org/repo", 7)
	if err != nil {
		t.Fatalf("GetPRSnapshot: %v", err)
	}
	if snap.State != "open" || !snap.Draft || snap.Author != "alice" || snap.HeadSHA != "deadbeef" {
		t.Errorf("snapshot = %+v", snap)
	}
}
```

(If the existing test file uses a different test server helper, match that pattern. The canonical `NewClient` signature is already used by other tests in this file.)

- [ ] **Step 2: Run to verify it fails**

Run: `cd daemon && go test ./internal/github/ -run TestGetPRSnapshot -v`
Expected: FAIL — `GetPRSnapshot` undefined.

- [ ] **Step 3: Implement `GetPRSnapshot`**

Edit `daemon/internal/github/client.go`. Add below `GetPRHeadSHA`:

```go
// PRSnapshot is the subset of PR fields Tier 3's guard evaluator needs.
// Returned by GetPRSnapshot in one call so the watch tier doesn't have to
// combine GetIssue + GetPRHeadSHA.
type PRSnapshot struct {
	State     string
	Draft     bool
	Author    string
	UpdatedAt time.Time
	HeadSHA   string
}

// GetPRSnapshot returns the current state, draft flag, author, updated_at,
// and HEAD SHA of a PR via the Pulls API. Tier 3 uses this to refresh state
// before re-reviewing a watched PR so a merged/closed PR does not burn AI
// tokens on a stale open-PR record.
func (c *Client) GetPRSnapshot(repo string, number int) (*PRSnapshot, error) {
	path := fmt.Sprintf("/repos/%s/pulls/%d", repo, number)
	resp, err := c.do("GET", path, "application/vnd.github+json")
	if err != nil {
		return nil, fmt.Errorf("github: get PR snapshot: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, maxBodyBytes))
	if resp.StatusCode != http.StatusOK {
		errBody := safeTruncate(string(body), maxErrBodyLen)
		return nil, fmt.Errorf("github: get PR snapshot (%s #%d): status %d: %s", repo, number, resp.StatusCode, errBody)
	}
	var pr PullRequest
	if err := json.Unmarshal(body, &pr); err != nil {
		return nil, fmt.Errorf("github: get PR snapshot: unmarshal: %w", err)
	}
	return &PRSnapshot{
		State:     pr.State,
		Draft:     pr.Draft,
		Author:    pr.User.Login,
		UpdatedAt: pr.UpdatedAt,
		HeadSHA:   pr.Head.SHA,
	}, nil
}
```

- [ ] **Step 4: Run tests**

Run: `cd daemon && go test ./internal/github/ -v`
Expected: PASS including TestGetPRSnapshot.

- [ ] **Step 5: Commit**

```bash
git add daemon/internal/github/client.go daemon/internal/github/client_test.go
git commit -m "feat(github): GetPRSnapshot returns state/draft/author in one call"
```

---

## Task 10: `ItemSnapshot` + new Tier 3 signatures

**Files:**
- Modify: `daemon/internal/scheduler/tier3.go`
- Modify: `daemon/internal/scheduler/tier2.go` (the interface lives here next to the other tier types)
- Modify: `daemon/internal/scheduler/tier3_test.go`
- Modify: `daemon/cmd/heimdallm/main.go` (adapter's CheckItem/HandleChange)

- [ ] **Step 1: Update the interface**

Edit `daemon/internal/scheduler/tier3.go`. Replace the interface and `RunTier3` body:

```go
// ItemSnapshot is the freshly-fetched subset of a watched item's state that
// HandleChange needs to decide whether to run the review. Tier 3 returns it
// from CheckItem so HandleChange does not re-fetch from GitHub.
//
// Fields are optional — only those relevant to the item's type are populated
// (e.g. Draft is always false for issues). A nil snapshot signals "no change
// detected" and is ignored by HandleChange.
type ItemSnapshot struct {
	State     string
	Draft     bool
	Author    string
	UpdatedAt time.Time
}

// Tier3ItemChecker checks a single item for state changes.
type Tier3ItemChecker interface {
	// CheckItem returns whether the item changed since LastSeen and, when
	// changed, a fresh snapshot of the item's state. An unchanged item
	// returns (false, nil, nil).
	CheckItem(ctx context.Context, item *WatchItem) (changed bool, snap *ItemSnapshot, err error)
	// HandleChange processes a detected change. snap is the snapshot returned
	// by CheckItem on the same tick; callers can rely on it being non-nil
	// because RunTier3 only invokes HandleChange when changed == true.
	HandleChange(ctx context.Context, item *WatchItem, snap *ItemSnapshot) error
}
```

Replace the inner loop in `RunTier3`:

```go
changed, snap, err := deps.Checker.CheckItem(ctx, item)
if err != nil {
    slog.Warn("tier3: check failed", "type", item.Type,
        "repo", item.Repo, "number", item.Number, "err", err)
    deps.Queue.ReEnqueue(item)
    continue
}

if changed {
    slog.Info("tier3: change detected",
        "type", item.Type, "repo", item.Repo, "number", item.Number)
    if err := deps.Checker.HandleChange(ctx, item, snap); err != nil {
        slog.Error("tier3: handle change", "err", err)
    }
    deps.Queue.ResetBackoff(item)
} else {
    deps.Queue.ReEnqueue(item)
}
```

- [ ] **Step 2: Update the adapter in main.go**

Edit `daemon/cmd/heimdallm/main.go`. Replace `tier2Adapter.CheckItem` and `tier2Adapter.HandleChange` (around lines 1260–1316):

```go
// CheckItem implements scheduler.Tier3ItemChecker.
func (a *tier2Adapter) CheckItem(ctx context.Context, item *scheduler.WatchItem) (bool, *scheduler.ItemSnapshot, error) {
	if item.Type == "pr" {
		snap, err := a.ghClient.GetPRSnapshot(item.Repo, item.Number)
		if err != nil {
			return false, nil, err
		}
		if !snap.UpdatedAt.After(item.LastSeen) {
			return false, nil, nil
		}
		return true, &scheduler.ItemSnapshot{
			State:     snap.State,
			Draft:     snap.Draft,
			Author:    snap.Author,
			UpdatedAt: snap.UpdatedAt,
		}, nil
	}
	// Issues still use the Issues API; draft is always false.
	issue, err := a.ghClient.GetIssue(item.Repo, item.Number)
	if err != nil {
		return false, nil, err
	}
	if !issue.UpdatedAt.After(item.LastSeen) {
		return false, nil, nil
	}
	return true, &scheduler.ItemSnapshot{
		State:     issue.State,
		Author:    issue.User.Login,
		UpdatedAt: issue.UpdatedAt,
	}, nil
}

// HandleChange implements scheduler.Tier3ItemChecker.
func (a *tier2Adapter) HandleChange(ctx context.Context, item *scheduler.WatchItem, snap *scheduler.ItemSnapshot) error {
	if item.Type == "pr" {
		if snap == nil {
			return nil
		}

		// Guard: apply review guards against the FRESH state from snap, not
		// the stale store copy. This closes the closed/merged-PR hole —
		// Tier 3 previously reviewed PRs that had merged between cycles.
		a.loginMu.Lock()
		botLogin := *a.login
		a.loginMu.Unlock()

		a.cfgMu.Lock()
		guards := (*a.cfg).ReviewGuards(botLogin)
		c := *a.cfg
		aiCfg := c.AIForRepo(item.Repo)
		a.cfgMu.Unlock()

		stored, _ := a.store.GetPRByGithubID(item.GithubID)
		title := ""
		if stored != nil {
			title = stored.Title
		}

		reason := pipeline.Evaluate(pipeline.PRGate{
			State:  snap.State,
			Draft:  snap.Draft,
			Author: snap.Author,
		}, guards)
		if reason != pipeline.SkipReasonNone {
			a.broker.Publish(sse.Event{
				Type: sse.EventReviewSkipped,
				Data: sseData(map[string]any{
					"repo":      item.Repo,
					"pr_number": item.Number,
					"pr_title":  title,
					"reason":    string(reason),
				}),
			})
			slog.Info("tier3: skipping PR",
				"repo", item.Repo, "pr", item.Number, "reason", string(reason))
			return nil
		}

		// Mirror the existing Tier 2 updated_at dedup.
		if a.PRAlreadyReviewed(item.GithubID, item.LastSeen) {
			slog.Debug("tier3: PR already reviewed, skipping", "pr", item.Number, "repo", item.Repo)
			return nil
		}

		ghPR := &gh.PullRequest{
			ID:        item.GithubID,
			Number:    item.Number,
			Repo:      item.Repo,
			State:     snap.State,
			Draft:     snap.Draft,
			UpdatedAt: snap.UpdatedAt,
		}
		if stored != nil {
			ghPR.Title = stored.Title
			ghPR.HTMLURL = stored.URL
			ghPR.User = gh.User{Login: snap.Author}
		}
		a.runReview(ghPR, aiCfg)
		return nil
	}
	if item.Type == "issue" {
		slog.Info("tier3: issue change detected, backoff will reset",
			"repo", item.Repo, "number", item.Number)
	}
	return nil
}
```

- [ ] **Step 3: Update the existing Tier 3 test**

Edit `daemon/internal/scheduler/tier3_test.go`. Any fake that implements `Tier3ItemChecker` needs updated method signatures. Replace its methods with:

```go
func (f *fakeChecker) CheckItem(ctx context.Context, item *scheduler.WatchItem) (bool, *scheduler.ItemSnapshot, error) {
	f.checked = append(f.checked, item.Number)
	// existing fake return values …
	return f.changed, f.snap, f.err
}

func (f *fakeChecker) HandleChange(ctx context.Context, item *scheduler.WatchItem, snap *scheduler.ItemSnapshot) error {
	f.handled = append(f.handled, item.Number)
	f.handledSnap = snap
	return nil
}
```

Add a new test asserting the snapshot is threaded through:

```go
func TestRunTier3_PassesSnapshotToHandleChange(t *testing.T) {
	q := scheduler.NewWatchQueue()
	q.Push(&scheduler.WatchItem{Type: "pr", Repo: "org/r", Number: 1, GithubID: 1})

	snap := &scheduler.ItemSnapshot{State: "open", Draft: true, Author: "alice"}
	checker := &fakeChecker{changed: true, snap: snap}

	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	deps := scheduler.Tier3Deps{
		Limiter: scheduler.NewRateLimiter(100),
		Queue:   q,
		Checker: checker,
		Interval: 10 * time.Millisecond,
	}
	go scheduler.RunTier3(ctx, deps)
	time.Sleep(150 * time.Millisecond)
	if checker.handledSnap == nil || checker.handledSnap.Author != "alice" {
		t.Errorf("snap not threaded: got %+v", checker.handledSnap)
	}
}
```

(Adjust `fakeChecker` struct to add `snap *scheduler.ItemSnapshot` and `handledSnap *scheduler.ItemSnapshot` fields if not present.)

- [ ] **Step 4: Run scheduler tests**

Run: `cd daemon && go test ./internal/scheduler/ -v`
Expected: PASS including the new test.

- [ ] **Step 5: Build the whole daemon**

Run: `cd daemon && go build ./...`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add daemon/internal/scheduler/tier2.go daemon/internal/scheduler/tier3.go daemon/internal/scheduler/tier3_test.go daemon/cmd/heimdallm/main.go
git commit -m "feat(scheduler): Tier 3 refreshes PR state and applies review guards"
```

---

## Task 11: Plumb `Guards` into `pipeline.RunOptions` from `buildRunOpts`

**Files:**
- Modify: `daemon/cmd/heimdallm/main.go`

- [ ] **Step 1: Populate Guards in buildRunOpts**

Edit `buildRunOpts` (around line 200). At the bottom of the function, update the returned struct:

```go
// Resolve bot login for self-author check; falls back to empty (disables the check).
loginMu.Lock()
botLogin := cachedLogin
loginMu.Unlock()

return pipeline.RunOptions{
    Primary:        aiCfg.Primary,
    Fallback:       aiCfg.Fallback,
    PromptOverride: aiCfg.Prompt,
    AgentPromptID:  agentCfg.PromptID,
    ReviewMode:     aiCfg.ReviewMode,
    ExecOpts:       execOpts, // existing
    Guards:         cfg.ReviewGuards(botLogin),
}
```

(Match the existing local variable names in `buildRunOpts` — `cfgMu` is already locked for reading `agentCfg`, so `cfg.ReviewGuards(botLogin)` goes inside that critical section.)

- [ ] **Step 2: Build**

Run: `cd daemon && go build ./...`
Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add daemon/cmd/heimdallm/main.go
git commit -m "feat(daemon): pass review guards into pipeline.RunOptions"
```

---

## Task 12: Integration smoke — closed PR at Tier 3 burns no tokens

**Files:**
- Modify: `daemon/integration_test.go`

- [ ] **Step 1: Write the test**

Append to `daemon/integration_test.go`:

```go
// TestTier3_ClosedPR_DoesNotInvokeCLI simulates Tier 2 reviewing an open PR,
// the PR being closed/merged between ticks, and Tier 3 detecting a change.
// The guards must refuse to run the CLI; an activity row must record the skip.
func TestTier3_ClosedPR_DoesNotInvokeCLI(t *testing.T) {
	// Use the harness helpers that already build a daemon with fake GH + fake exec.
	// (If the existing integration file uses a different style, mirror that.)
	h := newIntegrationHarness(t)
	defer h.Close()

	// Seed Tier 2 with one open, non-draft PR by pushing a fake search response.
	h.fakeGH.pushPR(fakePR{
		ID: 1, Number: 1, Repo: "org/r", State: "open", Draft: false,
		Author: "alice", Head: "sha-1", UpdatedAt: time.Now(),
	})
	h.tick() // Tier 2 reviews once
	if h.exec.calls != 1 {
		t.Fatalf("expected 1 CLI call after first tick, got %d", h.exec.calls)
	}

	// Simulate PR close (state flip + updated_at bump).
	h.fakeGH.setPRState(1, "closed", time.Now().Add(1*time.Minute))

	// Tier 3 ticks — must not invoke CLI.
	h.tickTier3()
	if h.exec.calls != 1 {
		t.Errorf("CLI invoked on closed PR at Tier 3: calls=%d", h.exec.calls)
	}

	// Activity row recorded with outcome=not_open.
	rows := h.store.RecentActivity(10)
	found := false
	for _, row := range rows {
		if row.Action == "review_skipped" && row.Outcome == "not_open" {
			found = true
			break
		}
	}
	if !found {
		t.Errorf("expected activity row review_skipped/not_open, got %+v", rows)
	}
}
```

**Before starting, inspect `daemon/integration_test.go` to see what harness helpers already exist.** If there is no `newIntegrationHarness` helper, the simplest path is to extend whatever style the existing integration test uses (a concrete example lives one file up). Do not invent new infrastructure — reuse existing fakes (`fakeExec`, `fakeGHCounter`, `activity.NewWithChannel`) even if the wiring is slightly verbose.

- [ ] **Step 2: Run the test**

Run: `cd daemon && go test -run TestTier3_ClosedPR_DoesNotInvokeCLI -v ./...`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add daemon/integration_test.go
git commit -m "test(integration): closed PR at Tier 3 skips review"
```

---

## Task 13: Full test sweep + verify-linux

**Files:** none.

- [ ] **Step 1: Run the full Go test suite**

Run: `cd daemon && go test ./... -count=1`
Expected: all green.

- [ ] **Step 2: Run verify-linux**

Per project memory, if this work is in a worktree, run verify-linux from the worktree directory, not from main. If it's not in a worktree, run from the repo root:

```bash
make verify-linux
```

Expected: PASS.

- [ ] **Step 3: Manual spot check on a running daemon (post-merge)**

After merging, tail the daemon log and confirm at least one of these lines fires in the first hour:

- `tier2: skipping PR  reason=draft` (draft PR in the user's review-requested queue)
- `pipeline: skipping re-review, HEAD SHA unchanged` (yesterday's fix firing)
- `tier3: skipping PR  reason=not_open` (a PR that merged between ticks)

No code change on this step — it is verification only.

---

## Self-review

**Spec coverage:**

- G1 (refresh state in Tier 3) → Task 10.
- G2 (defense-in-depth state assert in pipeline.Run) → Task 5.
- G3 (verify yesterday's HEAD-SHA fix via Tier 3 path) → Task 6.
- G4 (skip drafts, default on) → Tasks 2, 3, 7, 8.
- G5 (skip self-authored, default on) → Tasks 2, 3, 8, 10.
- SSE `review_skipped` event + activity log row → Task 4.
- Config surface (`[github.review_guards]`, defaults) → Task 3.
- All unit + integration tests called out in the spec have a home.

**Placeholder scan:** no TBD/TODO; every step with code has complete code; commit messages are concrete.

**Type consistency:**

- `pipeline.PRGate` / `GateConfig` / `SkipReason` / `Evaluate` — used identically across tasks 2, 5, 8, 10.
- `scheduler.ItemSnapshot` fields (`State`, `Draft`, `Author`, `UpdatedAt`) — used identically in tasks 10, 12.
- `github.PRSnapshot` vs `scheduler.ItemSnapshot` — deliberately separate types. `PRSnapshot` is the GitHub-layer value (includes `HeadSHA`); `ItemSnapshot` is the scheduler-layer value (drops HeadSHA, adds nothing). Adapter in Task 10 converts between them explicitly.
- `ReviewGuards` helper signature: `(c *Config) ReviewGuards(botLogin string) pipeline.GateConfig` — called with the same argument list in Tasks 8, 10, 11.
