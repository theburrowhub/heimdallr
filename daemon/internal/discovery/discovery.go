// Package discovery manages automatic repository discovery via GitHub topic tags.
package discovery

import (
	"log/slog"
	"sort"
	"strings"
	"sync"
)

// RepoSearcher is the interface for fetching repos by topic. Satisfied by github.Client.
type RepoSearcher interface {
	FetchReposByTopic(topic string, orgs []string) ([]string, error)
}

// Engine manages topic-based repo discovery and merging with static repos.
type Engine struct {
	searcher     RepoSearcher
	topic        string
	orgs         []string
	staticRepos  []string
	nonMonitored map[string]struct{}

	mu               sync.RWMutex
	cachedDiscovered []string
	lastCount        int
}

// New creates a discovery engine. If orgs is empty, orgs are inferred from staticRepos.
func New(searcher RepoSearcher, topic string, orgs, staticRepos, nonMonitored []string) *Engine {
	inferredOrgs := orgs
	if len(inferredOrgs) == 0 {
		inferredOrgs = inferOrgs(staticRepos)
	}
	nm := make(map[string]struct{}, len(nonMonitored))
	for _, r := range nonMonitored {
		nm[r] = struct{}{}
	}
	return &Engine{
		searcher:     searcher,
		topic:        topic,
		orgs:         inferredOrgs,
		staticRepos:  staticRepos,
		nonMonitored: nm,
	}
}

// inferOrgs extracts unique org prefixes from "org/repo" strings.
func inferOrgs(repos []string) []string {
	set := make(map[string]struct{})
	for _, r := range repos {
		if idx := strings.IndexByte(r, '/'); idx > 0 {
			set[r[:idx]] = struct{}{}
		}
	}
	orgs := make([]string, 0, len(set))
	for o := range set {
		orgs = append(orgs, o)
	}
	sort.Strings(orgs)
	return orgs
}

// Run executes one discovery cycle: fetch repos by topic, cache the result.
// On API failure, the previous cached list is preserved.
// Thread-safe — called by the discovery scheduler.
func (e *Engine) Run() {
	repos, err := e.searcher.FetchReposByTopic(e.topic, e.orgs)
	if err != nil {
		slog.Warn("discovery: API call failed, keeping cached list", "err", err)
		return
	}

	e.mu.Lock()
	prev := e.lastCount
	e.cachedDiscovered = repos
	e.lastCount = len(repos)
	e.mu.Unlock()

	slog.Info("discovery: cycle complete", "discovered", len(repos), "previous", prev)
	if prev > 0 && len(repos) < prev {
		// Build list of missing repos for the warning
		current := make(map[string]struct{}, len(repos))
		for _, r := range repos {
			current[r] = struct{}{}
		}
		slog.Warn("discovery: repo count decreased", "previous", prev, "current", len(repos))
	}
}

// Repos returns the current effective repo list: (static UNION cached_discovered) MINUS non_monitored.
// Thread-safe — called by the poll function on every tick.
func (e *Engine) Repos() []string {
	e.mu.RLock()
	discovered := e.cachedDiscovered
	e.mu.RUnlock()

	set := make(map[string]struct{}, len(e.staticRepos)+len(discovered))
	for _, r := range e.staticRepos {
		set[r] = struct{}{}
	}
	for _, r := range discovered {
		set[r] = struct{}{}
	}
	// Apply non_monitored blacklist
	for r := range e.nonMonitored {
		delete(set, r)
	}

	result := make([]string, 0, len(set))
	for r := range set {
		result = append(result, r)
	}
	sort.Strings(result)
	return result
}
