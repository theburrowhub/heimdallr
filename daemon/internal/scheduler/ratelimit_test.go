package scheduler

import (
	"context"
	"testing"
	"time"
)

func TestRateLimiter_AcquireWithinBudget(t *testing.T) {
	rl := NewRateLimiter(100)
	ctx := context.Background()
	for i := 0; i < 50; i++ {
		if err := rl.Acquire(ctx, TierRepo); err != nil {
			t.Fatalf("acquire %d: %v", i, err)
		}
	}
	if rl.Available() != 50 {
		t.Errorf("available = %d, want 50", rl.Available())
	}
}

func TestRateLimiter_PriorityOrdering(t *testing.T) {
	rl := NewRateLimiter(1)
	ctx := context.Background()
	// Drain the single token
	if err := rl.Acquire(ctx, TierWatch); err != nil {
		t.Fatal(err)
	}
	// T1 (low priority) should timeout
	ctx2, cancel2 := context.WithTimeout(context.Background(), 600*time.Millisecond)
	defer cancel2()
	if err := rl.Acquire(ctx2, TierDiscovery); err == nil {
		t.Error("expected timeout for low-priority tier with empty pool")
	}
}

func TestRateLimiter_ContextCancellation(t *testing.T) {
	rl := NewRateLimiter(0)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := rl.Acquire(ctx, TierWatch); err == nil {
		t.Error("expected error on cancelled context")
	}
}

func TestRateLimiter_Refill(t *testing.T) {
	rl := NewRateLimiter(10)
	ctx := context.Background()
	for i := 0; i < 10; i++ {
		rl.Acquire(ctx, TierRepo)
	}
	if rl.Available() != 0 {
		t.Errorf("should be empty, got %d", rl.Available())
	}
	rl.Refill()
	if rl.Available() != 10 {
		t.Errorf("after refill = %d, want 10", rl.Available())
	}
}
