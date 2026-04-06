package github

import (
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const defaultBaseURL = "https://api.github.com"

// maxBodyBytes limits the size of API response bodies read into memory to
// prevent out-of-memory conditions caused by unexpectedly large responses.
const maxBodyBytes = 1 * 1024 * 1024 // 1 MB for most API responses

// maxDiffBodyBytes allows a larger limit for PR diffs, which can be legitimately large.
const maxDiffBodyBytes = 10 * 1024 * 1024 // 10 MB for diffs

// maxErrBodyLen limits the number of bytes included in error messages to avoid
// leaking sensitive GitHub diagnostic information (e.g. token details).
const maxErrBodyLen = 200

type Client struct {
	token   string
	baseURL string
	http    *http.Client
}

type Option func(*Client)

func WithBaseURL(u string) Option {
	return func(c *Client) { c.baseURL = u }
}

func NewClient(token string, opts ...Option) *Client {
	c := &Client{
		token:   token,
		baseURL: defaultBaseURL,
		http:    &http.Client{Timeout: 30 * time.Second},
	}
	for _, o := range opts {
		o(c)
	}
	return c
}

// AuthenticatedUser returns the GitHub login of the token owner.
// Used to resolve the actual username instead of @me (which some token types reject).
func (c *Client) AuthenticatedUser() (string, error) {
	resp, err := c.do("GET", "/user", "application/vnd.github+json")
	if err != nil {
		return "", fmt.Errorf("github: get user: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, maxBodyBytes))
		errBody := string(body)
		if len(errBody) > maxErrBodyLen {
			errBody = errBody[:maxErrBodyLen]
		}
		return "", fmt.Errorf("github: get user: status %d: %s", resp.StatusCode, errBody)
	}
	var u struct {
		Login string `json:"login"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, maxBodyBytes)).Decode(&u); err != nil {
		return "", fmt.Errorf("github: decode user: %w", err)
	}
	return u.Login, nil
}

func (c *Client) do(method, path string, accept string) (*http.Response, error) {
	req, err := http.NewRequest(method, c.baseURL+path, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set("Accept", accept)
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	return c.http.Do(req)
}

// FetchPRsToReview returns all open PRs where the authenticated user is explicitly
// requested as reviewer, across ALL repos (no repo filter in the query).
//
// The repo filter is intentionally omitted: adding many `repo:` terms to the
// GitHub Search API query can exceed its length limit and silently return zero
// results. Filtering by monitored repos is done in the caller instead.
func (c *Client) FetchPRsToReview() ([]*PullRequest, error) {
	username, err := c.AuthenticatedUser()
	if err != nil {
		return nil, fmt.Errorf("github: resolve user: %w", err)
	}
	prs, err := c.fetchByQualifier(username, "review-requested", nil) // no repo filter
	if err != nil {
		return nil, err
	}
	slog.Info("github: PRs to review (all repos)", "count", len(prs))
	return prs, nil
}

// FetchPRs fetches all open PRs where the user is reviewer, assignee, or author.
// Used for the dashboard display only — NOT for triggering AI reviews.
func (c *Client) FetchPRs(repos []string) ([]*PullRequest, error) {
	username, err := c.AuthenticatedUser()
	if err != nil {
		return nil, fmt.Errorf("github: resolve user: %w", err)
	}

	qualifiers := []string{"review-requested", "assignee", "author"}
	seen := make(map[int64]struct{})
	var all []*PullRequest

	for _, q := range qualifiers {
		prs, err := c.fetchByQualifier(username, q, repos)
		if err != nil {
			slog.Warn("github: fetch PRs partial error", "qualifier", q, "err", err)
			continue
		}
		for _, pr := range prs {
			if _, dup := seen[pr.ID]; !dup {
				seen[pr.ID] = struct{}{}
				all = append(all, pr)
			}
		}
	}
	return all, nil
}

func (c *Client) fetchByQualifier(username, qualifier string, repos []string) ([]*PullRequest, error) {
	repoFilter := ""
	if len(repos) > 0 {
		repoFilter = " repo:" + strings.Join(repos, " repo:")
	}
	query := fmt.Sprintf("is:pr is:open %s:%s%s", qualifier, username, repoFilter)
	params := url.Values{}
	params.Set("q", query)
	params.Set("per_page", "100")

	resp, err := c.do("GET", "/search/issues?"+params.Encode(), "application/vnd.github+json")
	if err != nil {
		return nil, fmt.Errorf("github: search PRs (%s): %w", qualifier, err)
	}
	body, _ := io.ReadAll(io.LimitReader(resp.Body, maxBodyBytes))
	resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		errBody := string(body)
		if len(errBody) > maxErrBodyLen {
			errBody = errBody[:maxErrBodyLen]
		}
		return nil, fmt.Errorf("github: search PRs (%s): status %d: %s", qualifier, resp.StatusCode, errBody)
	}
	var result struct {
		Items []*PullRequest `json:"items"`
	}
	if err := json.Unmarshal(body, &result); err != nil {
		return nil, fmt.Errorf("github: decode search (%s): %w", qualifier, err)
	}
	return result.Items, nil
}

// SubmitReview posts an AI-generated review to GitHub as a PR review.
// event should be "REQUEST_CHANGES", "COMMENT", or "APPROVE".
// Returns the GitHub review ID.
func (c *Client) SubmitReview(repo string, number int, body, event string) (int64, error) {
	path := fmt.Sprintf("/repos/%s/pulls/%d/reviews", repo, number)

	payload := map[string]any{
		"body":  body,
		"event": event,
	}

	data, _ := json.Marshal(payload)
	req, err := http.NewRequest("POST", c.baseURL+path, strings.NewReader(string(data)))
	if err != nil {
		return 0, fmt.Errorf("github: submit review: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")

	resp, err := c.http.Do(req)
	if err != nil {
		return 0, fmt.Errorf("github: submit review: %w", err)
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(io.LimitReader(resp.Body, maxBodyBytes))
	if resp.StatusCode != http.StatusOK && resp.StatusCode != 200 {
		errBody := string(respBody)
		if len(errBody) > maxErrBodyLen {
			errBody = errBody[:maxErrBodyLen]
		}
		return 0, fmt.Errorf("github: submit review: status %d: %s", resp.StatusCode, errBody)
	}

	var result struct {
		ID int64 `json:"id"`
	}
	if err := json.Unmarshal(respBody, &result); err != nil {
		return 0, fmt.Errorf("github: submit review: decode: %w", err)
	}
	return result.ID, nil
}

// PostComment posts a general comment on a PR (issue comment).
// Used in multi-feedback mode to post one comment per issue before the formal review.
func (c *Client) PostComment(repo string, number int, body string) error {
	path := fmt.Sprintf("/repos/%s/issues/%d/comments", repo, number)
	payload := map[string]any{"body": body}
	data, _ := json.Marshal(payload)
	req, err := http.NewRequest("POST", c.baseURL+path, strings.NewReader(string(data)))
	if err != nil {
		return fmt.Errorf("github: post comment: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("github: post comment: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		respBody, _ := io.ReadAll(io.LimitReader(resp.Body, maxBodyBytes))
		errBody := string(respBody)
		if len(errBody) > maxErrBodyLen {
			errBody = errBody[:maxErrBodyLen]
		}
		return fmt.Errorf("github: post comment: status %d: %s", resp.StatusCode, errBody)
	}
	return nil
}

// FetchDiff returns the unified diff for a PR.
func (c *Client) FetchDiff(repo string, number int) (string, error) {
	path := fmt.Sprintf("/repos/%s/pulls/%d", repo, number)
	resp, err := c.do("GET", path, "application/vnd.github.v3.diff")
	if err != nil {
		return "", fmt.Errorf("github: fetch diff: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, maxBodyBytes))
		errBody := string(body)
		if len(errBody) > maxErrBodyLen {
			errBody = errBody[:maxErrBodyLen]
		}
		return "", fmt.Errorf("github: fetch diff: status %d: %s", resp.StatusCode, errBody)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxDiffBodyBytes))
	if err != nil {
		return "", fmt.Errorf("github: fetch diff (%s #%d): read: %w", repo, number, err)
	}
	if int64(len(data)) >= maxDiffBodyBytes {
		slog.Warn("github: diff truncated at size limit", "repo", repo, "pr", number, "limit_bytes", maxDiffBodyBytes)
	}
	return string(data), nil
}
