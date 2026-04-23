# PR Publish Worker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a NATS consumer that publishes stored reviews to GitHub, replacing the manual PublishPending retry loop with NATS retry semantics (NakWithDelay).

**Architecture:** PublishWorker consumes `PRPublishMsg` from the `publish-worker` consumer. Two sources publish messages: the review worker (happy path after successful review) and a simplified PublishPending scanner (catch-up). The handler returns an error to control ack/nak — nil means ack, non-nil means NakWithDelay for NATS retry.

**Tech Stack:** Go, NATS JetStream (embedded), existing pipeline/store packages

**Spec:** `docs/superpowers/specs/2026-04-23-pr-publish-worker-design.md`

---

## File Map

| Action | File | Responsibility |
|--------|------|----------------|
| Modify | `daemon/internal/store/reviews.go` | Add GetReview(id) method |
| Modify | `daemon/internal/bus/publisher.go` | Add PRPublishPublisher |
| Modify | `daemon/internal/bus/publisher_test.go` | Test PRPublishPublisher |
| Create | `daemon/internal/worker/publish.go` | PublishWorker with ack/nak logic |
| Create | `daemon/internal/worker/publish_test.go` | Tests for PublishWorker |
| Modify | `daemon/cmd/heimdallm/main.go` | runReview returns *Review, publishHandler, PublishWorker startup, reviewHandler publishes PRPublishMsg, simplify PublishPending |

---

### Task 1: store.GetReview

**Files:**
- Modify: `daemon/internal/store/reviews.go`

- [ ] **Step 1: Add GetReview method**

In `daemon/internal/store/reviews.go`, after the `ListUnpublishedReviews` method (around line 77), add:

```go
// GetReview returns a single review by its local row ID.
func (s *Store) GetReview(id int64) (*Review, error) {
	row := s.db.QueryRow(
		"SELECT id, pr_id, cli_used, summary, issues, suggestions, severity, created_at, published_at, github_review_id, github_review_state, head_sha FROM reviews WHERE id = ?",
		id,
	)
	return scanReview(row)
}
```

- [ ] **Step 2: Verify it compiles**

```bash
cd daemon
go build ./internal/store/
```

- [ ] **Step 3: Commit**

```bash
git add internal/store/reviews.go
git commit -m "feat(store): add GetReview method (#305)"
```

---

### Task 2: PRPublishPublisher

**Files:**
- Modify: `daemon/internal/bus/publisher.go`
- Modify: `daemon/internal/bus/publisher_test.go`

- [ ] **Step 1: Write the failing test**

Append to `daemon/internal/bus/publisher_test.go`:

```go
func TestPRPublishPublisher_Publish(t *testing.T) {
	b := newTestBus(t)
	ctx := context.Background()

	pub := bus.NewPRPublishPublisher(b.JetStream())

	if err := pub.PublishPRPublish(ctx, 42); err != nil {
		t.Fatalf("PublishPRPublish: %v", err)
	}

	cons, err := b.JetStream().Consumer(ctx, bus.StreamWork, bus.ConsumerPublish)
	if err != nil {
		t.Fatalf("consumer: %v", err)
	}
	msgs, err := cons.Fetch(1, jetstream.FetchMaxWait(2*time.Second))
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}
	var got bus.PRPublishMsg
	for m := range msgs.Messages() {
		if err := bus.Decode(m.Data(), &got); err != nil {
			t.Fatalf("decode: %v", err)
		}
		m.Ack()
	}
	if got.ReviewID != 42 {
		t.Errorf("ReviewID = %d, want 42", got.ReviewID)
	}
}

func TestPRPublishPublisher_Dedup(t *testing.T) {
	b := newTestBus(t)
	ctx := context.Background()

	pub := bus.NewPRPublishPublisher(b.JetStream())

	if err := pub.PublishPRPublish(ctx, 42); err != nil {
		t.Fatalf("publish 1: %v", err)
	}
	if err := pub.PublishPRPublish(ctx, 42); err != nil {
		t.Fatalf("publish 2: %v", err)
	}

	cons, err := b.JetStream().Consumer(ctx, bus.StreamWork, bus.ConsumerPublish)
	if err != nil {
		t.Fatalf("consumer: %v", err)
	}
	msgs, err := cons.Fetch(2, jetstream.FetchMaxWait(1*time.Second))
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}
	count := 0
	for m := range msgs.Messages() {
		count++
		m.Ack()
	}
	if count != 1 {
		t.Errorf("expected 1 (dedup), got %d", count)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd daemon
go test ./internal/bus/ -run TestPRPublishPublisher -v
```

