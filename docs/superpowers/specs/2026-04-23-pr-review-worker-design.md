# PR Review Worker (NATS Consumer) Design

**Issue:** #298 (epic), #304 (Task 5)  
**Date:** 2026-04-23  
**Scope:** First NATS consumer — subscribes to heimdallm.pr.review, calls existing review pipeline  

## Overview

The PR review worker is a pull-based NATS consumer that reads from the `review-worker` durable consumer on `HEIMDALLM_WORK`. For each message, it fetches the full PR from GitHub, calls the existing `runReview` logic, and pushes to WatchQueue for Tier 3. Messages are always acked (errors are logged, not retried — the pipeline already has circuit breakers and SHA dedup).

## Architecture

```
NATS (heimdallm.pr.review) → ReviewWorker → handler closure → runReview → pipeline.Run
                                                              → WatchQueue.Push
```

### ReviewWorker (daemon/internal/worker/review.go)

```go
type ReviewWorker struct {
    js      jetstream.JetStream
    handler func(ctx context.Context, msg bus.PRReviewMsg)
}

func NewReviewWorker(js jetstream.JetStream, handler func(context.Context, bus.PRReviewMsg)) *ReviewWorker
func (w *ReviewWorker) Start(ctx context.Context) error
```

`Start` gets the `review-worker` consumer, calls `cons.Messages()`, iterates:
1. Deserialize `PRReviewMsg`
2. Call `handler(ctx, msg)`
3. Ack (always — handler logs errors internally)
4. On context cancel, stop iterator and return

### Handler closure (main.go)

```go
reviewHandler := func(ctx context.Context, msg bus.PRReviewMsg) {
    // 1. Fetch full PR from GitHub via GetPR
    // 2. Verify HeadSHA matches (stale message guard)
    // 3. Resolve aiCfg for repo
    // 4. Call existing runReview(pr, aiCfg)
    // 5. WatchQueue.Push (maintain Tier 3)
}
```

The handler reuses `runReview` exactly as-is — all claims, guards, SSE events, pipeline.Run logic stays intact.

### GetPR (github/client.go)

New method on `Client`:

```go
func (c *Client) GetPR(repo string, number int) (*PullRequest, error)
```

Same API call as `GetPRSnapshot` (`GET /repos/{repo}/pulls/{number}`) but returns the full `*PullRequest` instead of a reduced snapshot. Sets `pr.Repo` from `Head.Repo.FullName` (same pattern as `FetchPRs`).

## Design Decisions

### Always Ack
Messages are always acked even on handler error. Rationale:
- `MaxDeliver=3` with `AckWait=30m` means a failed message re-delivers after 30 min — too late to be useful
- The pipeline has layered defenses: circuit breaker (3/PR/24h), SHA dedup (fail-closed), PublishedAt grace
- Nak/retry would just hit the same defenses again
- Errors are logged for operator visibility

### No pr.publish or NATS events yet
The epic spec says the worker should publish `pr.publish` + `events.review_completed`. These are deferred:
- `pr.publish` has no consumer until Task 6
- NATS events have no consumer until Task 10 (SSE bridge)
- The SSE broker still handles UI events
- Tasks 6 and 10 will add these publishes when they create the consumers

### HeadSHA stale guard
Between publish (Tier 2 poll) and consume (worker), the PR's HEAD may have changed. The handler fetches the fresh PR and compares `pr.Head.SHA` with `msg.HeadSHA`. If they differ, the message is stale — log and skip (a new message for the updated SHA will arrive from the next poll cycle).

## Files Changed

| Action | File | What |
|--------|------|------|
| Create | `daemon/internal/worker/review.go` | ReviewWorker struct with NATS consumer loop |
| Create | `daemon/internal/worker/review_test.go` | Test with embedded NATS + mock handler |
| Modify | `daemon/internal/github/client.go` | Add GetPR method |
| Modify | `daemon/cmd/heimdallm/main.go` | Create handler closure, start ReviewWorker |

## Testing

1. **ReviewWorker test** — embedded NATS, publish PRReviewMsg, mock handler verifies it's called with correct data, consumer acks message
2. **Smoke test** — binary starts, PR published to NATS by Tier 2, worker consumes and triggers review

## Out of Scope

- Publishing to `heimdallm.pr.publish` (Task 6)
- Publishing to NATS events (Task 10)
- Removing `PRProcessor.ProcessPR` from Tier2Deps (still used for `PublishPending`)
- Replacing WatchQueue (Task 9)
