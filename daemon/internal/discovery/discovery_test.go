package discovery

import (
	"errors"
	"testing"
)

type mockSearcher struct {
	repos []string
	err   error
}

func (m *mockSearcher) FetchReposByTopic(topic string, orgs []string) ([]string, error) {
	return m.repos, m.err
}

func TestEngine_MergeStaticAndDiscovered(t *testing.T) {
	searcher := &mockSearcher{repos: []string{"org/discovered-1", "org/discovered-2"}}
	e := New(searcher, "review", []string{"org"}, []string{"org/static-1"}, nil)
	e.Run()

	repos := e.Repos()
	if len(repos) != 3 {
		t.Fatalf("Repos() = %v, want 3 items", repos)
	}
	// Should be sorted
	expected := []string{"org/discovered-1", "org/discovered-2", "org/static-1"}
	for i, r := range repos {
		if r != expected[i] {
			t.Errorf("Repos()[%d] = %q, want %q", i, r, expected[i])
		}
	}
}

func TestEngine_NonMonitoredBlacklist(t *testing.T) {
	searcher := &mockSearcher{repos: []string{"org/discovered-1", "org/blacklisted"}}
	e := New(searcher, "review", []string{"org"},
		[]string{"org/static-1", "org/also-blacklisted"},
		[]string{"org/blacklisted", "org/also-blacklisted"})
	e.Run()

	repos := e.Repos()
	if len(repos) != 2 {
		t.Fatalf("Repos() = %v, want 2 items", repos)
	}
	for _, r := range repos {
		if r == "org/blacklisted" || r == "org/also-blacklisted" {
			t.Errorf("Repos() contains blacklisted repo %q", r)
		}
	}
}

func TestEngine_InferOrgsFromStaticRepos(t *testing.T) {
	searcher := &mockSearcher{repos: []string{"freepik/repo-a"}}
	e := New(searcher, "review", nil, // empty orgs — should infer
		[]string{"freepik/repo-1", "theburrowhub/repo-2"}, nil)

	if len(e.orgs) != 2 {
		t.Fatalf("orgs = %v, want 2 inferred orgs", e.orgs)
	}
	// Sorted
	if e.orgs[0] != "freepik" || e.orgs[1] != "theburrowhub" {
		t.Errorf("orgs = %v, want [freepik theburrowhub]", e.orgs)
	}
}

func TestEngine_CacheOnAPIFailure(t *testing.T) {
	searcher := &mockSearcher{repos: []string{"org/repo-1", "org/repo-2"}}
	e := New(searcher, "review", []string{"org"}, nil, nil)
	e.Run() // First run succeeds

	// Now make it fail
	searcher.repos = nil
	searcher.err = errors.New("API error")
	e.Run() // Should keep cached

	repos := e.Repos()
	if len(repos) != 2 {
		t.Fatalf("Repos() after API failure = %v, want 2 cached items", repos)
	}
}

func TestEngine_Deduplication(t *testing.T) {
	searcher := &mockSearcher{repos: []string{"org/repo-1", "org/repo-2"}}
	e := New(searcher, "review", []string{"org"},
		[]string{"org/repo-1", "org/repo-3"}, // repo-1 overlaps
		nil)
	e.Run()

	repos := e.Repos()
	if len(repos) != 3 {
		t.Fatalf("Repos() = %v, want 3 deduplicated items", repos)
	}
}

func TestEngine_NoDiscoveryBeforeRun(t *testing.T) {
	searcher := &mockSearcher{repos: []string{"org/discovered"}}
	e := New(searcher, "review", []string{"org"}, []string{"org/static"}, nil)
	// Don't call Run()

	repos := e.Repos()
	if len(repos) != 1 || repos[0] != "org/static" {
		t.Errorf("Repos() before Run() = %v, want [org/static]", repos)
	}
}

func TestEngine_EmptyStaticAndDiscovered(t *testing.T) {
	searcher := &mockSearcher{repos: []string{}}
	e := New(searcher, "review", []string{"org"}, nil, nil)
	e.Run()

	repos := e.Repos()
	if len(repos) != 0 {
		t.Errorf("Repos() = %v, want empty", repos)
	}
}
