package issues

import (
	"context"
	"fmt"
	"log/slog"
	"strings"

	"github.com/heimdallm/daemon/internal/config"
	"github.com/heimdallm/daemon/internal/github"
)

// PromoteIssueClient is the subset of *github.Client that PromoteReady
// uses. Scoped to the minimum so tests can inject an in-memory fake.
type PromoteIssueClient interface {
	ListOpenIssues(repo string) ([]*github.Issue, error)
	GetIssue(repo string, number int) (*github.Issue, error)
	AddLabels(repo string, number int, labels []string) error
	RemoveLabels(repo string, number int, labels []string) error
	PostComment(repo string, number int, body string) error
}

// PromoteReady scans every monitored repo for open issues carrying a
// "blocked" label, checks whether each issue's declared dependencies have
// all closed, and — when they have — flips the blocked label(s) to the
// configured promote-to label. The next poll cycle then picks up the
// freshly-promoted issue through the normal FetchIssues path.
//
// Returns the number of promotions performed and the first fatal error.
// Per-issue failures (a bad dep, a transient GitHub 5xx) are logged and
// counted as "skipped", they don't abort the whole run: the next poll
// cycle retries naturally.
//
// The call is a no-op when issue tracking is disabled, when no blocked
// labels are configured, or when every repo in the list is empty — keeps
// default installs unaffected.
func PromoteReady(ctx context.Context, c PromoteIssueClient, cfg config.IssueTrackingConfig, repos []string) (int, error) {
	if !cfg.Enabled || len(cfg.BlockedLabels) == 0 {
		return 0, nil
	}
	promoteTo := cfg.ResolvePromoteToLabel()
	if promoteTo == "" {
		return 0, fmt.Errorf("issues promote: blocked_labels set but promote target unresolved")
	}
	if ctx == nil {
		ctx = context.Background()
	}

	blockedSet := lowerSet(cfg.BlockedLabels)
	promoted := 0

	for _, repo := range repos {
		if err := ctx.Err(); err != nil {
			return promoted, err
		}
		issues, err := c.ListOpenIssues(repo)
		if err != nil {
			slog.Warn("issues promote: list failed, skipping repo this cycle", "repo", repo, "err", err)
			continue
		}

		for _, issue := range issues {
			blockedOnIssue := intersectLabels(issue.LabelNames(), blockedSet)
			if len(blockedOnIssue) == 0 {
				continue
			}
			deps := ParseDependencies(issue.Body, repo)
			if len(deps) == 0 {
				// Carries a blocked label but no structured deps declared.
				// We can't know what "ready" means here, so stay out — the
				// operator likely wants to unblock manually.
				continue
			}
			ready, err := allDepsClosed(c, deps)
			if err != nil {
				slog.Warn("issues promote: dep check failed",
					"repo", repo, "issue", issue.Number, "err", err)
				continue
			}
			if !ready {
				continue
			}
			if err := applyPromotion(c, issue, blockedOnIssue, promoteTo); err != nil {
				slog.Warn("issues promote: apply failed",
					"repo", repo, "issue", issue.Number, "err", err)
				continue
			}
			promoted++
			slog.Info("issues promote: promoted issue",
				"repo", repo, "issue", issue.Number,
				"from", blockedOnIssue, "to", promoteTo)
		}
	}
	return promoted, nil
}

// allDepsClosed returns true only when EVERY referenced issue/PR is in
// state "closed". A closed PR with state "merged" is reported by GitHub
// with state == "closed" too (merged is a sub-state exposed through
// pull_request.merged_at which we don't need to inspect — "closed" is
// sufficient for "this work has landed one way or another").
//
// Any non-fatal error returns (false, err) so the caller can log and
// skip — a transient API failure is retried on the next poll cycle.
func allDepsClosed(c PromoteIssueClient, deps []IssueRef) (bool, error) {
	for _, d := range deps {
		got, err := c.GetIssue(d.Repo, d.Number)
		if err != nil {
			return false, fmt.Errorf("dep %s#%d: %w", d.Repo, d.Number, err)
		}
		if got.State != "closed" {
			return false, nil
		}
	}
	return true, nil
}

// applyPromotion flips the blocked label(s) to the promote-to label and
// leaves an audit comment. Calls are ordered remove → add → comment: if
// add fails we've already removed, which is less bad than the reverse
// (double-labelled, in both states at once).
func applyPromotion(c PromoteIssueClient, issue *github.Issue, blockedLabels []string, promoteTo string) error {
	if err := c.RemoveLabels(issue.Repo, issue.Number, blockedLabels); err != nil {
		return fmt.Errorf("remove blocked: %w", err)
	}
	if err := c.AddLabels(issue.Repo, issue.Number, []string{promoteTo}); err != nil {
		return fmt.Errorf("add promote-to: %w", err)
	}
	body := fmt.Sprintf(
		"All declared dependencies are closed, promoting to `%s`.\n\n---\n*Promoted by Heimdallm*",
		promoteTo,
	)
	if err := c.PostComment(issue.Repo, issue.Number, body); err != nil {
		// Comment failure is non-fatal — labels already flipped, the
		// next poll cycle will process the issue normally. Log only.
		slog.Warn("issues promote: audit comment failed (labels already flipped)",
			"repo", issue.Repo, "issue", issue.Number, "err", err)
	}
	return nil
}

func lowerSet(xs []string) map[string]struct{} {
	m := make(map[string]struct{}, len(xs))
	for _, x := range xs {
		m[strings.ToLower(strings.TrimSpace(x))] = struct{}{}
	}
	return m
}

// intersectLabels returns the subset of `have` that are also in `want`
// (case-insensitive). Preserves the casing from `have` so RemoveLabels
// hits the exact label GitHub stores.
func intersectLabels(have []string, want map[string]struct{}) []string {
	var out []string
	for _, h := range have {
		key := strings.ToLower(strings.TrimSpace(h))
		if _, ok := want[key]; ok {
			out = append(out, h)
		}
	}
	return out
}
