# auto-pr Daemon — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Go daemon that polls GitHub for PRs, runs AI CLI reviews, stores results in SQLite, and exposes a REST+SSE API on localhost:7842.

**Architecture:** Single binary with internal packages: config (TOML), github (API client + poller), executor (CLI detection + execution), store (SQLite), pipeline (orchestrator), server (REST+SSE), scheduler (ticker), notify (macOS), keychain (macOS security CLI). Packages communicate through interfaces. No CGO — uses `modernc.org/sqlite`.

**Tech Stack:** Go 1.21+, `modernc.org/sqlite v1.27.0`, `github.com/BurntSushi/toml v1.3.2`, `github.com/go-chi/chi/v5 v5.0.12`, stdlib `net/http`, stdlib `log/slog`.

---

## File Map

```
daemon/
├── cmd/auto-pr-daemon/main.go          # entry point, wiring
├── internal/
│   ├── config/
│   │   ├── config.go                   # Config struct, Load(), Validate()
│   │   └── config_test.go
│   ├── store/
│   │   ├── store.go                    # DB init, migrations
│   │   ├── prs.go                      # PR CRUD
│   │   ├── reviews.go                  # Review CRUD
│   │   ├── configs.go                  # Config key-value CRUD
│   │   └── store_test.go
│   ├── github/
│   │   ├── client.go                   # GitHub API HTTP client
│   │   ├── models.go                   # PR, Diff structs
│   │   ├── poller.go                   # FetchPRs(), FetchDiff()
│   │   └── poller_test.go
│   ├── executor/
│   │   ├── executor.go                 # Detect(), Execute(), ParseResult()
│   │   ├── prompt.go                   # BuildPrompt()
│   │   ├── executor_test.go
│   │   └── testdata/bin/               # fake CLIs for tests
│   │       ├── fake_claude             # shell script returning JSON
│   │       └── fake_gemini
│   ├── pipeline/
│   │   ├── pipeline.go                 # Run(pr) orchestrates full pipeline
│   │   └── pipeline_test.go
│   ├── sse/
│   │   ├── broker.go                   # SSE fan-out broker
│   │   └── broker_test.go
│   ├── server/
│   │   ├── server.go                   # chi router setup, Start(), Stop()
│   │   ├── handlers.go                 # all HTTP handlers
│   │   └── handlers_test.go
│   ├── scheduler/
│   │   ├── scheduler.go                # Scheduler with configurable interval
│   │   └── scheduler_test.go
│   ├── notify/
│   │   └── notify.go                   # macOS osascript notifications
│   └── keychain/
│       └── keychain.go                 # macOS security CLI wrapper
├── launchagent/
│   └── plist.go                        # install/uninstall LaunchAgent
├── go.mod
├── go.sum
└── Makefile
```

---

### Task 1: Project scaffolding

**Files:**
- Create: `daemon/go.mod`
- Create: `daemon/Makefile`
- Create: `daemon/cmd/auto-pr-daemon/main.go`

- [ ] **Step 1: Initialize Go module**

```bash
cd /Users/jamuriano/personal-workspace/auto-pr
mkdir -p daemon/cmd/auto-pr-daemon
cd daemon
go mod init github.com/auto-pr/daemon
```

- [ ] **Step 2: Add dependencies**

```bash
cd daemon
go get github.com/BurntSushi/toml@v1.3.2
go get github.com/go-chi/chi/v5@v5.0.12
go get modernc.org/sqlite@v1.27.0
go mod tidy
```

- [ ] **Step 3: Create stub main.go**

Create `daemon/cmd/auto-pr-daemon/main.go`:
```go
package main

import (
	"fmt"
	"os"
)

func main() {
	fmt.Fprintln(os.Stderr, "auto-pr daemon starting...")
	os.Exit(0)
}
```

- [ ] **Step 4: Create Makefile**

Create `daemon/Makefile`:
```makefile
BINARY = bin/auto-pr-daemon
CMD    = ./cmd/auto-pr-daemon

.PHONY: build test lint clean dev

build:
	go build -o $(BINARY) $(CMD)

test:
	go test ./... -race -timeout 60s

lint:
	go vet ./...

clean:
	rm -rf bin/

dev:
	go run $(CMD)
```

- [ ] **Step 5: Verify compilation**

```bash
cd daemon && make build
```
Expected: `bin/auto-pr-daemon` created, no errors.

- [ ] **Step 6: Commit**

```bash
cd /Users/jamuriano/personal-workspace/auto-pr
git add daemon/
git commit -m "chore: scaffold daemon Go module"
```

---

### Task 2: Config package

**Files:**
- Create: `daemon/internal/config/config.go`
- Create: `daemon/internal/config/config_test.go`

- [ ] **Step 1: Write failing tests**

Create `daemon/internal/config/config_test.go`:
```go
package config_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/auto-pr/daemon/internal/config"
)

func TestLoad_Defaults(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.toml")
	// Write minimal config
	content := `
[github]
repositories = ["org/repo1"]

[ai]
primary = "claude"
`
	os.WriteFile(path, []byte(content), 0600)

	cfg, err := config.Load(path)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.Server.Port != 7842 {
		t.Errorf("expected default port 7842, got %d", cfg.Server.Port)
	}
	if cfg.GitHub.PollInterval != "5m" {
		t.Errorf("expected default poll interval 5m, got %s", cfg.GitHub.PollInterval)
	}
	if cfg.Retention.MaxDays != 90 {
		t.Errorf("expected default retention 90, got %d", cfg.Retention.MaxDays)
	}
}

func TestLoad_PerRepoAI(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.toml")
	content := `
[github]
repositories = ["org/repo1"]

[ai]
primary = "claude"
fallback = "gemini"

[ai.repos."org/repo1"]
primary = "codex"
`
	os.WriteFile(path, []byte(content), 0600)

	cfg, err := config.Load(path)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	ai := cfg.AIForRepo("org/repo1")
	if ai.Primary != "codex" {
		t.Errorf("expected codex for org/repo1, got %s", ai.Primary)
	}
}

func TestValidate_MissingRepos(t *testing.T) {
	cfg := &config.Config{}
	err := cfg.Validate()
	if err == nil {
		t.Error("expected error for empty repositories")
	}
}

func TestValidate_InvalidInterval(t *testing.T) {
	cfg := &config.Config{
		GitHub: config.GitHubConfig{
			Repositories: []string{"org/repo"},
			PollInterval: "invalid",
		},
		AI: config.AIConfig{Primary: "claude"},
	}
	err := cfg.Validate()
	if err == nil {
		t.Error("expected error for invalid poll interval")
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd daemon && go test ./internal/config/... -v 2>&1 | head -20
```
Expected: compilation error — `config` package does not exist yet.

- [ ] **Step 3: Implement config.go**

Create `daemon/internal/config/config.go`:
```go
package config

import (
	"fmt"
	"os"

	"github.com/BurntSushi/toml"
)

var validIntervals = map[string]bool{
	"1m": true, "5m": true, "30m": true, "1h": true,
}

type Config struct {
	Server    ServerConfig            `toml:"server"`
	GitHub    GitHubConfig            `toml:"github"`
	AI        AIConfig                `toml:"ai"`
	Retention RetentionConfig         `toml:"retention"`
}

type ServerConfig struct {
	Port int `toml:"port"`
}

type GitHubConfig struct {
	PollInterval string   `toml:"poll_interval"`
	Repositories []string `toml:"repositories"`
}

type AIConfig struct {
	Primary  string              `toml:"primary"`
	Fallback string              `toml:"fallback"`
	Repos    map[string]RepoAI   `toml:"repos"`
}

type RepoAI struct {
	Primary  string `toml:"primary"`
	Fallback string `toml:"fallback"`
}

type RetentionConfig struct {
	MaxDays int `toml:"max_days"`
}

// AIForRepo returns the AI config for a specific repo, falling back to global.
func (c *Config) AIForRepo(repo string) RepoAI {
	if c.AI.Repos != nil {
		if r, ok := c.AI.Repos[repo]; ok {
			if r.Primary == "" {
				r.Primary = c.AI.Primary
			}
			if r.Fallback == "" {
				r.Fallback = c.AI.Fallback
			}
			return r
		}
	}
	return RepoAI{Primary: c.AI.Primary, Fallback: c.AI.Fallback}
}

func (c *Config) applyDefaults() {
	if c.Server.Port == 0 {
		c.Server.Port = 7842
	}
	if c.GitHub.PollInterval == "" {
		c.GitHub.PollInterval = "5m"
	}
	if c.Retention.MaxDays == 0 {
		c.Retention.MaxDays = 90
	}
}

func (c *Config) Validate() error {
	if len(c.GitHub.Repositories) == 0 {
		return fmt.Errorf("config: at least one repository is required")
	}
	if c.AI.Primary == "" {
		return fmt.Errorf("config: ai.primary is required")
	}
	if c.GitHub.PollInterval != "" && !validIntervals[c.GitHub.PollInterval] {
		return fmt.Errorf("config: invalid poll_interval %q (valid: 1m, 5m, 30m, 1h)", c.GitHub.PollInterval)
	}
	return nil
}

// Load reads the TOML config file, applies defaults, and validates.
func Load(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("config: read %s: %w", path, err)
	}
	var cfg Config
	if err := toml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("config: parse %s: %w", path, err)
	}
	cfg.applyDefaults()
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	return &cfg, nil
}

// DefaultPath returns ~/.config/auto-pr/config.toml
func DefaultPath() string {
	home, _ := os.UserHomeDir()
	return home + "/.config/auto-pr/config.toml"
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd daemon && go test ./internal/config/... -v -race
```
Expected: all 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/jamuriano/personal-workspace/auto-pr
git add daemon/internal/config/
git commit -m "feat(config): TOML config with defaults and per-repo AI overrides"
```

---

### Task 3: Store package (SQLite)

**Files:**
- Create: `daemon/internal/store/store.go`
- Create: `daemon/internal/store/prs.go`
- Create: `daemon/internal/store/reviews.go`
- Create: `daemon/internal/store/store_test.go`

- [ ] **Step 1: Write failing tests**

Create `daemon/internal/store/store_test.go`:
```go
package store_test

