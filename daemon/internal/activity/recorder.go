// Package activity records a row in the activity_log table for every
// significant Heimdallm action emitted on the SSE broker. The recorder
// subscribes once on Start and runs until its context is cancelled.
//
// Failure mode: log + drop. The activity log is observability, so a
// failed insert (disk full, locked DB) must never block the publisher.
package activity

import (
	"context"
	"encoding/json"
	"log/slog"
	"strings"
	"time"

	"github.com/heimdallm/daemon/internal/sse"
)

// Store is the subset of *store.Store the recorder uses. Kept as a local
// interface so tests can inject fakes without importing the real store.
type Store interface {
	InsertActivity(ts time.Time, org, repo, itemType string, itemNumber int,
		itemTitle, action, outcome string, details map[string]any) (int64, error)
}

// Recorder consumes SSE events and writes activity rows.
type Recorder struct {
	store  Store
	events chan sse.Event
}

// New subscribes to the broker and returns a recorder ready to Start.
// Returns nil if the broker has reached its subscriber limit; the caller
// should log and continue without the recorder (activity is optional).
func New(s Store, broker *sse.Broker) *Recorder {
	ch := broker.Subscribe()
	if ch == nil {
		return nil
	}
	return &Recorder{store: s, events: ch}
}

// NewWithChannel is a test hook. Production code uses New.
func NewWithChannel(s Store, ch chan sse.Event) *Recorder {
	return &Recorder{store: s, events: ch}
}

// Start runs the event loop. Returns when ctx is cancelled or the event
// channel is closed.
func (r *Recorder) Start(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case ev, ok := <-r.events:
			if !ok {
				return
			}
			if err := r.handle(ev); err != nil {
				slog.Warn("activity: record failed", "err", err, "event", ev.Type)
			}
		}
	}
}

func (r *Recorder) handle(ev sse.Event) error {
	switch ev.Type {
	case sse.EventReviewCompleted:
		return r.recordReviewCompleted(ev)
	default:
		return nil // unknown/ignored
	}
}

// payload helpers ----------------------------------------------------------

func decode(data string, v any) error {
	return json.Unmarshal([]byte(data), v)
}

func orgOf(repo string) string {
	i := strings.IndexByte(repo, '/')
	if i < 0 {
		return repo
	}
	return repo[:i]
}

// event handlers -----------------------------------------------------------

func (r *Recorder) recordReviewCompleted(ev sse.Event) error {
	var p struct {
		Repo              string `json:"repo"`
		PRNumber          int    `json:"pr_number"`
		PRTitle           string `json:"pr_title"`
		CLIUsed           string `json:"cli_used"`
		Severity          string `json:"severity"`
		ReviewID          int64  `json:"review_id"`
		GitHubReviewState string `json:"github_review_state"`
	}
	if err := decode(ev.Data, &p); err != nil {
		return err
	}
	details := map[string]any{
		"cli_used":            p.CLIUsed,
		"review_id":           p.ReviewID,
		"github_review_state": p.GitHubReviewState,
	}
	_, err := r.store.InsertActivity(time.Now(), orgOf(p.Repo), p.Repo, "pr",
		p.PRNumber, p.PRTitle, "review", p.Severity, details)
	return err
}