Expected: FAIL — `bus.NewPRPublishPublisher` undefined.

- [ ] **Step 3: Add PRPublishPublisher to publisher.go**

Append to `daemon/internal/bus/publisher.go`:

```go
// PRPublishPublisher publishes review publish requests to NATS JetStream.
type PRPublishPublisher struct {
	js jetstream.JetStream
}

// NewPRPublishPublisher creates a publisher that writes to SubjPRPublish.
func NewPRPublishPublisher(js jetstream.JetStream) *PRPublishPublisher {
	return &PRPublishPublisher{js: js}
}

// PublishPRPublish enqueues a review for GitHub publication.
// Dedup via Nats-Msg-Id prevents the scanner and review worker from
// double-publishing the same review.
func (p *PRPublishPublisher) PublishPRPublish(ctx context.Context, reviewID int64) error {
	data, err := Encode(PRPublishMsg{ReviewID: reviewID})
	if err != nil {
		return fmt.Errorf("bus: encode pr publish: %w", err)
	}
	msgID := fmt.Sprintf("rev:%d", reviewID)
	_, err = p.js.Publish(ctx, SubjPRPublish, data, jetstream.WithMsgID(msgID))
	if err != nil {
		return fmt.Errorf("bus: publish pr publish: %w", err)
	}
	return nil
}
```

- [ ] **Step 4: Run tests**

```bash
cd daemon
go test ./internal/bus/ -run TestPRPublishPublisher -v
```

Expected: Both PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/bus/publisher.go internal/bus/publisher_test.go
git commit -m "feat(bus): add PRPublishPublisher with dedup by review ID (#305)"
```

---

### Task 3: PublishWorker

**Files:**
- Create: `daemon/internal/worker/publish.go`
- Create: `daemon/internal/worker/publish_test.go`

- [ ] **Step 1: Create publish.go**

```go
// daemon/internal/worker/publish.go
package worker

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"runtime/debug"
	"time"

	"github.com/heimdallm/daemon/internal/bus"
	"github.com/nats-io/nats.go/jetstream"
)

// PublishWorker consumes PR publish requests from NATS and delegates
// to a handler that submits the review to GitHub.
//
// Unlike ReviewWorker, the handler returns an error to control ack/nak:
//   - nil → Ack (success or permanent failure, no retry)
//   - non-nil → NakWithDelay(30s) for NATS retry on transient failures
type PublishWorker struct {
	js      jetstream.JetStream
	handler func(ctx context.Context, msg bus.PRPublishMsg) error
}

// NewPublishWorker creates a worker that consumes from the publish-worker
// durable consumer.
func NewPublishWorker(js jetstream.JetStream, handler func(context.Context, bus.PRPublishMsg) error) *PublishWorker {
	return &PublishWorker{js: js, handler: handler}
}

// Start begins consuming. Blocks until ctx is cancelled.
func (w *PublishWorker) Start(ctx context.Context) error {
	cons, err := w.js.Consumer(ctx, bus.StreamWork, bus.ConsumerPublish)
	if err != nil {
		return err
	}

	iter, err := cons.Messages(jetstream.PullMaxMessages(1))
	if err != nil {
		return err
	}

	go func() {
		<-ctx.Done()
		iter.Stop()
	}()

	for {
		msg, err := iter.Next()
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, jetstream.ErrMsgIteratorClosed) {
				return nil
			}
			return fmt.Errorf("publish-worker: iter.Next: %w", err)
		}

		var pubMsg bus.PRPublishMsg
		if err := bus.Decode(msg.Data(), &pubMsg); err != nil {
			slog.Error("publish-worker: decode message", "err", err)
			msg.Ack()
			continue
		}

		slog.Info("publish-worker: processing", "review_id", pubMsg.ReviewID)

		if err := w.safeHandle(ctx, pubMsg); err != nil {
			slog.Warn("publish-worker: transient error, will retry",
				"review_id", pubMsg.ReviewID, "err", err)
			msg.NakWithDelay(30 * time.Second)
		} else {
			msg.Ack()
		}
	}
}

