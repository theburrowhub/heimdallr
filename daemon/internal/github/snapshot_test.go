package github_test

import (
	"net/http"
	"net/http/httptest"
	"testing"

	gh "github.com/heimdallm/daemon/internal/github"
)

func TestGetPRSnapshot(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/repos/org/repo/pulls/7" {
			t.Errorf("path = %q", r.URL.Path)
		}
		_, _ = w.Write([]byte(`{
			"state":"open",
			"draft":true,
			"user":{"login":"alice"},
			"updated_at":"2026-04-22T10:00:00Z",
			"head":{"sha":"deadbeef"}
		}`))
	}))
	defer srv.Close()

	c := gh.NewClient("fake-token", gh.WithBaseURL(srv.URL))
	snap, err := c.GetPRSnapshot("org/repo", 7)
	if err != nil {
		t.Fatalf("GetPRSnapshot: %v", err)
	}
	if snap.State != "open" || !snap.Draft || snap.Author != "alice" || snap.HeadSHA != "deadbeef" {
		t.Errorf("snapshot = %+v", snap)
	}
}
