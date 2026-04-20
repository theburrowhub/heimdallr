package config

import (
	"testing"
)

// ApplyStore is the third layer of config precedence: TOML < env < store.
// It receives the `configs` table rows (key → raw value string) that the
// PUT /config handler writes, and merges them onto an already-loaded cfg.
//
// Values stored as bare strings (e.g. "5m" for poll_interval) are assigned
// as-is; everything else was json.Marshal'd by the handler, so we unmarshal
// here symmetrically.

func TestApplyStore_MergesRepositoriesAndIssueTracking(t *testing.T) {
	cfg := &Config{}
	cfg.applyDefaults()
	cfg.GitHub.Repositories = []string{"toml/one"}

	rows := map[string]string{
		"repositories":   `["store/a","store/b"]`,
		"issue_tracking": `{"enabled":true,"filter_mode":"inclusive","develop_labels":["feature","bug"],"default_action":"review_only"}`,
	}

	if err := cfg.ApplyStore(rows); err != nil {
		t.Fatalf("ApplyStore: %v", err)
	}

	got := cfg.GitHub.Repositories
	if len(got) != 2 || got[0] != "store/a" || got[1] != "store/b" {
		t.Errorf("Repositories = %v, want [store/a store/b]", got)
	}
	it := cfg.GitHub.IssueTracking
	if !it.Enabled {
		t.Errorf("IssueTracking.Enabled = false, want true")
	}
	if it.FilterMode != FilterModeInclusive {
		t.Errorf("FilterMode = %q, want inclusive", it.FilterMode)
	}
	if len(it.DevelopLabels) != 2 || it.DevelopLabels[0] != "feature" || it.DevelopLabels[1] != "bug" {
		t.Errorf("DevelopLabels = %v, want [feature bug]", it.DevelopLabels)
	}
	if it.DefaultAction != "review_only" {
		t.Errorf("DefaultAction = %q, want review_only", it.DefaultAction)
	}
}

func TestApplyStore_WinsOverEnvOverrides(t *testing.T) {
	t.Setenv("HEIMDALLM_POLL_INTERVAL", "1m")
	t.Setenv("HEIMDALLM_AI_PRIMARY", "gemini")

	cfg := &Config{}
	cfg.applyDefaults()
	cfg.applyEnvOverrides()

	if cfg.GitHub.PollInterval != "1m" {
		t.Fatalf("setup: env should have set poll_interval=1m, got %q", cfg.GitHub.PollInterval)
	}
	if cfg.AI.Primary != "gemini" {
		t.Fatalf("setup: env should have set ai_primary=gemini, got %q", cfg.AI.Primary)
	}

	rows := map[string]string{
		"poll_interval": "30m",
		"ai_primary":    "claude",
	}

	if err := cfg.ApplyStore(rows); err != nil {
		t.Fatalf("ApplyStore: %v", err)
	}

	if cfg.GitHub.PollInterval != "30m" {
		t.Errorf("PollInterval = %q, want 30m (store wins over env)", cfg.GitHub.PollInterval)
	}
	if cfg.AI.Primary != "claude" {
		t.Errorf("AI.Primary = %q, want claude (store wins over env)", cfg.AI.Primary)
	}
}

func TestApplyStore_InvalidJSON_ReturnsError(t *testing.T) {
	cfg := &Config{}
	cfg.applyDefaults()

	rows := map[string]string{
		"repositories": "this is not json",
	}

	if err := cfg.ApplyStore(rows); err == nil {
		t.Fatal("ApplyStore with malformed JSON: expected error, got nil")
	}
}

func TestApplyStore_UnknownKey_IsIgnored(t *testing.T) {
	// Forward-compat: if an older daemon sees a key written by a newer
	// handler, we skip it rather than fail the whole reload.
	cfg := &Config{}
	cfg.applyDefaults()

	rows := map[string]string{
		"future_key":    "some-value",
		"poll_interval": "30m", // known key alongside unknown one
	}

	if err := cfg.ApplyStore(rows); err != nil {
		t.Errorf("ApplyStore with unknown key: expected nil error, got %v", err)
	}
	if cfg.GitHub.PollInterval != "30m" {
		t.Errorf("PollInterval = %q, want 30m (known key should still apply)", cfg.GitHub.PollInterval)
	}
}
