package scheduler

import (
	"context"
	"time"
)

// Tier identifies which polling tier is requesting API access.
type Tier int

const (
	TierDiscovery Tier = iota // Tier 1: slow, lowest priority
	TierRepo                  // Tier 2: medium
	TierWatch                 // Tier 3: fast, highest priority
)

// tierWait is how long each tier will wait for a token before giving up.
var tierWait = map[Tier]time.Duration{
	TierDiscovery: 500 * time.Millisecond,
	TierRepo:      200 * time.Millisecond,
	TierWatch:     50 * time.Millisecond,
}

// RateLimiter is a shared token pool that governs GitHub API usage across
// all polling tiers. Higher-priority tiers (Watch) get shorter initial wait
// times, meaning they acquire tokens faster when the pool is under pressure.
type RateLimiter struct {
	pool chan struct{}
	size int
}

// NewRateLimiter creates a rate limiter with the given number of tokens.
func NewRateLimiter(tokens int) *RateLimiter {
	pool := make(chan struct{}, tokens)
	for i := 0; i < tokens; i++ {
		pool <- struct{}{}
	}
	return &RateLimiter{pool: pool, size: tokens}
}

// Acquire blocks until a token is available or the context is done.
func (r *RateLimiter) Acquire(ctx context.Context, tier Tier) error {
	wait := tierWait[tier]
	timer := time.NewTimer(wait)
	defer timer.Stop()

	select {
	case <-r.pool:
		return nil
	case <-timer.C:
		select {
		case <-r.pool:
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	case <-ctx.Done():
		return ctx.Err()
	}
}

// Refill restores the token pool to its original capacity.
func (r *RateLimiter) Refill() {
	for {
		select {
		case r.pool <- struct{}{}:
		default:
			return
		}
	}
}

// Available returns the number of tokens currently in the pool.
func (r *RateLimiter) Available() int {
	return len(r.pool)
}