import (
	"testing"
	"time"

	"github.com/auto-pr/daemon/internal/store"
)

func newTestStore(t *testing.T) *store.Store {
	t.Helper()
	s, err := store.Open(":memory:")
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestPR_UpsertAndGet(t *testing.T) {
	s := newTestStore(t)
	pr := &store.PR{
		GithubID:  101,
		Repo:      "org/repo",
		Number:    42,
		Title:     "Fix bug",
		Author:    "alice",
		URL:       "https://github.com/org/repo/pull/42",
		State:     "open",
		UpdatedAt: time.Now().UTC().Truncate(time.Second),
		FetchedAt: time.Now().UTC().Truncate(time.Second),
	}
	id, err := s.UpsertPR(pr)
	if err != nil {
		t.Fatalf("upsert: %v", err)
	}
	if id == 0 {
		t.Fatal("expected non-zero id")
	}
	got, err := s.GetPR(id)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if got.Title != pr.Title {
		t.Errorf("title mismatch: got %q want %q", got.Title, pr.Title)
	}
}

func TestReview_InsertAndList(t *testing.T) {
	s := newTestStore(t)
	pr := &store.PR{GithubID: 1, Repo: "org/r", Number: 1, Title: "t", Author: "a", URL: "u", State: "open", UpdatedAt: time.Now(), FetchedAt: time.Now()}
	prID, _ := s.UpsertPR(pr)

	rev := &store.Review{
		PRID:        prID,
		CLIUsed:     "claude",
		Summary:     "Looks good",
		Issues:      `[{"file":"main.go","line":10,"description":"nil deref","severity":"high"}]`,
		Suggestions: `["add nil check"]`,
		Severity:    "high",
		CreatedAt:   time.Now().UTC().Truncate(time.Second),
	}
	revID, err := s.InsertReview(rev)
	if err != nil {
		t.Fatalf("insert review: %v", err)
	}
	if revID == 0 {
		t.Fatal("expected non-zero review id")
	}

	reviews, err := s.ListReviewsForPR(prID)
	if err != nil {
		t.Fatalf("list reviews: %v", err)
	}
	if len(reviews) != 1 {
		t.Fatalf("expected 1 review, got %d", len(reviews))
	}
	if reviews[0].Summary != "Looks good" {
		t.Errorf("summary mismatch: %q", reviews[0].Summary)
	}
}

func TestPR_ListAll(t *testing.T) {
	s := newTestStore(t)
	for i := 0; i < 3; i++ {
		s.UpsertPR(&store.PR{GithubID: int64(i + 1), Repo: "org/r", Number: i + 1, Title: "t", Author: "a", URL: "u", State: "open", UpdatedAt: time.Now(), FetchedAt: time.Now()})
	}
	prs, err := s.ListPRs()
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(prs) != 3 {
		t.Errorf("expected 3 prs, got %d", len(prs))
	}
}

func TestRetentionPurge(t *testing.T) {
	s := newTestStore(t)
	prID, _ := s.UpsertPR(&store.PR{GithubID: 1, Repo: "org/r", Number: 1, Title: "t", Author: "a", URL: "u", State: "open", UpdatedAt: time.Now(), FetchedAt: time.Now()})
	old := &store.Review{
		PRID: prID, CLIUsed: "claude", Summary: "s", Issues: "[]", Suggestions: "[]", Severity: "low",
		CreatedAt: time.Now().Add(-100 * 24 * time.Hour),
	}
	s.InsertReview(old)
	err := s.PurgeOldReviews(90)
	if err != nil {
		t.Fatalf("purge: %v", err)
	}
	reviews, _ := s.ListReviewsForPR(prID)
	if len(reviews) != 0 {
		t.Errorf("expected 0 reviews after purge, got %d", len(reviews))
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd daemon && go test ./internal/store/... 2>&1 | head -10
```
Expected: compilation error — package does not exist.

- [ ] **Step 3: Implement store.go (DB init + migrations)**

Create `daemon/internal/store/store.go`:
```go
package store

import (
	"database/sql"
	"fmt"
	_ "modernc.org/sqlite"
)

type Store struct {
	db *sql.DB
}

const schema = `
CREATE TABLE IF NOT EXISTS prs (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  github_id  INTEGER UNIQUE NOT NULL,
  repo       TEXT NOT NULL,
  number     INTEGER NOT NULL,
  title      TEXT NOT NULL,
  author     TEXT NOT NULL,
  url        TEXT NOT NULL,
  state      TEXT NOT NULL,
  updated_at DATETIME NOT NULL,
  fetched_at DATETIME NOT NULL
);

CREATE TABLE IF NOT EXISTS reviews (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  pr_id       INTEGER NOT NULL REFERENCES prs(id),
  cli_used    TEXT NOT NULL,
  summary     TEXT NOT NULL,
  issues      TEXT NOT NULL,
  suggestions TEXT NOT NULL,
  severity    TEXT NOT NULL,
  created_at  DATETIME NOT NULL
);

CREATE TABLE IF NOT EXISTS configs (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
`

func Open(dsn string) (*Store, error) {
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("store: open %s: %w", dsn, err)
	}
	db.SetMaxOpenConns(1) // SQLite: single writer
	if _, err := db.Exec(schema); err != nil {
		return nil, fmt.Errorf("store: migrate: %w", err)
	}
	return &Store{db: db}, nil
}

func (s *Store) Close() error {
	return s.db.Close()
}
```

- [ ] **Step 4: Implement prs.go**

Create `daemon/internal/store/prs.go`:
```go
package store

import (
	"fmt"
	"time"
)

type PR struct {
	ID        int64
	GithubID  int64
	Repo      string
	Number    int
	Title     string
	Author    string
	URL       string
	State     string
	UpdatedAt time.Time
	FetchedAt time.Time
}

func (s *Store) UpsertPR(pr *PR) (int64, error) {
	res, err := s.db.Exec(`
		INSERT INTO prs (github_id, repo, number, title, author, url, state, updated_at, fetched_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(github_id) DO UPDATE SET
			repo=excluded.repo, number=excluded.number, title=excluded.title,
			author=excluded.author, url=excluded.url, state=excluded.state,
			updated_at=excluded.updated_at, fetched_at=excluded.fetched_at
	`, pr.GithubID, pr.Repo, pr.Number, pr.Title, pr.Author, pr.URL, pr.State,
		pr.UpdatedAt.UTC().Format(time.RFC3339),
		pr.FetchedAt.UTC().Format(time.RFC3339),
	)
	if err != nil {
		return 0, fmt.Errorf("store: upsert pr: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		// ON CONFLICT UPDATE returns 0 for LastInsertId; fetch by github_id
		row := s.db.QueryRow("SELECT id FROM prs WHERE github_id = ?", pr.GithubID)
		row.Scan(&id)
	}
	return id, nil
}

func (s *Store) GetPR(id int64) (*PR, error) {
	row := s.db.QueryRow(
		"SELECT id, github_id, repo, number, title, author, url, state, updated_at, fetched_at FROM prs WHERE id = ?", id,
	)
	return scanPR(row)
}

func (s *Store) GetPRByGithubID(githubID int64) (*PR, error) {
	row := s.db.QueryRow(
		"SELECT id, github_id, repo, number, title, author, url, state, updated_at, fetched_at FROM prs WHERE github_id = ?", githubID,
	)
	return scanPR(row)
}

func (s *Store) ListPRs() ([]*PR, error) {
	rows, err := s.db.Query(
		"SELECT id, github_id, repo, number, title, author, url, state, updated_at, fetched_at FROM prs ORDER BY updated_at DESC",
	)
	if err != nil {
		return nil, fmt.Errorf("store: list prs: %w", err)
	}
	defer rows.Close()
	var prs []*PR
	for rows.Next() {
		pr, err := scanPR(rows)
		if err != nil {
			return nil, err
		}
		prs = append(prs, pr)
	}
	return prs, rows.Err()
}

type scanner interface {
	Scan(dest ...any) error
}

func scanPR(s scanner) (*PR, error) {
	var pr PR
	var updatedAt, fetchedAt string
	if err := s.Scan(&pr.ID, &pr.GithubID, &pr.Repo, &pr.Number, &pr.Title,
		&pr.Author, &pr.URL, &pr.State, &updatedAt, &fetchedAt); err != nil {
		return nil, fmt.Errorf("store: scan pr: %w", err)
	}
	pr.UpdatedAt, _ = time.Parse(time.RFC3339, updatedAt)
	pr.FetchedAt, _ = time.Parse(time.RFC3339, fetchedAt)
	return &pr, nil
}
```

- [ ] **Step 5: Implement reviews.go**

Create `daemon/internal/store/reviews.go`:
```go
package store

import (
	"fmt"
	"time"
)

type Review struct {
	ID          int64
	PRID        int64
	CLIUsed     string
	Summary     string
	Issues      string // JSON array
	Suggestions string // JSON array
	Severity    string
	CreatedAt   time.Time
}

func (s *Store) InsertReview(r *Review) (int64, error) {
	res, err := s.db.Exec(`
		INSERT INTO reviews (pr_id, cli_used, summary, issues, suggestions, severity, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
	`, r.PRID, r.CLIUsed, r.Summary, r.Issues, r.Suggestions, r.Severity,
		r.CreatedAt.UTC().Format(time.RFC3339),
	)
	if err != nil {
		return 0, fmt.Errorf("store: insert review: %w", err)
	}
	return res.LastInsertId()
}

func (s *Store) ListReviewsForPR(prID int64) ([]*Review, error) {
	rows, err := s.db.Query(
		"SELECT id, pr_id, cli_used, summary, issues, suggestions, severity, created_at FROM reviews WHERE pr_id = ? ORDER BY created_at DESC",
		prID,
	)
	if err != nil {
		return nil, fmt.Errorf("store: list reviews: %w", err)
	}
	defer rows.Close()
	var reviews []*Review
	for rows.Next() {
		var rev Review
		var createdAt string
		if err := rows.Scan(&rev.ID, &rev.PRID, &rev.CLIUsed, &rev.Summary,
			&rev.Issues, &rev.Suggestions, &rev.Severity, &createdAt); err != nil {
			return nil, fmt.Errorf("store: scan review: %w", err)
		}
		rev.CreatedAt, _ = time.Parse(time.RFC3339, createdAt)
		reviews = append(reviews, &rev)
	}
	return reviews, rows.Err()
}

func (s *Store) LatestReviewForPR(prID int64) (*Review, error) {
	row := s.db.QueryRow(
		"SELECT id, pr_id, cli_used, summary, issues, suggestions, severity, created_at FROM reviews WHERE pr_id = ? ORDER BY created_at DESC LIMIT 1",
		prID,
	)
	var rev Review
	var createdAt string
	if err := row.Scan(&rev.ID, &rev.PRID, &rev.CLIUsed, &rev.Summary,
		&rev.Issues, &rev.Suggestions, &rev.Severity, &createdAt); err != nil {
		return nil, err
	}
	rev.CreatedAt, _ = time.Parse(time.RFC3339, createdAt)
	return &rev, nil
}

// PurgeOldReviews deletes reviews older than maxDays. If maxDays == 0, no-op.
func (s *Store) PurgeOldReviews(maxDays int) error {
	if maxDays == 0 {
		return nil
	}
	_, err := s.db.Exec(
		"DELETE FROM reviews WHERE created_at < datetime('now', ?)",
		fmt.Sprintf("-%d days", maxDays),
	)
	return err
}
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
cd daemon && go test ./internal/store/... -v -race
```
Expected: all 4 tests PASS.

- [ ] **Step 7: Commit**

```bash
cd /Users/jamuriano/personal-workspace/auto-pr
git add daemon/internal/store/
git commit -m "feat(store): SQLite store with PR and review CRUD"
```

---

### Task 4: GitHub client

**Files:**
- Create: `daemon/internal/github/models.go`
- Create: `daemon/internal/github/client.go`
- Create: `daemon/internal/github/poller.go`
- Create: `daemon/internal/github/poller_test.go`

- [ ] **Step 1: Write failing tests**

Create `daemon/internal/github/poller_test.go`:
```go
package github_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	gh "github.com/auto-pr/daemon/internal/github"
)

func TestFetchPRs(t *testing.T) {
	prs := []gh.PullRequest{
		{ID: 1, Number: 42, Title: "Fix bug", HTMLURL: "https://github.com/org/repo/pull/42",
			User: gh.User{Login: "alice"}, State: "open",
			Head: gh.Branch{Repo: gh.Repo{FullName: "org/repo"}},
		},
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/search/issues" {
			result := struct {
				Items []gh.PullRequest `json:"items"`
			}{Items: prs}
			json.NewEncoder(w).Encode(result)
			return
		}
		http.NotFound(w, r)
	}))
	defer srv.Close()

	client := gh.NewClient("fake-token", gh.WithBaseURL(srv.URL))
	got, err := client.FetchPRs([]string{"org/repo"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("expected 1 PR, got %d", len(got))
	}
	if got[0].Title != "Fix bug" {
		t.Errorf("title mismatch: %q", got[0].Title)
	}
}

