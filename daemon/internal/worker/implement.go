// daemon/internal/worker/implement.go
package worker

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"runtime/debug"

	"github.com/heimdallm/daemon/internal/bus"
	"github.com/nats-io/nats.go/jetstream"
)

// ImplementWorker consumes issue implement requests from NATS and delegates
// to a handler that runs the issue pipeline in Develop mode.
type ImplementWorker struct {
	js      jetstream.JetStream
	handler func(ctx context.Context, msg bus.IssueMsg)
}

// NewImplementWorker creates a worker that consumes from the implement-worker
// durable consumer.
func NewImplementWorker(js jetstream.JetStream, handler func(context.Context, bus.IssueMsg)) *ImplementWorker {
	return &ImplementWorker{js: js, handler: handler}
}

// Start begins consuming. Blocks until ctx is cancelled.
// Always acks messages — errors are logged inside the handler.
func (w *ImplementWorker) Start(ctx context.Context) error {
	cons, err := w.js.Consumer(ctx, bus.StreamWork, bus.ConsumerImplement)
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
			return fmt.Errorf("implement-worker: iter.Next: %w", err)
		}

		var issueMsg bus.IssueMsg
		if err := bus.Decode(msg.Data(), &issueMsg); err != nil {
			slog.Error("implement-worker: decode message", "err", err)
			msg.Ack()
			continue
		}

		slog.Info("implement-worker: processing",
			"repo", issueMsg.Repo, "number", issueMsg.Number, "github_id", issueMsg.GithubID)

		w.safeHandle(ctx, issueMsg)
		msg.Ack()
	}
}

func (w *ImplementWorker) safeHandle(ctx context.Context, msg bus.IssueMsg) {
	defer func() {
		if r := recover(); r != nil {
			slog.Error("implement-worker: handler panic",
				"repo", msg.Repo, "number", msg.Number, "panic", r,
				"stack", string(debug.Stack()))
		}
	}()
	w.handler(ctx, msg)
}
