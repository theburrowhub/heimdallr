package config

import (
	"encoding/json"
	"fmt"
	"log/slog"
)

// StoreLister is the subset of *store.Store that ApplyStore needs. Kept as a
// local interface so the config package stays free of a store dependency
// (avoids an import cycle and keeps tests able to inject fakes).
type StoreLister interface {
	ListConfigs() (map[string]string, error)
}

// MergeStoreLayer is the full "apply the store layer on top of TOML+env"
// operation: fetch rows, apply them atomically, re-validate. Callers that
// need each step separately can still use ListConfigs + ApplyStore + Validate
// directly; this helper exists so main.go's bootstrap and reload paths can
// share one code path and so tests can drive the whole flow with a fake.
//
// Returns the first error encountered. On error the receiver is untouched
// (ApplyStore is atomic and Validate is a read-only check), so the caller is
// free to keep serving the previous Config on reload failure.
func (c *Config) MergeStoreLayer(s StoreLister) error {
	rows, err := s.ListConfigs()
	if err != nil {
		return fmt.Errorf("config: list store: %w", err)
	}
	if err := c.ApplyStore(rows); err != nil {
		return fmt.Errorf("config: apply store: %w", err)
	}
	if err := c.Validate(); err != nil {
		return fmt.Errorf("config: validate after store: %w", err)
	}
	return nil
}

// ApplyStore merges runtime-overridable config values written by the
// PUT /config handler on top of whatever is already in the Config (TOML +
// env vars). Precedence is TOML < env < store, so this step runs last.
//
// The handler stores string values bare and everything else as JSON, so the
// decoding here is symmetric to handlers.go:handlePutConfig.
//
// Unknown keys are logged and skipped rather than rejected so a newer writer
// can't brick an older reader during a staggered deploy.
//
// Atomicity: the merge happens on a shadow copy of the Config and is
// promoted onto the receiver only if every row decoded successfully. A
// single malformed row therefore leaves the receiver untouched, so the
// caller's error-path ("continuing with TOML+env") is truthful.
//
// `server_port` is intentionally NOT supported: mutating the listening port
// at runtime would invalidate every in-flight connection and the web UI has
// no surface for it. Bootstrap-only.
func (c *Config) ApplyStore(rows map[string]string) error {
	shadow := *c
	for key, raw := range rows {
		switch key {
		case "poll_interval":
			shadow.GitHub.PollInterval = raw
		case "ai_primary":
			shadow.AI.Primary = raw
		case "ai_fallback":
			shadow.AI.Fallback = raw
		case "review_mode":
			shadow.AI.ReviewMode = raw
		case "repositories":
			var repos []string
			if err := json.Unmarshal([]byte(raw), &repos); err != nil {
				return fmt.Errorf("config: apply store key %q: %w", key, err)
			}
			shadow.GitHub.Repositories = repos
		case "retention_days":
			var days int
			if err := json.Unmarshal([]byte(raw), &days); err != nil {
				return fmt.Errorf("config: apply store key %q: %w", key, err)
			}
			shadow.Retention.MaxDays = days
		case "issue_tracking":
			var it IssueTrackingConfig
			if err := json.Unmarshal([]byte(raw), &it); err != nil {
				return fmt.Errorf("config: apply store key %q: %w", key, err)
			}
			shadow.GitHub.IssueTracking = it
		default:
			slog.Warn("config: unknown store key, skipping", "key", key)
		}
	}
	*c = shadow
	return nil
}