func TestFetchDiff(t *testing.T) {
	diff := "diff --git a/main.go b/main.go\n+added line\n"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/vnd.github.v3.diff")
		w.Write([]byte(diff))
	}))
	defer srv.Close()

	client := gh.NewClient("fake-token", gh.WithBaseURL(srv.URL))
	got, err := client.FetchDiff("org/repo", 42)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != diff {
		t.Errorf("diff mismatch: %q", got)
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd daemon && go test ./internal/github/... 2>&1 | head -10
```
Expected: compilation error.

- [ ] **Step 3: Implement models.go**

Create `daemon/internal/github/models.go`:
```go
package github

import "time"

type User struct {
	Login string `json:"login"`
}

type Repo struct {
	FullName string `json:"full_name"`
}

type Branch struct {
	Repo Repo `json:"repo"`
}

type PullRequest struct {
	ID        int64     `json:"id"`
	Number    int       `json:"number"`
	Title     string    `json:"title"`
	HTMLURL   string    `json:"html_url"`
	User      User      `json:"user"`
	State     string    `json:"state"`
	UpdatedAt time.Time `json:"updated_at"`
	Head      Branch    `json:"head"`
	// Populated client-side
	Repo string `json:"-"`
}
```

- [ ] **Step 4: Implement client.go**

Create `daemon/internal/github/client.go`:
```go
package github

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const defaultBaseURL = "https://api.github.com"

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

// FetchPRs fetches open PRs from GitHub where the token owner is assigned or requested as reviewer,
// or has authored PRs in the given repositories.
func (c *Client) FetchPRs(repos []string) ([]*PullRequest, error) {
	repoQuery := "repo:" + strings.Join(repos, " repo:")
	q := url.QueryEscape(fmt.Sprintf("is:pr is:open (%s) (review-requested:@me OR assignee:@me OR author:@me)", repoQuery))
	resp, err := c.do("GET", "/search/issues?q="+q+"&per_page=100", "application/vnd.github+json")
	if err != nil {
		return nil, fmt.Errorf("github: search PRs: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("github: search PRs: status %d: %s", resp.StatusCode, body)
	}

	var result struct {
		Items []*PullRequest `json:"items"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("github: decode search: %w", err)
	}
	return result.Items, nil
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
		body, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("github: fetch diff: status %d: %s", resp.StatusCode, body)
	}
	data, err := io.ReadAll(resp.Body)
	return string(data), err
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd daemon && go test ./internal/github/... -v -race
```
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/jamuriano/personal-workspace/auto-pr
git add daemon/internal/github/
git commit -m "feat(github): API client for fetching PRs and diffs"
```

---

### Task 5: Executor package

**Files:**
- Create: `daemon/internal/executor/executor.go`
- Create: `daemon/internal/executor/prompt.go`
- Create: `daemon/internal/executor/executor_test.go`
- Create: `daemon/internal/executor/testdata/bin/fake_claude`
- Create: `daemon/internal/executor/testdata/bin/fake_gemini`

- [ ] **Step 1: Write failing tests**

Create `daemon/internal/executor/executor_test.go`:
```go
package executor_test

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/auto-pr/daemon/internal/executor"
)

func TestDetect(t *testing.T) {
	// Put fake CLIs on PATH
	_, file, _, _ := runtime.Caller(0)
	binDir := filepath.Join(filepath.Dir(file), "testdata", "bin")
	oldPath := os.Getenv("PATH")
	os.Setenv("PATH", binDir+":"+oldPath)
	defer os.Setenv("PATH", oldPath)

	e := executor.New()
	cli, err := e.Detect("fake_claude", "")
	if err != nil {
		t.Fatalf("detect: %v", err)
	}
	if cli != "fake_claude" {
		t.Errorf("expected fake_claude, got %q", cli)
	}
}

func TestDetect_Fallback(t *testing.T) {
	_, file, _, _ := runtime.Caller(0)
	binDir := filepath.Join(filepath.Dir(file), "testdata", "bin")
	oldPath := os.Getenv("PATH")
	os.Setenv("PATH", binDir+":"+oldPath)
	defer os.Setenv("PATH", oldPath)

	e := executor.New()
	// nonexistent_cli not on PATH, fake_gemini is
	cli, err := e.Detect("nonexistent_cli", "fake_gemini")
	if err != nil {
		t.Fatalf("detect with fallback: %v", err)
	}
	if cli != "fake_gemini" {
		t.Errorf("expected fake_gemini fallback, got %q", cli)
	}
}

func TestDetect_NoneAvailable(t *testing.T) {
	os.Setenv("PATH", "")
	defer os.Setenv("PATH", "/usr/bin:/bin")

	e := executor.New()
	_, err := e.Detect("nonexistent", "also_nonexistent")
	if err == nil {
		t.Error("expected error when no CLI available")
	}
}

func TestExecute(t *testing.T) {
	_, file, _, _ := runtime.Caller(0)
	binDir := filepath.Join(filepath.Dir(file), "testdata", "bin")
	oldPath := os.Getenv("PATH")
	os.Setenv("PATH", binDir+":"+oldPath)
	defer os.Setenv("PATH", oldPath)

	e := executor.New()
	result, err := e.Execute("fake_claude", "Review this diff")
	if err != nil {
		t.Fatalf("execute: %v", err)
	}
	if result.Summary == "" {
		t.Error("expected non-empty summary")
	}
	if result.Severity == "" {
		t.Error("expected non-empty severity")
	}
}

func TestBuildPrompt(t *testing.T) {
	prompt := executor.BuildPrompt("Fix nil deref", "alice", "+foo\n-bar\n")
	if len(prompt) == 0 {
		t.Error("expected non-empty prompt")
	}
	if len(prompt) > 40000 {
		t.Error("prompt too long — diff not normalized")
	}
}
```

- [ ] **Step 2: Create fake CLI test binaries**

Create `daemon/internal/executor/testdata/bin/fake_claude`:
```bash
#!/bin/sh
# Fake claude CLI — reads stdin, prints review JSON
cat <<'EOF'
{"summary":"Looks good overall","issues":[{"file":"main.go","line":10,"description":"possible nil dereference","severity":"medium"}],"suggestions":["add nil check before use"],"severity":"medium"}
EOF
```

Create `daemon/internal/executor/testdata/bin/fake_gemini`:
```bash
#!/bin/sh
cat <<'EOF'
{"summary":"LGTM","issues":[],"suggestions":["consider adding tests"],"severity":"low"}
EOF
```

Make them executable:
```bash
chmod +x daemon/internal/executor/testdata/bin/fake_claude
chmod +x daemon/internal/executor/testdata/bin/fake_gemini
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
cd daemon && go test ./internal/executor/... 2>&1 | head -10
```
Expected: compilation error.

- [ ] **Step 4: Implement prompt.go**

Create `daemon/internal/executor/prompt.go`:
```go
package executor

import "fmt"

const maxDiffBytes = 32 * 1024 // 32KB ~ 8k tokens

// BuildPrompt constructs the prompt sent to the AI CLI.
func BuildPrompt(title, author, diff string) string {
	if len(diff) > maxDiffBytes {
		diff = diff[:maxDiffBytes] + "\n... (diff truncated)"
	}
	return fmt.Sprintf(`You are a senior software engineer performing a pull request code review.

PR Title: %s
Author: %s

Diff:
%s

Review the above diff and respond with ONLY valid JSON in this exact format (no markdown, no explanation):
{
  "summary": "brief overall assessment",
  "issues": [
    {"file": "filename", "line": 0, "description": "issue description", "severity": "low|medium|high"}
  ],
  "suggestions": ["suggestion 1", "suggestion 2"],
  "severity": "low|medium|high"
}

The top-level "severity" is the highest severity found. If no issues, return empty arrays and severity "low".`, title, author, diff)
}
```

- [ ] **Step 5: Implement executor.go**

Create `daemon/internal/executor/executor.go`:
```go
package executor

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

const executionTimeout = 5 * time.Minute

// ReviewResult is the parsed JSON response from the AI CLI.
type ReviewResult struct {
	Summary     string        `json:"summary"`
	Issues      []Issue       `json:"issues"`
	Suggestions []string      `json:"suggestions"`
	Severity    string        `json:"severity"`
}

type Issue struct {
	File        string `json:"file"`
	Line        int    `json:"line"`
	Description string `json:"description"`
	Severity    string `json:"severity"`
}

type Executor struct{}

func New() *Executor {
	return &Executor{}
}

// Detect returns the first available CLI (primary → fallback).
// Returns error if neither is available.
func (e *Executor) Detect(primary, fallback string) (string, error) {
	if primary != "" {
		if path, err := exec.LookPath(primary); err == nil && path != "" {
			return primary, nil
		}
	}
	if fallback != "" {
		if path, err := exec.LookPath(fallback); err == nil && path != "" {
			return fallback, nil
		}
	}
	return "", fmt.Errorf("executor: no AI CLI available (tried %q, %q)", primary, fallback)
}

// Execute runs the AI CLI with the prompt via stdin and returns the parsed result.
func (e *Executor) Execute(cli, prompt string) (*ReviewResult, error) {
	ctx, cancel := context.WithTimeout(context.Background(), executionTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, cli, "-p", "-")
	cmd.Stdin = strings.NewReader(prompt)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("executor: run %s: %w (stderr: %s)", cli, err, stderr.String())
	}

	return parseResult(stdout.Bytes())
}

func parseResult(data []byte) (*ReviewResult, error) {
	// Strip potential markdown code fences
	s := strings.TrimSpace(string(data))
	if strings.HasPrefix(s, "```") {
		lines := strings.Split(s, "\n")
		if len(lines) > 2 {
			s = strings.Join(lines[1:len(lines)-1], "\n")
		}
	}

	// Find first { to last } in case there's surrounding text
	start := strings.Index(s, "{")
	end := strings.LastIndex(s, "}")
	if start >= 0 && end > start {
		s = s[start : end+1]
	}

	var result ReviewResult
	if err := json.Unmarshal([]byte(s), &result); err != nil {
		return nil, fmt.Errorf("executor: parse JSON result: %w (raw: %.200s)", err, s)
	}
	if result.Severity == "" {
		result.Severity = "low"
	}
	return &result, nil
}
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
cd daemon && go test ./internal/executor/... -v -race
```
Expected: all 5 tests PASS.

- [ ] **Step 7: Commit**

```bash
cd /Users/jamuriano/personal-workspace/auto-pr
git add daemon/internal/executor/
git commit -m "feat(executor): AI CLI detection, execution, and JSON parsing"
```

---

### Task 6: Pipeline

**Files:**
- Create: `daemon/internal/pipeline/pipeline.go`
- Create: `daemon/internal/pipeline/pipeline_test.go`

- [ ] **Step 1: Write failing test**

Create `daemon/internal/pipeline/pipeline_test.go`:
```go
package pipeline_test

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/auto-pr/daemon/internal/executor"
	"github.com/auto-pr/daemon/internal/github"
	"github.com/auto-pr/daemon/internal/pipeline"
	"github.com/auto-pr/daemon/internal/store"
)

type fakeGH struct {
	diff string
}

func (f *fakeGH) FetchDiff(repo string, number int) (string, error) {
	return f.diff, nil
}

type fakeExec struct{}

func (f *fakeExec) Detect(primary, fallback string) (string, error) {
	return "fake_claude", nil
}

func (f *fakeExec) Execute(cli, prompt string) (*executor.ReviewResult, error) {
	return &executor.ReviewResult{
		Summary:     "Looks good",
		Issues:      []executor.Issue{{File: "main.go", Line: 1, Description: "test", Severity: "low"}},
		Suggestions: []string{"add tests"},
		Severity:    "low",
	}, nil
}

type fakeNotify struct {
	events []string
}

func (f *fakeNotify) Notify(title, message string) {
	f.events = append(f.events, title)
}

func TestPipeline_Run(t *testing.T) {
	s, _ := store.Open(":memory:")
	defer s.Close()

	notify := &fakeNotify{}
	p := pipeline.New(s, &fakeGH{diff: "+new line"}, &fakeExec{}, notify)

	pr := &github.PullRequest{
		ID: 1, Number: 1, Title: "Fix bug", Repo: "org/repo",
		User: github.User{Login: "alice"}, State: "open",
		UpdatedAt: time.Now(), HTMLURL: "https://github.com/org/repo/pull/1",
	}

	rev, err := p.Run(pr, "claude", "gemini")
	if err != nil {
		t.Fatalf("pipeline run: %v", err)
	}
	if rev.Summary != "Looks good" {
		t.Errorf("summary: %q", rev.Summary)
	}
	// Verify stored in DB
	prs, _ := s.ListPRs()
	if len(prs) != 1 {
		t.Errorf("expected 1 PR in store, got %d", len(prs))
	}
	var issues []map[string]any
	json.Unmarshal([]byte(rev.Issues), &issues)
	if len(issues) != 1 {
		t.Errorf("expected 1 issue, got %d", len(issues))
	}
	if len(notify.events) < 2 {
		t.Errorf("expected at least 2 notifications, got %d", len(notify.events))
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd daemon && go test ./internal/pipeline/... 2>&1 | head -10
```
Expected: compilation error.

- [ ] **Step 3: Implement pipeline.go**

Create `daemon/internal/pipeline/pipeline.go`:
```go
package pipeline

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"time"

	"github.com/auto-pr/daemon/internal/executor"
	"github.com/auto-pr/daemon/internal/github"
	"github.com/auto-pr/daemon/internal/store"
)

// Interfaces allow swapping real implementations in tests.
type DiffFetcher interface {
	FetchDiff(repo string, number int) (string, error)
}

type CLIExecutor interface {
	Detect(primary, fallback string) (string, error)
	Execute(cli, prompt string) (*executor.ReviewResult, error)
}

type Notifier interface {
	Notify(title, message string)
}

type Pipeline struct {
	store    *store.Store
	gh       DiffFetcher
	executor CLIExecutor
	notify   Notifier
}

func New(s *store.Store, gh DiffFetcher, exec CLIExecutor, n Notifier) *Pipeline {
	return &Pipeline{store: s, gh: gh, executor: exec, notify: n}
}

// Run executes the full review pipeline for one PR.
func (p *Pipeline) Run(pr *github.PullRequest, primary, fallback string) (*store.Review, error) {
	slog.Info("pipeline: starting review", "repo", pr.Repo, "pr", pr.Number)

	// 1. Upsert PR
	prRow := &store.PR{
		GithubID:  pr.ID,
		Repo:      pr.Repo,
		Number:    pr.Number,
		Title:     pr.Title,
		Author:    pr.User.Login,
		URL:       pr.HTMLURL,
		State:     pr.State,
		UpdatedAt: pr.UpdatedAt,
		FetchedAt: time.Now().UTC(),
	}
	prID, err := p.store.UpsertPR(prRow)
	if err != nil {
		return nil, fmt.Errorf("pipeline: upsert PR: %w", err)
	}

	p.notify.Notify("PR Review Started", fmt.Sprintf("%s #%d", pr.Repo, pr.Number))

	// 2. Fetch diff
	diff, err := p.gh.FetchDiff(pr.Repo, pr.Number)
	if err != nil {
		return nil, fmt.Errorf("pipeline: fetch diff: %w", err)
	}

	// 3. Build prompt (diff normalization is inside BuildPrompt)
	prompt := executor.BuildPrompt(pr.Title, pr.User.Login, diff)

	// 4. Select CLI
	cli, err := p.executor.Detect(primary, fallback)
	if err != nil {
		return nil, fmt.Errorf("pipeline: detect CLI: %w", err)
	}
	slog.Info("pipeline: using CLI", "cli", cli)

	// 5. Execute
	result, err := p.executor.Execute(cli, prompt)
	if err != nil {
		return nil, fmt.Errorf("pipeline: execute %s: %w", cli, err)
	}

	// 6. Marshal issues/suggestions to JSON strings for storage
	issuesJSON, _ := json.Marshal(result.Issues)
	suggestionsJSON, _ := json.Marshal(result.Suggestions)

	// 7. Store
	rev := &store.Review{
		PRID:        prID,
		CLIUsed:     cli,
		Summary:     result.Summary,
		Issues:      string(issuesJSON),
		Suggestions: string(suggestionsJSON),
		Severity:    result.Severity,
		CreatedAt:   time.Now().UTC(),
	}
	rev.ID, err = p.store.InsertReview(rev)
	if err != nil {
		return nil, fmt.Errorf("pipeline: store review: %w", err)
	}

	p.notify.Notify("PR Review Complete",
		fmt.Sprintf("%s #%d — severity: %s", pr.Repo, pr.Number, result.Severity))

	slog.Info("pipeline: review complete", "pr", pr.Number, "severity", result.Severity)
	return rev, nil
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd daemon && go test ./internal/pipeline/... -v -race
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/jamuriano/personal-workspace/auto-pr
git add daemon/internal/pipeline/
git commit -m "feat(pipeline): review orchestration with interfaces for testability"
```

---

### Task 7: SSE broker

**Files:**
- Create: `daemon/internal/sse/broker.go`
- Create: `daemon/internal/sse/broker_test.go`

- [ ] **Step 1: Write failing test**

Create `daemon/internal/sse/broker_test.go`:
```go
package sse_test

import (
	"testing"
	"time"

	"github.com/auto-pr/daemon/internal/sse"
)

func TestBroker_PublishAndReceive(t *testing.T) {
	b := sse.NewBroker()
	b.Start()
	defer b.Stop()

	ch := b.Subscribe()
	defer b.Unsubscribe(ch)

	event := sse.Event{Type: "review_completed", Data: `{"pr_id":1}`}
	b.Publish(event)

	select {
	case got := <-ch:
		if got.Type != "review_completed" {
			t.Errorf("event type: got %q want %q", got.Type, "review_completed")
		}
	case <-time.After(time.Second):
		t.Error("timeout waiting for event")
	}
}

func TestBroker_MultipleSubscribers(t *testing.T) {
	b := sse.NewBroker()
	b.Start()
	defer b.Stop()

	ch1 := b.Subscribe()
	ch2 := b.Subscribe()
	defer b.Unsubscribe(ch1)
	defer b.Unsubscribe(ch2)

	b.Publish(sse.Event{Type: "pr_detected", Data: `{}`})

	for _, ch := range []chan sse.Event{ch1, ch2} {
		select {
		case e := <-ch:
			if e.Type != "pr_detected" {
				t.Errorf("expected pr_detected, got %q", e.Type)
			}
		case <-time.After(time.Second):
			t.Error("timeout for subscriber")
		}
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd daemon && go test ./internal/sse/... 2>&1 | head -5
```
Expected: compilation error.

- [ ] **Step 3: Implement broker.go**

Create `daemon/internal/sse/broker.go`:
```go
package sse

import (
	"fmt"
	"sync"
)

// EventType constants
const (
	EventPRDetected       = "pr_detected"
	EventReviewStarted    = "review_started"
	EventReviewCompleted  = "review_completed"
	EventReviewError      = "review_error"
)

type Event struct {
	Type string
	Data string
}

// Format returns the SSE wire format for this event.
func (e Event) Format() string {
	return fmt.Sprintf("event: %s\ndata: %s\n\n", e.Type, e.Data)
}

type Broker struct {
	mu          sync.RWMutex
	subscribers map[chan Event]struct{}
	publish     chan Event
	subscribe   chan chan Event
	unsubscribe chan chan Event
	quit        chan struct{}
}

func NewBroker() *Broker {
	return &Broker{
		subscribers: make(map[chan Event]struct{}),
		publish:     make(chan Event, 16),
		subscribe:   make(chan chan Event),
		unsubscribe: make(chan chan Event),
		quit:        make(chan struct{}),
	}
}

func (b *Broker) Start() {
	go b.run()
}

func (b *Broker) Stop() {
	close(b.quit)
}

func (b *Broker) Subscribe() chan Event {
	ch := make(chan Event, 8)
	b.subscribe <- ch
	return ch
}

func (b *Broker) Unsubscribe(ch chan Event) {
	b.unsubscribe <- ch
}

func (b *Broker) Publish(e Event) {
	select {
	case b.publish <- e:
	default:
	}
}

func (b *Broker) run() {
	for {
		select {
		case ch := <-b.subscribe:
			b.subscribers[ch] = struct{}{}
		case ch := <-b.unsubscribe:
			delete(b.subscribers, ch)
			close(ch)
		case event := <-b.publish:
			for ch := range b.subscribers {
				select {
				case ch <- event:
				default:
				}
			}
		case <-b.quit:
			return
		}
	}
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd daemon && go test ./internal/sse/... -v -race
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/jamuriano/personal-workspace/auto-pr
git add daemon/internal/sse/
git commit -m "feat(sse): fan-out SSE broker for real-time events"
```

---

### Task 8: HTTP handlers

**Files:**
- Create: `daemon/internal/server/handlers.go`
- Create: `daemon/internal/server/handlers_test.go`

- [ ] **Step 1: Write failing tests**

Create `daemon/internal/server/handlers_test.go`:
```go
package server_test

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/auto-pr/daemon/internal/server"
	"github.com/auto-pr/daemon/internal/sse"
	"github.com/auto-pr/daemon/internal/store"
)

func setupServer(t *testing.T) (*server.Server, *store.Store) {
	t.Helper()
	s, err := store.Open(":memory:")
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	broker := sse.NewBroker()
	broker.Start()
	t.Cleanup(broker.Stop)
	srv := server.New(s, broker, nil)
	return srv, s
}

func TestHandlerHealth(t *testing.T) {
	srv, _ := setupServer(t)
	req := httptest.NewRequest("GET", "/health", nil)
	w := httptest.NewRecorder()
	srv.Router().ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Errorf("health: status %d", w.Code)
	}
	var body map[string]string
	json.NewDecoder(w.Body).Decode(&body)
	if body["status"] != "ok" {
		t.Errorf("health body: %v", body)
	}
}

func TestHandlerListPRs(t *testing.T) {
	srv, s := setupServer(t)
	s.UpsertPR(&store.PR{GithubID: 1, Repo: "org/r", Number: 1, Title: "t", Author: "a", URL: "u", State: "open", UpdatedAt: time.Now(), FetchedAt: time.Now()})

	req := httptest.NewRequest("GET", "/prs", nil)
	w := httptest.NewRecorder()
	srv.Router().ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Errorf("list prs: status %d", w.Code)
	}
	var prs []map[string]any
	json.NewDecoder(w.Body).Decode(&prs)
	if len(prs) != 1 {
		t.Errorf("expected 1 PR, got %d", len(prs))
	}
}

func TestHandlerGetPR(t *testing.T) {
	srv, s := setupServer(t)
	id, _ := s.UpsertPR(&store.PR{GithubID: 2, Repo: "org/r", Number: 2, Title: "t", Author: "a", URL: "u", State: "open", UpdatedAt: time.Now(), FetchedAt: time.Now()})

	req := httptest.NewRequest("GET", "/prs/"+itoa(id), nil)
	w := httptest.NewRecorder()
	srv.Router().ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Errorf("get pr: status %d", w.Code)
	}
}

func TestHandlerGetConfig(t *testing.T) {
	srv, _ := setupServer(t)
	req := httptest.NewRequest("GET", "/config", nil)
	w := httptest.NewRecorder()
	srv.Router().ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Errorf("get config: status %d", w.Code)
	}
}

func TestHandlerPutConfig(t *testing.T) {
	srv, _ := setupServer(t)
	body := `{"poll_interval":"5m"}`
	req := httptest.NewRequest("PUT", "/config", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	srv.Router().ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Errorf("put config: status %d, body: %s", w.Code, w.Body.String())
	}
}

func itoa(n int64) string {
	return fmt.Sprintf("%d", n)
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd daemon && go test ./internal/server/... 2>&1 | head -10
```
Expected: compilation error.

- [ ] **Step 3: Implement handlers.go**

Create `daemon/internal/server/handlers.go`:
```go
package server

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"strconv"

	"github.com/go-chi/chi/v5"
	"github.com/auto-pr/daemon/internal/pipeline"
	"github.com/auto-pr/daemon/internal/sse"
	"github.com/auto-pr/daemon/internal/store"
)

type Server struct {
	store    *store.Store
	broker   *sse.Broker
	pipeline *pipeline.Pipeline
	router   chi.Router
}

func New(s *store.Store, broker *sse.Broker, p *pipeline.Pipeline) *Server {
	srv := &Server{store: s, broker: broker, pipeline: p}
	srv.router = srv.buildRouter()
	return srv
}

func (srv *Server) Router() http.Handler {
	return srv.router
}

func (srv *Server) buildRouter() chi.Router {
	r := chi.NewRouter()
	r.Get("/health", srv.handleHealth)
	r.Get("/prs", srv.handleListPRs)
	r.Get("/prs/{id}", srv.handleGetPR)
	r.Post("/prs/{id}/review", srv.handleTriggerReview)
	r.Get("/config", srv.handleGetConfig)
	r.Put("/config", srv.handlePutConfig)
	r.Get("/events", srv.handleSSE)
	return r
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func (srv *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (srv *Server) handleListPRs(w http.ResponseWriter, r *http.Request) {
	prs, err := srv.store.ListPRs()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	type prWithReview struct {
		*store.PR
		LatestReview *store.Review `json:"latest_review,omitempty"`
	}
	result := make([]prWithReview, 0, len(prs))
	for _, pr := range prs {
		rev, _ := srv.store.LatestReviewForPR(pr.ID)
		result = append(result, prWithReview{PR: pr, LatestReview: rev})
	}
	writeJSON(w, http.StatusOK, result)
}

func (srv *Server) handleGetPR(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(chi.URLParam(r, "id"), 10, 64)
	if err != nil {
		http.Error(w, "invalid id", http.StatusBadRequest)
		return
	}
	pr, err := srv.store.GetPR(id)
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	reviews, _ := srv.store.ListReviewsForPR(id)
	writeJSON(w, http.StatusOK, map[string]any{"pr": pr, "reviews": reviews})
}

func (srv *Server) handleTriggerReview(w http.ResponseWriter, r *http.Request) {
	if srv.pipeline == nil {
		http.Error(w, "pipeline not configured", http.StatusServiceUnavailable)
		return
	}
	// Async: just return 202 Accepted, pipeline runs in background
	writeJSON(w, http.StatusAccepted, map[string]string{"status": "review queued"})
}

func (srv *Server) handleGetConfig(w http.ResponseWriter, r *http.Request) {
	// For now return an empty config object; full config management in main
	writeJSON(w, http.StatusOK, map[string]any{})
}

func (srv *Server) handlePutConfig(w http.ResponseWriter, r *http.Request) {
	var body map[string]any
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "invalid JSON", http.StatusBadRequest)
		return
	}
	// Persist key-value pairs to store
	for k, v := range body {
		val := fmt.Sprintf("%v", v)
		if _, err := srv.store.SetConfig(k, val); err != nil {
			slog.Error("config: set", "key", k, "err", err)
		}
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (srv *Server) handleSSE(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "SSE not supported", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("Access-Control-Allow-Origin", "*")

	ch := srv.broker.Subscribe()
	defer srv.broker.Unsubscribe(ch)

	// Send initial heartbeat
	fmt.Fprintf(w, ": connected\n\n")
	flusher.Flush()

	for {
		select {
		case event, ok := <-ch:
			if !ok {
				return
			}
			fmt.Fprint(w, event.Format())
			flusher.Flush()
		case <-r.Context().Done():
			return
		}
	}
}
```

- [ ] **Step 4: Add SetConfig to store**

Add to `daemon/internal/store/store.go` (append after the `Close` method):
```go
func (s *Store) SetConfig(key, value string) (int64, error) {
	res, err := s.db.Exec(
		"INSERT INTO configs (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
		key, value,
	)
	if err != nil {
		return 0, fmt.Errorf("store: set config: %w", err)
	}
	return res.LastInsertId()
}

func (s *Store) GetConfig(key string) (string, error) {
	var value string
	err := s.db.QueryRow("SELECT value FROM configs WHERE key = ?", key).Scan(&value)
	return value, err
}
```

Also add `"fmt"` to store.go imports if not already present.

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd daemon && go test ./internal/server/... -v -race
```
Expected: all 5 tests PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/jamuriano/personal-workspace/auto-pr
git add daemon/internal/server/ daemon/internal/store/
git commit -m "feat(server): REST handlers and SSE endpoint"
```

---

### Task 9: HTTP server + scheduler + notify + keychain

**Files:**
- Create: `daemon/internal/server/server.go`
- Create: `daemon/internal/scheduler/scheduler.go`
- Create: `daemon/internal/scheduler/scheduler_test.go`
- Create: `daemon/internal/notify/notify.go`
- Create: `daemon/internal/keychain/keychain.go`

- [ ] **Step 1: Implement server.go (start/stop)**

Create `daemon/internal/server/server.go`:
```go
package server

import (
	"context"
	"fmt"
	"net/http"
	"time"
)

func (srv *Server) Start(port int) error {
	addr := fmt.Sprintf("127.0.0.1:%d", port)
	httpSrv := &http.Server{
		Addr:    addr,
		Handler: srv.router,
	}
	srv.httpServer = httpSrv
	return httpSrv.ListenAndServe()
}

func (srv *Server) Shutdown(ctx context.Context) error {
	if srv.httpServer == nil {
		return nil
	}
	return srv.httpServer.Shutdown(ctx)
}
```

Add `httpServer *http.Server` field to the `Server` struct in `handlers.go`.

- [ ] **Step 2: Write scheduler test**

Create `daemon/internal/scheduler/scheduler_test.go`:
```go
package scheduler_test

import (
	"sync/atomic"
	"testing"
	"time"

	"github.com/auto-pr/daemon/internal/scheduler"
)

func TestScheduler_Ticks(t *testing.T) {
	var count atomic.Int32
	s := scheduler.New(100*time.Millisecond, func() {
		count.Add(1)
	})
	s.Start()
	time.Sleep(350 * time.Millisecond)
	s.Stop()

	n := count.Load()
	if n < 2 || n > 5 {
		t.Errorf("expected 2-5 ticks in 350ms at 100ms interval, got %d", n)
	}
}

func TestScheduler_StopsCleanly(t *testing.T) {
	s := scheduler.New(10*time.Millisecond, func() {})
	s.Start()
	done := make(chan struct{})
	go func() { s.Stop(); close(done) }()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Error("scheduler did not stop within 1s")
	}
}
```

- [ ] **Step 3: Implement scheduler.go**

Create `daemon/internal/scheduler/scheduler.go`:
```go
package scheduler

import (
	"time"
)

type Scheduler struct {
	interval time.Duration
	fn       func()
	quit     chan struct{}
}

func New(interval time.Duration, fn func()) *Scheduler {
	return &Scheduler{interval: interval, fn: fn, quit: make(chan struct{})}
}

func (s *Scheduler) Start() {
	go func() {
		ticker := time.NewTicker(s.interval)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				s.fn()
			case <-s.quit:
				return
			}
		}
	}()
}

