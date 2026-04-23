// daemon/internal/bus/roundtrip_test.go
package bus_test

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/heimdallm/daemon/internal/bus"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

func TestRoundtrip_PRReview(t *testing.T) {
	b := newTestBus(t)
	ctx := context.Background()

	msg := bus.PRReviewMsg{
		Repo:     "org/repo",
		Number:   42,
		GithubID: 12345,
		HeadSHA:  "abc123",
	}
	data, err := bus.Encode(msg)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}

	_, err = b.JetStream().Publish(ctx, bus.SubjPRReview, data, jetstream.WithMsgID(
		fmt.Sprintf("%d:%s", msg.GithubID, msg.HeadSHA),
	))
	if err != nil {
		t.Fatalf("publish: %v", err)
	}

	cons, err := b.JetStream().Consumer(ctx, bus.StreamWork, bus.ConsumerReview)
	if err != nil {
		t.Fatalf("consumer: %v", err)
	}

	msgs, err := cons.Fetch(1, jetstream.FetchMaxWait(2*time.Second))
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}
	var got bus.PRReviewMsg
	for m := range msgs.Messages() {
		if err := bus.Decode(m.Data(), &got); err != nil {
			t.Fatalf("decode: %v", err)
		}
		m.Ack()
	}
	if msgs.Error() != nil {
		t.Fatalf("messages error: %v", msgs.Error())
	}

	if got.Repo != "org/repo" || got.Number != 42 || got.GithubID != 12345 || got.HeadSHA != "abc123" {
		t.Errorf("unexpected payload: %+v", got)
	}
}

func TestDedup_SameMsgID(t *testing.T) {
	b := newTestBus(t)
	ctx := context.Background()

	data, _ := bus.Encode(bus.PRReviewMsg{Repo: "a/b", Number: 1, GithubID: 100, HeadSHA: "sha1"})
	msgID := "100:sha1"

	_, err := b.JetStream().Publish(ctx, bus.SubjPRReview, data, jetstream.WithMsgID(msgID))
	if err != nil {
		t.Fatalf("publish 1: %v", err)
	}
	_, err = b.JetStream().Publish(ctx, bus.SubjPRReview, data, jetstream.WithMsgID(msgID))
	if err != nil {
		t.Fatalf("publish 2: %v", err)
	}

	cons, err := b.JetStream().Consumer(ctx, bus.StreamWork, bus.ConsumerReview)
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
		t.Errorf("expected 1 message (dedup), got %d", count)
	}
}

func TestBackpressure_MaxAckPending(t *testing.T) {
	b := newTestBus(t)
	ctx := context.Background()

	for i := 0; i < 4; i++ {
		data, _ := bus.Encode(bus.PRReviewMsg{
			Repo: "a/b", Number: i, GithubID: int64(i), HeadSHA: fmt.Sprintf("sha%d", i),
		})
		_, err := b.JetStream().Publish(ctx, bus.SubjPRReview, data, jetstream.WithMsgID(
			fmt.Sprintf("%d:sha%d", i, i),
		))
		if err != nil {
			t.Fatalf("publish %d: %v", i, err)
		}
	}

	cons, err := b.JetStream().Consumer(ctx, bus.StreamWork, bus.ConsumerReview)
	if err != nil {
		t.Fatalf("consumer: %v", err)
	}

	batch1, err := cons.Fetch(4, jetstream.FetchMaxWait(1*time.Second))
	if err != nil {
		t.Fatalf("fetch 1: %v", err)
	}
	var unacked []jetstream.Msg
	for m := range batch1.Messages() {
		unacked = append(unacked, m)
	}
	if len(unacked) != 3 {
		t.Fatalf("expected 3 messages (MaxAckPending), got %d", len(unacked))
	}

	batch2, err := cons.Fetch(1, jetstream.FetchMaxWait(500*time.Millisecond))
	if err != nil {
		t.Fatalf("fetch 2: %v", err)
	}
	extra := 0
	for range batch2.Messages() {
		extra++
	}
	if extra != 0 {
		t.Errorf("expected 0 messages (backpressure), got %d", extra)
	}

	unacked[0].Ack()
	time.Sleep(100 * time.Millisecond)

	batch3, err := cons.Fetch(1, jetstream.FetchMaxWait(2*time.Second))
	if err != nil {
		t.Fatalf("fetch 3: %v", err)
	}
	released := 0
	for m := range batch3.Messages() {
		released++
		m.Ack()
	}
	if released != 1 {
		t.Errorf("expected 1 message after ack, got %d", released)
	}

	for _, m := range unacked[1:] {
		m.Ack()
	}
}

