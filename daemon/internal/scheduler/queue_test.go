package scheduler

import (
	"testing"
	"time"
)

func TestWatchQueue_PushAndPop(t *testing.T) {
	q := NewWatchQueue()
	q.Push(&WatchItem{Type: "pr", Repo: "org/a", Number: 1, GithubID: 100,
		NextCheck: time.Now().Add(-1 * time.Second)})
	q.Push(&WatchItem{Type: "issue", Repo: "org/a", Number: 2, GithubID: 200,
		NextCheck: time.Now().Add(-1 * time.Second)})
	ready := q.PopReady()
	if len(ready) != 2 {
		t.Fatalf("expected 2 ready, got %d", len(ready))
	}
	if q.Len() != 0 {
		t.Errorf("queue should be empty after pop, got %d", q.Len())
	}
}

func TestWatchQueue_NotYetReady(t *testing.T) {
	q := NewWatchQueue()
	q.Push(&WatchItem{Type: "pr", Repo: "org/a", Number: 1, GithubID: 100,
		NextCheck: time.Now().Add(1 * time.Hour)})
	ready := q.PopReady()
	if len(ready) != 0 {
		t.Errorf("expected 0 ready (future NextCheck), got %d", len(ready))
	}
	if q.Len() != 1 {
		t.Errorf("item should still be in queue")
	}
}

func TestWatchQueue_Dedup(t *testing.T) {
	q := NewWatchQueue()
	q.Push(&WatchItem{Type: "pr", GithubID: 100, NextCheck: time.Now()})
	q.Push(&WatchItem{Type: "pr", GithubID: 100, NextCheck: time.Now()})
	if q.Len() != 1 {
		t.Errorf("dedup failed, got %d items", q.Len())
	}
}

func TestWatchQueue_BackoffDoubles(t *testing.T) {
	q := NewWatchQueue()
	item := &WatchItem{Type: "pr", GithubID: 100, Backoff: 1 * time.Minute}
	q.ReEnqueue(item)
	if item.Backoff != 2*time.Minute {
		t.Errorf("backoff = %v, want 2m", item.Backoff)
	}
	q.PopReady() // drain
	q.ReEnqueue(item)
	if item.Backoff != 4*time.Minute {
		t.Errorf("backoff = %v, want 4m", item.Backoff)
	}
}

func TestWatchQueue_BackoffCapped(t *testing.T) {
	q := NewWatchQueue()
	item := &WatchItem{Type: "pr", GithubID: 100, Backoff: 10 * time.Minute}
	q.ReEnqueue(item)
	if item.Backoff != maxBackoff {
		t.Errorf("backoff = %v, want %v (cap)", item.Backoff, maxBackoff)
	}
}

func TestWatchQueue_ResetBackoff(t *testing.T) {
	q := NewWatchQueue()
	item := &WatchItem{Type: "pr", GithubID: 100, Backoff: 8 * time.Minute}
	q.ResetBackoff(item)
	if item.Backoff != initialBackoff {
		t.Errorf("backoff = %v, want %v", item.Backoff, initialBackoff)
	}
}

func TestWatchQueue_Evict(t *testing.T) {
	q := NewWatchQueue()
	q.Push(&WatchItem{Type: "pr", GithubID: 100,
		NextCheck: time.Now().Add(1 * time.Hour),
		LastSeen:  time.Now().Add(-2 * time.Hour)}) // stale
	q.Push(&WatchItem{Type: "pr", GithubID: 200,
		NextCheck: time.Now().Add(1 * time.Hour),
		LastSeen:  time.Now()}) // fresh
	evicted := q.Evict()
	if evicted != 1 {
		t.Errorf("evicted = %d, want 1", evicted)
	}
	if q.Len() != 1 {
		t.Errorf("queue len = %d, want 1", q.Len())
	}
}

func TestWatchQueue_PopOrderedByNextCheck(t *testing.T) {
	q := NewWatchQueue()
	now := time.Now()
	q.Push(&WatchItem{Type: "pr", GithubID: 100, NextCheck: now.Add(-2 * time.Second)})
	q.Push(&WatchItem{Type: "pr", GithubID: 200, NextCheck: now.Add(-5 * time.Second)})
	q.Push(&WatchItem{Type: "pr", GithubID: 300, NextCheck: now.Add(-1 * time.Second)})
	ready := q.PopReady()
	if len(ready) != 3 {
		t.Fatalf("expected 3 ready, got %d", len(ready))
	}
	// Should be ordered: 200 (earliest), 100, 300
	if ready[0].GithubID != 200 {
		t.Errorf("first = %d, want 200 (earliest NextCheck)", ready[0].GithubID)
	}
}
