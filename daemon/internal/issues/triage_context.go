package issues

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/heimdallm/daemon/internal/github"
)

// partitionComments splits comments into those created before and after the cutoff timestamp.
func partitionComments(comments []github.Comment, cutoff time.Time) (before, after []github.Comment) {
	for _, c := range comments {
		if c.CreatedAt.After(cutoff) {
			after = append(after, c)
		} else {
			before = append(before, c)
		}
	}
	return
}

// triageFinding is the minimal struct for deserializing a previous triage from JSON.
type triageFinding struct {
	Severity          string `json:"severity"`
	Category          string `json:"category"`
	SuggestedAssignee string `json:"suggested_assignee"`
}

// buildIssueTriageContext creates a structured prompt section for re-triages.
// Returns empty string for first-time triages (no previous review exists).
func buildIssueTriageContext(prevTriageJSON, prevSuggestionsJSON, prevSummary string, lastTriageAt time.Time, comments []github.Comment, botLogin string) string {
	if prevTriageJSON == "" && lastTriageAt.IsZero() {
		return ""
	}

	var b strings.Builder

	b.WriteString("IMPORTANT: This is a RE-TRIAGE. You previously triaged this issue.\n")
	b.WriteString("- Focus on NEW information since your last triage\n")
	b.WriteString("- Update your assessment if the new comments change the scope/severity\n")
	b.WriteString("- Do NOT repeat your previous analysis verbatim\n\n")

	var triage triageFinding
	if prevTriageJSON != "" && prevTriageJSON != "{}" {
		json.Unmarshal([]byte(prevTriageJSON), &triage)
	}

	hasTriage := triage.Severity != "" || triage.Category != ""
	if hasTriage || prevSummary != "" {
		severity := triage.Severity
		if severity == "" {
			severity = "unknown"
		}
		b.WriteString(fmt.Sprintf("## Your previous triage (severity: %s)\n\n", severity))
		if prevSummary != "" {
			b.WriteString(fmt.Sprintf("Summary: %s\n", prevSummary))
		}
		if triage.Category != "" {
			b.WriteString(fmt.Sprintf("- Category: %s\n", triage.Category))
		}
		if triage.SuggestedAssignee != "" {
			b.WriteString(fmt.Sprintf("- Suggested assignee: @%s\n", strings.TrimLeft(triage.SuggestedAssignee, "@")))
		}

		var suggestions []string
		if prevSuggestionsJSON != "" && prevSuggestionsJSON != "[]" {
			json.Unmarshal([]byte(prevSuggestionsJSON), &suggestions)
		}
		if len(suggestions) > 0 {
			b.WriteString("- Next steps:\n")
			for _, s := range suggestions {
				b.WriteString(fmt.Sprintf("  - %s\n", s))
			}
		}
		b.WriteString("\n")
	}

	_, afterComments := partitionComments(comments, lastTriageAt)

	var newDiscussion []github.Comment
	for _, c := range afterComments {
		if !strings.EqualFold(c.Author, botLogin) {
			newDiscussion = append(newDiscussion, c)
		}
	}

	if len(newDiscussion) > 0 {
		b.WriteString("## New discussion since last triage\n\n")
		for _, c := range newDiscussion {
			b.WriteString(fmt.Sprintf("@%s: %s\n", c.Author, strings.TrimSpace(c.Body)))
		}
		b.WriteString("\n")
	}

	return b.String()
}