func TestDurability_SurvivesRestart(t *testing.T) {
	dir := t.TempDir()
	ctx := context.Background()

	b1 := bus.New(bus.Config{DataDir: dir, MaxConcurrentWorkers: 3})
	if err := b1.Start(ctx); err != nil {
		t.Fatalf("start 1: %v", err)
	}
	data, _ := bus.Encode(bus.PRReviewMsg{Repo: "a/b", Number: 99, GithubID: 999, HeadSHA: "durable"})
	_, err := b1.JetStream().Publish(ctx, bus.SubjPRReview, data, jetstream.WithMsgID("999:durable"))
	if err != nil {
		t.Fatalf("publish: %v", err)
	}
	b1.Stop()

	b2 := bus.New(bus.Config{DataDir: dir, MaxConcurrentWorkers: 3})
	if err := b2.Start(ctx); err != nil {
		t.Fatalf("start 2: %v", err)
	}
	defer b2.Stop()

	cons, err := b2.JetStream().Consumer(ctx, bus.StreamWork, bus.ConsumerReview)
	if err != nil {
		t.Fatalf("consumer: %v", err)
	}

	msgs, err := cons.Fetch(1, jetstream.FetchMaxWait(2*time.Second))
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}
	var got bus.PRReviewMsg
	count := 0
	for m := range msgs.Messages() {
		count++
		bus.Decode(m.Data(), &got)
		m.Ack()
	}
	if count != 1 {
		t.Fatalf("expected 1 durable message, got %d", count)
	}
	if got.Number != 99 {
		t.Errorf("Number = %d, want 99", got.Number)
	}
}

func TestEventsFanOut(t *testing.T) {
	b := newTestBus(t)

	ch1 := make(chan *nats.Msg, 1)
	ch2 := make(chan *nats.Msg, 1)
	sub1, err := b.Conn().ChanSubscribe("heimdallm.events.>", ch1)
	if err != nil {
		t.Fatalf("chanSub1: %v", err)
	}
	defer sub1.Unsubscribe()
	sub2, err := b.Conn().ChanSubscribe("heimdallm.events.>", ch2)
	if err != nil {
		t.Fatalf("chanSub2: %v", err)
	}
	defer sub2.Unsubscribe()

	data, _ := bus.Encode(bus.EventMsg{Type: "review_completed", Data: map[string]any{"pr": 1}})
	if err := b.Conn().Publish(bus.SubjEventReviewCompleted, data); err != nil {
		t.Fatalf("publish: %v", err)
	}
	b.Conn().Flush()

	for i, ch := range []chan *nats.Msg{ch1, ch2} {
		select {
		case m := <-ch:
			var got bus.EventMsg
			bus.Decode(m.Data, &got)
			if got.Type != "review_completed" {
				t.Errorf("sub%d: type = %q, want review_completed", i+1, got.Type)
			}
		case <-time.After(2 * time.Second):
			t.Errorf("sub%d: timeout", i+1)
		}
	}
}

func TestMaxDeliver_Exhausted(t *testing.T) {
	b := newTestBus(t)
	ctx := context.Background()

	data, _ := bus.Encode(bus.IssueMsg{Repo: "a/b", Number: 7, GithubID: 777})
	_, err := b.JetStream().Publish(ctx, bus.SubjIssueTriage, data, jetstream.WithMsgID("777"))
	if err != nil {
		t.Fatalf("publish: %v", err)
	}

	cons, err := b.JetStream().Consumer(ctx, bus.StreamWork, bus.ConsumerTriage)
	if err != nil {
		t.Fatalf("consumer: %v", err)
	}

	for i := 0; i < 3; i++ {
		msgs, err := cons.Fetch(1, jetstream.FetchMaxWait(2*time.Second))
		if err != nil {
			t.Fatalf("fetch %d: %v", i, err)
		}
		for m := range msgs.Messages() {
			m.Nak()
		}
		time.Sleep(100 * time.Millisecond)
	}

	msgs, err := cons.Fetch(1, jetstream.FetchMaxWait(1*time.Second))
	if err != nil {
		t.Fatalf("fetch final: %v", err)
	}
	count := 0
	for range msgs.Messages() {
		count++
	}
	if count != 0 {
		t.Errorf("expected 0 messages after max deliver, got %d", count)
	}
}