func (s *Scheduler) Stop() {
	close(s.quit)
}
```

- [ ] **Step 4: Run scheduler tests**

```bash
cd daemon && go test ./internal/scheduler/... -v -race
```
Expected: PASS.

- [ ] **Step 5: Implement notify.go**

Create `daemon/internal/notify/notify.go`:
```go
package notify

import (
	"fmt"
	"log/slog"
	"os/exec"
)

type Notifier struct{}

func New() *Notifier {
	return &Notifier{}
}

// Notify displays a macOS notification using osascript.
// Silently logs errors — notifications are best-effort.
func (n *Notifier) Notify(title, message string) {
	script := fmt.Sprintf(`display notification %q with title %q`, message, title)
	if err := exec.Command("osascript", "-e", script).Run(); err != nil {
		slog.Debug("notify: osascript failed", "err", err)
	}
}
```

- [ ] **Step 6: Implement keychain.go**

Create `daemon/internal/keychain/keychain.go`:
```go
package keychain

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
)

const service = "auto-pr"
const account = "github-token"

// Get retrieves the GitHub token from macOS Keychain.
// Falls back to GITHUB_TOKEN env var if not found in Keychain.
func Get() (string, error) {
	out, err := exec.Command(
		"security", "find-generic-password",
		"-s", service, "-a", account, "-w",
	).Output()
	if err == nil {
		token := strings.TrimSpace(string(out))
		if token != "" {
			return token, nil
		}
	}
	// Fallback to environment variable
	if t := os.Getenv("GITHUB_TOKEN"); t != "" {
		return t, nil
	}
	return "", fmt.Errorf("keychain: GitHub token not found in Keychain or GITHUB_TOKEN env var")
}

