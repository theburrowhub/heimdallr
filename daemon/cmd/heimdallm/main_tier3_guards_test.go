package main

import (
	"context"
	"encoding/json"
	"sync"
	"testing"
	"time"

	"github.com/heimdallm/daemon/internal/config"
	gh "github.com/heimdallm/daemon/internal/github"
	"github.com/heimdallm/daemon/internal/scheduler"
	"github.com/heimdallm/daemon/internal/sse"
)

// TestTier3Adapter_HandleChange_SkipsClosedPR verifies the Tier 3 correctness
// fix: when the fresh snapshot shows a closed/merged PR, HandleChange must NOT
// call runReview and must publish a review_skipped SSE event with reason
// not_open. This is the bug we set out to fix in this plan.
func TestTier3Adapter_HandleChange_SkipsClosedPR(t *testing.T) {
	s := newMemStore(t)

	broker := sse.NewBroker()
	broker.Start()
	defer broker.Stop()

	// Subscribe BEFORE calling HandleChange so we don't miss the event.
	events := broker.Subscribe()
	defer broker.Unsubscribe(events)

	var (
		loginMu sync.Mutex
		login   = "heimdallm-bot"
		cfgMu   sync.Mutex
		cfg     = &config.Config{}
	)

	runReviewCalls := 0
	runReview := func(pr *gh.PullRequest, aiCfg config.RepoAI) {
		runReviewCalls++
	}

	a := &tier2Adapter{
		ghClient:  nil, // HandleChange on skip path does not touch ghClient
		store:     s,
		broker:    broker,
		cfgMu:     &cfgMu,
		cfg:       &cfg,
		loginMu:   &loginMu,
		login:     &login,
		runReview: runReview,
	}

	ctx := context.Background()
	item := &scheduler.WatchItem{
		Type:     "pr",
		Repo:     "org/repo",
		Number:   42,
		GithubID: 42,
		LastSeen: time.Now(),
	}
	snap := &scheduler.ItemSnapshot{
		State:     "closed",
		Draft:     false,
		Author:    "alice",
		UpdatedAt: time.Now().Add(time.Minute),
	}

	if err := a.HandleChange(ctx, item, snap); err != nil {
		t.Fatalf("HandleChange: %v", err)
	}
	if runReviewCalls != 0 {
		t.Errorf("runReview invoked on closed PR: calls=%d", runReviewCalls)
	}

	select {
	case ev := <-events:
		if ev.Type != sse.EventReviewSkipped {
			t.Errorf("event type = %q, want %q", ev.Type, sse.EventReviewSkipped)
		}
		var p struct {
			Reason   string `json:"reason"`
			PRNumber int    `json:"pr_number"`
			Repo     string `json:"repo"`
		}
		if err := json.Unmarshal([]byte(ev.Data), &p); err != nil {
			t.Fatalf("decode event: %v", err)
		}
		if p.Reason != "not_open" {
			t.Errorf("reason = %q, want not_open", p.Reason)
		}
		if p.PRNumber != 42 || p.Repo != "org/repo" {
			t.Errorf("payload = %+v, want pr=42 repo=org/repo", p)
		}
	case <-time.After(1 * time.Second):
		t.Fatal("no SSE event emitted within 1s")
	}
}
