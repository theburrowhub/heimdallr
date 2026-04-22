package issues

import (
	"strings"
	"testing"
	"time"

	"github.com/heimdallm/daemon/internal/github"
)

func TestPartitionComments_SplitsByTimestamp(t *testing.T) {
	cutoff := time.Date(2026, 4, 15, 12, 0, 0, 0, time.UTC)
	comments := []github.Comment{
		{Author: "reviewer", Body: "old comment", CreatedAt: cutoff.Add(-1 * time.Hour)},
		{Author: "author", Body: "old response", CreatedAt: cutoff.Add(-30 * time.Minute)},
		{Author: "author", Body: "new push", CreatedAt: cutoff.Add(1 * time.Hour)},
		{Author: "other", Body: "new feedback", CreatedAt: cutoff.Add(2 * time.Hour)},
	}

	before, after := partitionComments(comments, cutoff)
	if len(before) != 2 {
		t.Errorf("before = %d, want 2", len(before))
	}
	if len(after) != 2 {
		t.Errorf("after = %d, want 2", len(after))
	}
}

func TestPartitionComments_AllBefore(t *testing.T) {
	cutoff := time.Now()
	comments := []github.Comment{
		{Author: "a", Body: "old", CreatedAt: cutoff.Add(-1 * time.Hour)},
	}
	before, after := partitionComments(comments, cutoff)
	if len(before) != 1 || len(after) != 0 {
		t.Errorf("before=%d after=%d, want 1/0", len(before), len(after))
	}
}

func TestPartitionComments_AllAfter(t *testing.T) {
	cutoff := time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC)
	comments := []github.Comment{
		{Author: "a", Body: "new", CreatedAt: time.Now()},
	}
	before, after := partitionComments(comments, cutoff)
	if len(before) != 0 || len(after) != 1 {
		t.Errorf("before=%d after=%d, want 0/1", len(before), len(after))
	}
}

func TestPartitionComments_Empty(t *testing.T) {
	before, after := partitionComments(nil, time.Now())
	if len(before) != 0 || len(after) != 0 {
		t.Error("expected empty slices for nil input")
	}
}

func TestBuildIssueTriageContext_WithPreviousTriage(t *testing.T) {
	prevTriage := `{"severity":"high","category":"bug","suggested_assignee":"alice"}`
	prevSuggestions := `["reproduce locally","check auth migration"]`
	prevSummary := "Login fails after upgrade with a 500 error."
	lastTriageAt := time.Date(2026, 4, 15, 12, 0, 0, 0, time.UTC)

	comments := []github.Comment{
		{Author: "heimdallm-bot", Body: "Triage comment", CreatedAt: lastTriageAt.Add(-1 * time.Minute)},
		{Author: "author", Body: "Actually we want to support subdirectories long-term", CreatedAt: lastTriageAt.Add(1 * time.Hour)},
		{Author: "reviewer", Body: "Agreed, the template needs to handle glob patterns", CreatedAt: lastTriageAt.Add(2 * time.Hour)},
	}

	ctx := buildIssueTriageContext(prevTriage, prevSuggestions, prevSummary, lastTriageAt, comments, "heimdallm-bot")

	if ctx == "" {
		t.Fatal("expected non-empty triage context")
	}
	if !strings.Contains(ctx, "RE-TRIAGE") {
		t.Error("missing RE-TRIAGE instruction")
	}
	if !strings.Contains(ctx, "severity: high") {
		t.Error("missing previous severity")
	}
	if !strings.Contains(ctx, "Category: bug") {
		t.Error("missing previous category")
	}
	if !strings.Contains(ctx, "@alice") {
		t.Error("missing previous suggested assignee")
	}
	if !strings.Contains(ctx, "reproduce locally") {
		t.Error("missing previous suggestion")
	}
	if !strings.Contains(ctx, "Login fails after upgrade") {
		t.Error("missing previous summary")
	}
	if !strings.Contains(ctx, "support subdirectories") {
		t.Error("missing author response in new discussion")
	}
	if !strings.Contains(ctx, "glob patterns") {
		t.Error("missing reviewer response in new discussion")
	}
	// Bot's own comment should NOT appear in "New discussion since last triage"
	if strings.Contains(ctx, "Triage comment") {
		t.Error("bot's own comment should be filtered from new discussion")
	}
}

func TestBuildIssueTriageContext_NoPreviousTriage(t *testing.T) {
	ctx := buildIssueTriageContext("", "", "", time.Time{}, nil, "bot")
	if ctx != "" {
		t.Errorf("expected empty context for first triage, got: %q", ctx)
	}
}

func TestBuildIssueTriageContext_PreviousTriageNoNewComments(t *testing.T) {
	prevTriage := `{"severity":"low","category":"feature","suggested_assignee":""}`
	prevSuggestions := `["add docs"]`
	lastTriageAt := time.Now()

	ctx := buildIssueTriageContext(prevTriage, prevSuggestions, "Feature request for glob support.", lastTriageAt, nil, "bot")

	if !strings.Contains(ctx, "RE-TRIAGE") {
		t.Error("missing RE-TRIAGE instruction")
	}
	if !strings.Contains(ctx, "severity: low") {
		t.Error("missing previous severity")
	}
	if !strings.Contains(ctx, "add docs") {
		t.Error("missing previous suggestion")
	}
	if strings.Contains(ctx, "New discussion since") {
		t.Error("should not have discussion section with no new comments")
	}
}

func TestBuildIssueTriageContext_EmptyTriageJSON(t *testing.T) {
	// When triage is "{}" (no fields), should still show RE-TRIAGE header
	// if lastTriageAt is non-zero and summary exists.
	lastTriageAt := time.Now()
	ctx := buildIssueTriageContext("{}", "[]", "Previous summary.", lastTriageAt, nil, "bot")

	if !strings.Contains(ctx, "RE-TRIAGE") {
		t.Error("missing RE-TRIAGE instruction")
	}
	if !strings.Contains(ctx, "Previous summary.") {
		t.Error("missing previous summary")
	}
}

func TestBuildIssueTriageContext_BotFilteringCaseInsensitive(t *testing.T) {
	lastTriageAt := time.Date(2026, 4, 15, 12, 0, 0, 0, time.UTC)
	comments := []github.Comment{
		{Author: "Heimdallm-Bot", Body: "I am the bot", CreatedAt: lastTriageAt.Add(1 * time.Hour)},
		{Author: "human", Body: "Real comment", CreatedAt: lastTriageAt.Add(2 * time.Hour)},
	}

	ctx := buildIssueTriageContext(`{"severity":"medium"}`, "[]", "", lastTriageAt, comments, "heimdallm-bot")

	if strings.Contains(ctx, "I am the bot") {
		t.Error("bot comment should be filtered case-insensitively")
	}
	if !strings.Contains(ctx, "Real comment") {
		t.Error("human comment should appear in new discussion")
	}
}
