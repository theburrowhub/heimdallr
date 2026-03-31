package store

import (
	"fmt"
	"time"
)

// Agent defines a named AI agent with a custom prompt template.
// Prompt placeholders: {title} {number} {repo} {author} {link} {diff}
type Agent struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	CLI       string    `json:"cli"`       // claude | gemini | codex
	Prompt    string    `json:"prompt"`    // template with {placeholders}
	IsDefault bool      `json:"is_default"`
	CreatedAt time.Time `json:"created_at"`
}

const defaultPromptTemplate = `You are a senior software engineer performing a pull request code review.

PR: {title} (#{number})
Repo: {repo}
Author: {author}
Link: {link}

Diff:
{diff}

Review the diff and respond with ONLY valid JSON (no markdown, no explanation):
{
  "summary": "brief overall assessment",
  "issues": [
    {"file": "filename", "line": 0, "description": "issue description", "severity": "low|medium|high"}
  ],
  "suggestions": ["suggestion 1"],
  "severity": "low|medium|high"
}`

func (s *Store) ListAgents() ([]*Agent, error) {
	rows, err := s.db.Query(
		"SELECT id, name, cli, prompt, is_default, created_at FROM agents ORDER BY is_default DESC, name ASC",
	)
	if err != nil {
		return nil, fmt.Errorf("store: list agents: %w", err)
	}
	defer rows.Close()

	var agents []*Agent
	for rows.Next() {
		var a Agent
		var createdAt string
		var isDefault int
		if err := rows.Scan(&a.ID, &a.Name, &a.CLI, &a.Prompt, &isDefault, &createdAt); err != nil {
			return nil, err
		}
		a.IsDefault = isDefault == 1
		a.CreatedAt, _ = time.Parse(time.RFC3339, createdAt)
		agents = append(agents, &a)
	}
	return agents, rows.Err()
}

func (s *Store) UpsertAgent(a *Agent) error {
	if a.CreatedAt.IsZero() {
		a.CreatedAt = time.Now().UTC()
	}
	_, err := s.db.Exec(`
		INSERT INTO agents (id, name, cli, prompt, is_default, created_at)
		VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET
			name=excluded.name, cli=excluded.cli, prompt=excluded.prompt,
			is_default=excluded.is_default
	`, a.ID, a.Name, a.CLI, a.Prompt, boolToInt(a.IsDefault),
		a.CreatedAt.UTC().Format(time.RFC3339),
	)
	if err != nil {
		return fmt.Errorf("store: upsert agent: %w", err)
	}
	if a.IsDefault {
		// Clear default from all other agents
		_, err = s.db.Exec("UPDATE agents SET is_default=0 WHERE id != ?", a.ID)
		if err != nil {
			return fmt.Errorf("store: clear default: %w", err)
		}
	}
	return nil
}

func (s *Store) DeleteAgent(id string) error {
	_, err := s.db.Exec("DELETE FROM agents WHERE id = ?", id)
	return err
}

func (s *Store) DefaultAgent() (*Agent, error) {
	row := s.db.QueryRow(
		"SELECT id, name, cli, prompt, is_default, created_at FROM agents WHERE is_default=1 LIMIT 1",
	)
	var a Agent
	var createdAt string
	var isDefault int
	if err := row.Scan(&a.ID, &a.Name, &a.CLI, &a.Prompt, &isDefault, &createdAt); err != nil {
		return nil, err
	}
	a.IsDefault = true
	a.CreatedAt, _ = time.Parse(time.RFC3339, createdAt)
	return &a, nil
}

func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}
