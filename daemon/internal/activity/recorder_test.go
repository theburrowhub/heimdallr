package activity_test

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/heimdallm/daemon/internal/activity"
	"github.com/heimdallm/daemon/internal/sse"
	"github.com/heimdallm/daemon/internal/store"
)

type recordedInsert struct {
	ts                         time.Time
	org, repo, itemType        string
	itemNumber                 int
	itemTitle, action, outcome string
	details                    map[string]any
}

type fakeStore struct {
	inserts  []recordedInsert
	failNext bool
}

func (f *fakeStore) InsertActivity(
	ts time.Time, org, repo, itemType string, itemNumber int,
	itemTitle, action, outcome string, details map[string]any,
) (int64, error) {
	if f.failNext {
		f.failNext = false
		return 0, assertErr("store full")
	}
	f.inserts = append(f.inserts, recordedInsert{ts, org, repo, itemType, itemNumber, itemTitle, action, outcome, details})
	return int64(len(f.inserts)), nil
}

type assertErr string

func (e assertErr) Error() string { return string(e) }

func newTestRecorder(t *testing.T) (*activity.Recorder, *fakeStore, chan sse.Event) {
	t.Helper()
	fs := &fakeStore{}
	events := make(chan sse.Event, 4)
	r := activity.NewWithChannel(fs, events)
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go r.Start(ctx)
	return r, fs, events
}

func waitFor(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("condition not met within 2s")
}

// Compile-time check: real *store.Store satisfies the recorder's Store interface.
var _ activity.Store = (*store.Store)(nil)

func TestRecorder_ReviewCompleted(t *testing.T) {
	_, fs, events := newTestRecorder(t)

	payload, _ := json.Marshal(map[string]any{
		"repo":                "acme/api",
		"pr_number":           42,
		"pr_title":            "Fix rate limiter",
		"cli_used":            "claude",
		"severity":            "major",
		"review_id":           789,
		"github_review_state": "COMMENTED",
	})
	events <- sse.Event{Type: sse.EventReviewCompleted, Data: string(payload)}

	waitFor(t, func() bool { return len(fs.inserts) == 1 })

	got := fs.inserts[0]
	if got.repo != "acme/api" || got.itemType != "pr" || got.itemNumber != 42 {
		t.Errorf("row basics: %+v", got)
	}
	if got.action != "review" || got.outcome != "major" {
		t.Errorf("action/outcome: %s/%s", got.action, got.outcome)
	}
	if got.org != "acme" {
		t.Errorf("org = %q, want acme", got.org)
	}
	if got.details["cli_used"] != "claude" {
		t.Errorf("details: %+v", got.details)
	}
}