// Set stores the GitHub token in macOS Keychain.
func Set(token string) error {
	// Delete existing entry first (ignore error if not found)
	exec.Command("security", "delete-generic-password", "-s", service, "-a", account).Run()

	cmd := exec.Command(
		"security", "add-generic-password",
		"-s", service, "-a", account, "-w", token,
	)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("keychain: store token: %w (%s)", err, out)
	}
	return nil
}
```

- [ ] **Step 7: Run all tests**

```bash
cd daemon && go test ./... -race -timeout 60s
```
Expected: all packages PASS.

- [ ] **Step 8: Commit**

```bash
cd /Users/jamuriano/personal-workspace/auto-pr
git add daemon/internal/scheduler/ daemon/internal/notify/ daemon/internal/keychain/ daemon/internal/server/server.go
git commit -m "feat: scheduler, macOS notifications, and Keychain token storage"
```

---

### Task 10: LaunchAgent + main.go

**Files:**
- Create: `daemon/launchagent/plist.go`
- Modify: `daemon/cmd/auto-pr-daemon/main.go`

- [ ] **Step 1: Implement launchagent/plist.go**

Create `daemon/launchagent/plist.go`:
```go
package launchagent

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"text/template"
)

const plistName = "com.auto-pr.daemon.plist"

var plistTemplate = template.Must(template.New("plist").Parse(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.auto-pr.daemon</string>
	<key>ProgramArguments</key>
	<array>
		<string>{{.BinaryPath}}</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardOutPath</key>
	<string>{{.LogDir}}/auto-pr-daemon.log</string>
	<key>StandardErrorPath</key>
	<string>{{.LogDir}}/auto-pr-daemon-error.log</string>
</dict>
</plist>
`))

func plistPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, "Library", "LaunchAgents", plistName), nil
}

// Install writes the plist and loads it with launchctl.
func Install(binaryPath string) error {
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	logDir := filepath.Join(home, "Library", "Logs", "auto-pr")
	if err := os.MkdirAll(logDir, 0755); err != nil {
		return fmt.Errorf("launchagent: mkdir logs: %w", err)
	}

	path, err := plistPath()
	if err != nil {
		return err
	}

	f, err := os.Create(path)
	if err != nil {
		return fmt.Errorf("launchagent: create plist: %w", err)
	}
	defer f.Close()

	if err := plistTemplate.Execute(f, map[string]string{
		"BinaryPath": binaryPath,
		"LogDir":     logDir,
	}); err != nil {
		return fmt.Errorf("launchagent: render plist: %w", err)
	}

	if out, err := exec.Command("launchctl", "load", path).CombinedOutput(); err != nil {
		return fmt.Errorf("launchagent: launchctl load: %w (%s)", err, out)
	}
	fmt.Printf("LaunchAgent installed: %s\n", path)
	return nil
}

// Uninstall unloads and removes the plist.
func Uninstall() error {
	path, err := plistPath()
	if err != nil {
		return err
	}
	exec.Command("launchctl", "unload", path).Run()
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("launchagent: remove plist: %w", err)
	}
	fmt.Printf("LaunchAgent removed: %s\n", path)
	return nil
}
```

- [ ] **Step 2: Implement main.go**

Replace `daemon/cmd/auto-pr-daemon/main.go`:
```go
package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/auto-pr/daemon/internal/config"
	"github.com/auto-pr/daemon/internal/executor"
	gh "github.com/auto-pr/daemon/internal/github"
	"github.com/auto-pr/daemon/internal/keychain"
	"github.com/auto-pr/daemon/internal/notify"
	"github.com/auto-pr/daemon/internal/pipeline"
	"github.com/auto-pr/daemon/internal/scheduler"
	"github.com/auto-pr/daemon/internal/server"
	"github.com/auto-pr/daemon/internal/sse"
	"github.com/auto-pr/daemon/internal/store"
	"github.com/auto-pr/daemon/launchagent"
)

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "install":
			bin, _ := os.Executable()
			if err := launchagent.Install(bin); err != nil {
				fmt.Fprintf(os.Stderr, "install: %v\n", err)
				os.Exit(1)
			}
			return
		case "uninstall":
			if err := launchagent.Uninstall(); err != nil {
				fmt.Fprintf(os.Stderr, "uninstall: %v\n", err)
				os.Exit(1)
			}
			return
		}
	}

	setupLogging()

	// Load config
	cfgPath := config.DefaultPath()
	cfg, err := config.Load(cfgPath)
	if err != nil {
		slog.Error("config load failed", "path", cfgPath, "err", err)
		os.Exit(1)
	}

	// Get GitHub token
	token, err := keychain.Get()
	if err != nil {
		slog.Error("token not found", "err", err)
		os.Exit(1)
	}

	// Open store
	dbPath := filepath.Join(dataDir(), "auto-pr.db")
	s, err := store.Open(dbPath + "?_journal_mode=WAL")
	if err != nil {
		slog.Error("store open failed", "err", err)
		os.Exit(1)
	}
	defer s.Close()

	// Purge old reviews
	if err := s.PurgeOldReviews(cfg.Retention.MaxDays); err != nil {
		slog.Warn("retention purge failed", "err", err)
	}

	// Wiring
	broker := sse.NewBroker()
	broker.Start()

	notifier := notify.New()
	ghClient := gh.NewClient(token)
	exec := executor.New()

	// Pipeline needs SSE broker for events
	p := pipeline.New(s, ghClient, exec, &notifyWithSSE{notifier: notifier, broker: broker})

	srv := server.New(s, broker, p)

	// Poll function
	pollFn := func() {
		prs, err := ghClient.FetchPRs(cfg.GitHub.Repositories)
		if err != nil {
			slog.Error("poll: fetch PRs", "err", err)
			return
		}
		for _, pr := range prs {
			if pr.Head.Repo.FullName != "" {
				pr.Repo = pr.Head.Repo.FullName
			}
			aiCfg := cfg.AIForRepo(pr.Repo)
			// Check if already reviewed recently (skip if reviewed in last poll interval)
			existing, _ := s.GetPRByGithubID(pr.ID)
			if existing != nil {
				if rev, err := s.LatestReviewForPR(existing.ID); err == nil && rev != nil {
					interval := parsePollInterval(cfg.GitHub.PollInterval)
					if time.Since(rev.CreatedAt) < interval {
						continue // already reviewed this cycle
					}
				}
			}
			broker.Publish(sse.Event{Type: sse.EventPRDetected, Data: fmt.Sprintf(`{"pr_number":%d,"repo":%q}`, pr.Number, pr.Repo)})
			if _, err := p.Run(pr, aiCfg.Primary, aiCfg.Fallback); err != nil {
				slog.Error("pipeline run failed", "pr", pr.Number, "err", err)
				broker.Publish(sse.Event{Type: sse.EventReviewError, Data: fmt.Sprintf(`{"pr_number":%d,"error":%q}`, pr.Number, err.Error())})
			} else {
				broker.Publish(sse.Event{Type: sse.EventReviewCompleted, Data: fmt.Sprintf(`{"pr_number":%d,"repo":%q}`, pr.Number, pr.Repo)})
			}
		}
	}

	interval := parsePollInterval(cfg.GitHub.PollInterval)
	sched := scheduler.New(interval, pollFn)
	sched.Start()
	defer sched.Stop()

	// Run initial poll
	go pollFn()

	// HTTP server in goroutine
	go func() {
		slog.Info("daemon started", "port", cfg.Server.Port)
		if err := srv.Start(cfg.Server.Port); err != nil {
			slog.Error("server stopped", "err", err)
		}
	}()

	// Graceful shutdown
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	slog.Info("shutting down")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	srv.Shutdown(ctx)
}

func setupLogging() {
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	})))
}

func dataDir() string {
	home, _ := os.UserHomeDir()
	dir := filepath.Join(home, ".local", "share", "auto-pr")
	os.MkdirAll(dir, 0700)
	return dir
}

func parsePollInterval(s string) time.Duration {
	m := map[string]time.Duration{
		"1m": time.Minute, "5m": 5 * time.Minute,
		"30m": 30 * time.Minute, "1h": time.Hour,
	}
	if d, ok := m[s]; ok {
		return d
	}
	return 5 * time.Minute
}

// notifyWithSSE wraps Notifier and also emits SSE events.
type notifyWithSSE struct {
	notifier *notify.Notifier
	broker   *sse.Broker
}

func (n *notifyWithSSE) Notify(title, message string) {
	n.notifier.Notify(title, message)
}
```

- [ ] **Step 3: Build and verify**

```bash
cd daemon && make build
./bin/auto-pr-daemon --help 2>&1 || true
```
Expected: binary builds without errors. Running without args will attempt to load config (expected to fail without config file — that's fine at this stage).

- [ ] **Step 4: Run full test suite**

```bash
cd daemon && make test
```
Expected: all tests PASS with `-race`.

- [ ] **Step 5: Commit**

```bash
cd /Users/jamuriano/personal-workspace/auto-pr
git add daemon/
git commit -m "feat(daemon): main.go wiring + LaunchAgent install/uninstall"
```

---

### Task 11: Integration test

**Files:**
- Create: `daemon/integration_test.go`

- [ ] **Step 1: Write integration test**

Create `daemon/integration_test.go`:
```go
//go:build integration

package main_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	gh "github.com/auto-pr/daemon/internal/github"
	"github.com/auto-pr/daemon/internal/executor"
	"github.com/auto-pr/daemon/internal/pipeline"
	"github.com/auto-pr/daemon/internal/server"
	"github.com/auto-pr/daemon/internal/sse"
	"github.com/auto-pr/daemon/internal/store"
	"github.com/auto-pr/daemon/internal/notify"
)

// fakeGHServer returns a test GitHub API server
func fakeGHServer(t *testing.T) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/search/issues":
			prs := struct {
				Items []gh.PullRequest `json:"items"`
			}{Items: []gh.PullRequest{
				{ID: 999, Number: 7, Title: "Add feature", HTMLURL: "https://github.com/org/repo/pull/7",
					User: gh.User{Login: "bob"}, State: "open", UpdatedAt: time.Now(),
					Head: gh.Branch{Repo: gh.Repo{FullName: "org/repo"}}},
			}}
			json.NewEncoder(w).Encode(prs)
		default:
			// diff endpoint
			w.Write([]byte("+new feature line\n"))
		}
	}))
}

func TestIntegration_FullPipeline(t *testing.T) {
	ghSrv := fakeGHServer(t)
	defer ghSrv.Close()

	s, _ := store.Open(":memory:")
	defer s.Close()

	broker := sse.NewBroker()
	broker.Start()
	defer broker.Stop()

	ghClient := gh.NewClient("fake-token", gh.WithBaseURL(ghSrv.URL))
	exec := executor.New()

	// Skip if no real CLI available
	if _, err := exec.Detect("claude", "gemini"); err != nil {
		t.Skip("no AI CLI available, skipping integration test")
	}

	notifier := &struct{ notify.Notifier }{}
	p := pipeline.New(s, ghClient, exec, notifier)
	srv := server.New(s, broker, p)

	prs, err := ghClient.FetchPRs([]string{"org/repo"})
	if err != nil {
		t.Fatalf("fetch prs: %v", err)
	}
	if len(prs) == 0 {
		t.Fatal("expected at least 1 PR")
	}

	pr := prs[0]
	pr.Repo = pr.Head.Repo.FullName
	rev, err := p.Run(pr, "claude", "gemini")
	if err != nil {
		t.Fatalf("pipeline run: %v", err)
	}
	if rev.Summary == "" {
		t.Error("expected non-empty summary")
	}

	// Verify via HTTP
	testSrv := httptest.NewServer(srv.Router())
	defer testSrv.Close()

	resp, err := http.Get(testSrv.URL + "/prs")
	if err != nil {
		t.Fatalf("GET /prs: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Errorf("GET /prs: status %d", resp.StatusCode)
	}
}
```

- [ ] **Step 2: Run unit tests (integration skipped by default)**

```bash
cd daemon && make test
```
Expected: all unit tests PASS. Integration test skipped (requires build tag).

- [ ] **Step 3: Commit**

```bash
cd /Users/jamuriano/personal-workspace/auto-pr
git add daemon/integration_test.go
git commit -m "test(daemon): integration test with fake GitHub server"
```

---

**Daemon plan complete.** Proceed to Flutter plan: `2026-03-31-auto-pr-flutter.md`