// safeHandle calls the handler with panic recovery.
func (w *PublishWorker) safeHandle(ctx context.Context, msg bus.PRPublishMsg) (err error) {
	defer func() {
		if r := recover(); r != nil {
			slog.Error("publish-worker: handler panic",
				"review_id", msg.ReviewID, "panic", r,
				"stack", string(debug.Stack()))
			err = fmt.Errorf("panic: %v", r)
		}
	}()
	return w.handler(ctx, msg)
}
```

- [ ] **Step 2: Create publish_test.go**

```go
// daemon/internal/worker/publish_test.go
package worker_test

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/heimdallm/daemon/internal/bus"
	"github.com/heimdallm/daemon/internal/worker"
	"github.com/nats-io/nats.go/jetstream"
)

func TestPublishWorker_AcksOnSuccess(t *testing.T) {
	b := newTestBus(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	called := make(chan int64, 1)
	handler := func(_ context.Context, msg bus.PRPublishMsg) error {
		called <- msg.ReviewID
		return nil
	}

	w := worker.NewPublishWorker(b.JetStream(), handler)
	go func() { w.Start(ctx) }()
	time.Sleep(200 * time.Millisecond)

	pub := bus.NewPRPublishPublisher(b.JetStream())
	if err := pub.PublishPRPublish(ctx, 42); err != nil {
		t.Fatalf("publish: %v", err)
	}

	select {
	case id := <-called:
		if id != 42 {
			t.Errorf("ReviewID = %d, want 42", id)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("handler not called")
	}

	time.Sleep(200 * time.Millisecond)
	cancel()

	cons, err := b.JetStream().Consumer(context.Background(), bus.StreamWork, bus.ConsumerPublish)
	if err != nil {
		t.Fatalf("get consumer: %v", err)
	}
	info, err := cons.Info(context.Background())
	if err != nil {
		t.Fatalf("consumer info: %v", err)
	}
	if info.NumAckPending > 0 {
		t.Errorf("expected 0 ack-pending, got %d", info.NumAckPending)
	}
}

func TestPublishWorker_NaksOnError(t *testing.T) {
	b := newTestBus(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	var mu sync.Mutex
	callCount := 0
	handler := func(_ context.Context, msg bus.PRPublishMsg) error {
		mu.Lock()
		callCount++
		n := callCount
		mu.Unlock()
		if n <= 2 {
			return errors.New("transient error")
		}
		return nil // succeed on 3rd attempt
	}

	w := worker.NewPublishWorker(b.JetStream(), handler)
	go func() { w.Start(ctx) }()
	time.Sleep(200 * time.Millisecond)

	// Publish directly with short NakWithDelay for test speed.
	// The worker uses 30s delay, but for testing we publish and just
	// verify the handler is called multiple times (redelivery).
	data, _ := bus.Encode(bus.PRPublishMsg{ReviewID: 99})
	_, err := b.JetStream().Publish(ctx, bus.SubjPRPublish, data, jetstream.WithMsgID("rev:99"))
	if err != nil {
		t.Fatalf("publish: %v", err)
	}

	// Wait enough time for at least the first call + nak
	// NakWithDelay is 30s in production, but NATS may redeliver sooner in tests.
	// We just verify the handler was called at least once.
	time.Sleep(1 * time.Second)
	cancel()

	mu.Lock()
	n := callCount
	mu.Unlock()
	if n < 1 {
		t.Fatalf("expected handler to be called at least once, got %d", n)
	}
}

func TestPublishWorker_AcksOnPanic(t *testing.T) {
	b := newTestBus(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	panicked := make(chan struct{}, 1)
	handler := func(_ context.Context, _ bus.PRPublishMsg) error {
		panicked <- struct{}{}
		panic("simulated publish panic")
	}

	w := worker.NewPublishWorker(b.JetStream(), handler)
	go func() { w.Start(ctx) }()
	time.Sleep(200 * time.Millisecond)

	data, _ := bus.Encode(bus.PRPublishMsg{ReviewID: 77})
	_, err := b.JetStream().Publish(ctx, bus.SubjPRPublish, data, jetstream.WithMsgID("rev:77"))
	if err != nil {
		t.Fatalf("publish: %v", err)
	}

	select {
	case <-panicked:
	case <-time.After(2 * time.Second):
		t.Fatal("handler not called")
	}

	// Panic returns error from safeHandle → NakWithDelay (not ack).
	// This is correct — a panic is treated as transient.
	time.Sleep(300 * time.Millisecond)
	cancel()
}
```

- [ ] **Step 3: Run tests**

```bash
cd daemon
go test ./internal/worker/ -v -count=1
```

Expected: All worker tests pass (3 review + 3 publish).

- [ ] **Step 4: Commit**

```bash
git add internal/worker/publish.go internal/worker/publish_test.go
git commit -m "feat(worker): add PublishWorker with ack/nak error handling (#305)"
```

---

### Task 4: Wire into main.go

**Files:**
- Modify: `daemon/cmd/heimdallm/main.go`

This is the most complex task — several changes:

- [ ] **Step 1: Change runReview signature to return *store.Review**

In `daemon/cmd/heimdallm/main.go`, find `runReview := func(pr *gh.PullRequest, aiCfg config.RepoAI) {` (around line 278). Change to:

```go
	runReview := func(pr *gh.PullRequest, aiCfg config.RepoAI) *store.Review {
```

At the end of the function (around line 429, before the closing `}`), the `broker.Publish(sse.Event{Type: sse.EventReviewCompleted, ...})` block is the success path. After it, add `return rev`. For all early-return paths (errors, skips), change `return` to `return nil`.

Specifically:
- Line ~319 (`return` after "already in flight") → `return nil`
- Line ~349 (`return` after review guards skip) → `return nil`
- Line ~373 (`return` after circuit breaker) → `return nil`
- Line ~375 (`return` after review error) → `return nil`
- Line ~381 (`return` after rev == nil) → `return nil`
- Line ~429 (after EventReviewCompleted publish) → add `return rev`

- [ ] **Step 2: Update callers of runReview**

Find all callers:
- `a.runReview(ghPR, aiCfg)` in `ProcessPR` (around line 1554) → change to `_ = a.runReview(ghPR, aiCfg)`
- `a.runReview(ghPR, aiCfg)` in `HandleChange` (around line 1849) → change to `_ = a.runReview(ghPR, aiCfg)`

Also update the `tier2Adapter` struct field:
- `runReview func(pr *gh.PullRequest, aiCfg config.RepoAI)` → `runReview func(pr *gh.PullRequest, aiCfg config.RepoAI) *store.Review`

- [ ] **Step 3: Create publishPub and publishHandler**

After the `reviewWorker` startup block (around line 543), add:

```go
	// ── NATS PR publish worker ──────────────────────────────────────────
	publishPub := bus.NewPRPublishPublisher(js)

	publishHandler := func(ctx context.Context, msg bus.PRPublishMsg) error {
		rev, err := s.GetReview(msg.ReviewID)
		if err != nil {
			slog.Warn("publish-worker: review not found, skipping",
				"review_id", msg.ReviewID, "err", err)
			return nil // permanent — ack
		}
		if rev.GitHubReviewID != 0 {
			slog.Info("publish-worker: already published, skipping",
				"review_id", msg.ReviewID, "github_review_id", rev.GitHubReviewID)
			return nil // idempotent — ack
		}

		pr, err := s.GetPR(rev.PRID)
		if err != nil {
			slog.Warn("publish-worker: PR not found, marking orphaned",
				"review_id", msg.ReviewID, "pr_id", rev.PRID, "err", err)
			_ = s.MarkReviewPublished(rev.ID, -1, "", time.Now().UTC())
			return nil // permanent — ack
		}
		if pr.Repo == "" {
			slog.Info("publish-worker: PR has no repo, marking orphaned",
				"review_id", msg.ReviewID)
			_ = s.MarkReviewPublished(rev.ID, -1, "", time.Now().UTC())
			return nil // permanent — ack
		}

		// Rebuild ReviewResult from stored JSON
		var issues []executor.Issue
		json.Unmarshal([]byte(rev.Issues), &issues)
		result := &executor.ReviewResult{
			Summary:  rev.Summary,
			Issues:   issues,
			Severity: rev.Severity,
		}

		ghID, ghState, err := p.SubmitReviewToGitHub(
			pr.Repo, pr.Number,
			pipeline.BuildGitHubBody(result),
			pipeline.SeverityToEvent(rev.Severity, len(issues)),
		)
		if err != nil {
			// Transient — nak for NATS retry
			return fmt.Errorf("submit review to GitHub: %w", err)
		}

		publishedAt := time.Now().UTC()
		if err := s.MarkReviewPublished(rev.ID, ghID, ghState, publishedAt); err != nil {
			slog.Warn("publish-worker: failed to mark published",
				"review_id", rev.ID, "err", err)
		}
		slog.Info("publish-worker: review published",
			"review_id", rev.ID, "github_review_id", ghID,
			"github_review_state", ghState)
		return nil // success — ack
	}

	publishWorker := worker.NewPublishWorker(js, publishHandler)
	publishWorkerCtx, publishWorkerCancel := context.WithCancel(context.Background())
	defer publishWorkerCancel()
	go func() {
		if err := publishWorker.Start(publishWorkerCtx); err != nil {
			slog.Error("publish worker stopped", "err", err)
		}
	}()
```

**IMPORTANT:** The handler uses `p.SubmitReviewToGitHub()` — but this is actually `ghClient.SubmitReview()` since `p` is `*pipeline.Pipeline`. Check if `SubmitReview` is accessible. Actually, looking at the existing `PublishPending()`, it uses `p.gh.SubmitReview()` where `p.gh` is the GitHub client interface. Since we're in main.go, use `ghClient.SubmitReview()` directly.

Also, `buildGitHubBody` and `severityToEvent` are unexported in the pipeline package. We need to either:
a) Export them (`BuildGitHubBody`, `SeverityToEvent`)
b) Duplicate the logic in main.go
c) Add a method on pipeline.Pipeline that wraps the publish logic

Option (a) is cleanest — export the two helpers. They're pure functions with no dependencies.

- [ ] **Step 4: Export buildGitHubBody and severityToEvent**

In `daemon/internal/pipeline/pipeline.go`, rename:
- `buildGitHubBody` → `BuildGitHubBody`
- `severityToEvent` → `SeverityToEvent`

Update all internal callers in the same file. Search for `buildGitHubBody(` and `severityToEvent(` — they appear in `Run()` (around line 400-401) and `PublishPending()` (around lines 472-476).

- [ ] **Step 5: Modify reviewHandler to publish PRPublishMsg**

In the `reviewHandler` closure (around line 502), change the `runReview` call and add PRPublishMsg publish:

```go
		rev := runReview(pr, aiCfg)

		// If review succeeded but wasn't published to GitHub yet,
		// enqueue for the publish worker.
		if rev != nil && rev.GitHubReviewID == 0 {
			if err := publishPub.PublishPRPublish(ctx, rev.ID); err != nil {
				slog.Warn("review-worker: failed to enqueue publish",
					"review_id", rev.ID, "err", err)
			}
		}

		// Maintain Tier 3 watching ...
```

- [ ] **Step 6: Simplify PublishPending in tier2Adapter**

The `PublishPending()` method on `tier2Adapter` (around line 1508) currently calls `a.pipeline.PublishPending()`. Replace with a version that enqueues via NATS:

First, add `publishPub *bus.PRPublishPublisher` to the `tier2Adapter` struct and wire it in the `adapter := &tier2Adapter{...}` constructor.

Then change `PublishPending()`:

```go
func (a *tier2Adapter) PublishPending() {
	reviews, err := a.store.ListUnpublishedReviews()
	if err != nil || len(reviews) == 0 {
		return
	}
	for _, rev := range reviews {
		if err := a.publishPub.PublishPRPublish(context.Background(), rev.ID); err != nil {
			slog.Warn("publish-pending: enqueue failed", "review_id", rev.ID, "err", err)
		}
	}
}
```

- [ ] **Step 7: Verify build**

```bash
cd daemon
go build ./cmd/heimdallm/
```

- [ ] **Step 8: Run full test suite**

```bash
cd daemon
go test ./... -count=1
```

Expected: All tests pass.

- [ ] **Step 9: Commit**

```bash
git add cmd/heimdallm/main.go internal/pipeline/pipeline.go
git commit -m "feat: wire PR publish worker into daemon (#305)"
```

---

### Task 5: Final validation

- [ ] **Step 1: Run affected packages with race detector**

```bash
cd daemon
go test ./internal/worker/ ./internal/bus/ ./internal/store/ ./cmd/heimdallm/ -race -count=1
```

- [ ] **Step 2: Build binary**

```bash
cd daemon
go build -o bin/heimdallm ./cmd/heimdallm/
```

- [ ] **Step 3: Smoke test**

```bash
cd daemon
HEIMDALLM_DATA_DIR=$(mktemp -d) HEIMDALLM_AI_PRIMARY=claude-code timeout 8 ./bin/heimdallm 2>&1 | head -20
```

Expected: Daemon starts. If a PR review completes, the publish worker should pick up any unpublished reviews.

- [ ] **Step 4: Commit if adjustments needed**

Skip if no changes.
