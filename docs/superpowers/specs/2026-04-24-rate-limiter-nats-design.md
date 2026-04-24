# Rate Limiter Integration with NATS Design

**Issue:** #298 (epic), #310 (Task 11)  
**Date:** 2026-04-24  
**Scope:** Add rate limiter to NATS workers that make GitHub API calls  

## Overview

Keep the existing token-bucket rate limiter as middleware. The pollers (Tier 1+2) already use it. Add it to the NATS worker handlers that make GitHub API calls: review worker (GetPR), publish worker (SubmitReview), and state worker (CheckItem).

NATS `MaxAckPending` controls concurrency (how many workers run simultaneously). The rate limiter controls API call rate (how many GitHub calls per hour). They complement each other.

## Changes

### 1. Expose rate limiter to workers

The `RateLimiter` is currently created inside `Pipeline.NewPipeline()`. For workers to use it, create a shared limiter in main.go and pass it to both the pipeline and the workers.

### 2. Add Acquire to worker handlers

In each worker handler closure in main.go, call `limiter.Acquire(ctx, scheduler.TierRepo)` before the GitHub API call:

- **reviewHandler**: before `ghClient.GetPR()`
- **publishHandler**: before `ghClient.SubmitReview()`
- **stateHandler**: before `adapter.CheckItem()`

Use `TierRepo` priority for all workers — they're equivalent to Tier 2 processing.

### 3. Share limiter between pipeline and workers

Create the limiter in main.go before `buildPipeline`, pass it to the pipeline config. Workers use the same instance.

## Files Changed

| Action | File | What |
|--------|------|------|
| Modify | `daemon/internal/scheduler/pipeline.go` | Accept external limiter in PipelineConfig |
| Modify | `daemon/cmd/heimdallm/main.go` | Create shared limiter, pass to pipeline + workers |

## Out of Scope

- Replacing the token bucket with NATS-native rate limiting
- Per-worker rate limit configuration
