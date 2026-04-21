package main

import (
	"testing"

	"github.com/heimdallm/daemon/internal/config"
	gh "github.com/heimdallm/daemon/internal/github"
)

func TestUpsertDiscoveredRepos_DefaultEnabled(t *testing.T) {
	cfg := &config.Config{}
	cfg.GitHub.Repositories = []string{"a/known"}

	prs := []*gh.PullRequest{
		{RepositoryURL: "https://api.github.com/repos/a/known", Number: 1},
		{RepositoryURL: "https://api.github.com/repos/a/new", Number: 2},
	}
	for _, pr := range prs {
		pr.ResolveRepo()
	}

	added := upsertDiscoveredRepos(cfg, prs)
	if len(added) != 1 || added[0] != "a/new" {
		t.Fatalf("expected a/new added, got %v", added)
	}
	found := false
	for _, r := range cfg.GitHub.Repositories {
		if r == "a/new" {
			found = true
		}
	}
	if !found {
		t.Fatalf("a/new should be appended to Repositories, got %v", cfg.GitHub.Repositories)
	}
}

func TestUpsertDiscoveredRepos_RespectsDisabledFlag(t *testing.T) {
	f := false
	cfg := &config.Config{}
	cfg.GitHub.AutoEnablePROnDiscovery = &f

	prs := []*gh.PullRequest{
		{RepositoryURL: "https://api.github.com/repos/a/new", Number: 1},
	}
	for _, pr := range prs {
		pr.ResolveRepo()
	}

	added := upsertDiscoveredRepos(cfg, prs)
	if len(added) != 1 {
		t.Fatalf("expected 1 added, got %v", added)
	}
	for _, r := range cfg.GitHub.Repositories {
		if r == "a/new" {
			t.Fatal("a/new must not be in Repositories when disabled")
		}
	}
	found := false
	for _, r := range cfg.GitHub.NonMonitored {
		if r == "a/new" {
			found = true
		}
	}
	if !found {
		t.Fatalf("a/new should be in NonMonitored, got %v", cfg.GitHub.NonMonitored)
	}
}

func TestUpsertDiscoveredRepos_SkipsAlreadyKnown(t *testing.T) {
	cfg := &config.Config{}
	cfg.GitHub.Repositories = []string{"a/one"}
	cfg.GitHub.NonMonitored = []string{"a/two"}

	prs := []*gh.PullRequest{
		{RepositoryURL: "https://api.github.com/repos/a/one", Number: 1},
		{RepositoryURL: "https://api.github.com/repos/a/two", Number: 2},
	}
	for _, pr := range prs {
		pr.ResolveRepo()
	}

	added := upsertDiscoveredRepos(cfg, prs)
	if len(added) != 0 {
		t.Fatalf("known repos should not be added, got %v", added)
	}
}

func TestUpsertDiscoveredRepos_IgnoresPRsWithEmptyRepo(t *testing.T) {
	cfg := &config.Config{}
	prs := []*gh.PullRequest{{Number: 42}} // RepositoryURL empty → Repo stays ""
	added := upsertDiscoveredRepos(cfg, prs)
	if len(added) != 0 {
		t.Fatalf("PRs with empty Repo must be ignored, got %v", added)
	}
}
