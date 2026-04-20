package config

import (
	"encoding/json"
	"fmt"
	"log/slog"
)

// ApplyStore merges runtime-overridable config values written by the
// PUT /config handler on top of whatever is already in the Config (TOML +
// env vars). Precedence is TOML < env < store, so this step runs last.
//
// The handler stores string values bare and everything else as JSON, so the
// decoding here is symmetric to handlers.go:handlePutConfig.
//
// Unknown keys are logged and skipped rather than rejected so a newer writer
// can't brick an older reader during a staggered deploy.
func (c *Config) ApplyStore(rows map[string]string) error {
	for key, raw := range rows {
		switch key {
		case "poll_interval":
			c.GitHub.PollInterval = raw
		case "ai_primary":
			c.AI.Primary = raw
		case "ai_fallback":
			c.AI.Fallback = raw
		case "review_mode":
			c.AI.ReviewMode = raw
		case "repositories":
			var repos []string
			if err := json.Unmarshal([]byte(raw), &repos); err != nil {
				return fmt.Errorf("config: apply store key %q: %w", key, err)
			}
			c.GitHub.Repositories = repos
		case "retention_days":
			var days int
			if err := json.Unmarshal([]byte(raw), &days); err != nil {
				return fmt.Errorf("config: apply store key %q: %w", key, err)
			}
			c.Retention.MaxDays = days
		case "server_port":
			var port int
			if err := json.Unmarshal([]byte(raw), &port); err != nil {
				return fmt.Errorf("config: apply store key %q: %w", key, err)
			}
			c.Server.Port = port
		case "issue_tracking":
			var it IssueTrackingConfig
			if err := json.Unmarshal([]byte(raw), &it); err != nil {
				return fmt.Errorf("config: apply store key %q: %w", key, err)
			}
			c.GitHub.IssueTracking = it
		default:
			slog.Warn("config: unknown store key, skipping", "key", key)
		}
	}
	return nil
}
