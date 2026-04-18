package main

import (
	"testing"

	"github.com/heimdallm/daemon/internal/store"
)

// newMemStore returns an in-memory SQLite store with a short cleanup hook.
// Lives here (rather than in internal/store) so the cmd-layer tests can
// stand alone without loosening visibility of a test helper that is only
// useful to package main.
func newMemStore(t *testing.T) *store.Store {
	t.Helper()
	s, err := store.Open(":memory:")
	if err != nil {
		t.Fatalf("open memory store: %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

func seedAgent(t *testing.T, s *store.Store, a store.Agent) {
	t.Helper()
	if err := s.UpsertAgent(&a); err != nil {
		t.Fatalf("upsert agent %q: %v", a.ID, err)
	}
}

func TestResolveImplementPrompt_RepoOverrideWins(t *testing.T) {
	s := newMemStore(t)
	seedAgent(t, s, store.Agent{
		ID:                    "repo-agent",
		Name:                  "repo",
		ImplementPrompt:       "REPO TEMPLATE",
		ImplementInstructions: "should be ignored — template wins",
	})
	seedAgent(t, s, store.Agent{
		ID:                    "cli-agent",
		Name:                  "cli",
		ImplementInstructions: "cli-level instructions",
	})
	seedAgent(t, s, store.Agent{
		ID:                    "default-agent",
		Name:                  "default",
		IsDefault:             true,
		ImplementInstructions: "default instructions",
	})

	tmpl, instr := resolveImplementPrompt(s, "repo-agent", "cli-agent")
	if tmpl != "REPO TEMPLATE" {
		t.Errorf("template = %q, want REPO TEMPLATE", tmpl)
	}
	if instr != "" {
		t.Errorf("instr = %q, want empty (template wins)", instr)
	}
}

func TestResolveImplementPrompt_AgentFallbackWhenNoRepoMatch(t *testing.T) {
	s := newMemStore(t)
	seedAgent(t, s, store.Agent{
		ID:                    "cli-agent",
		Name:                  "cli",
		ImplementInstructions: "cli-level instructions",
	})
	seedAgent(t, s, store.Agent{
		ID:                    "default-agent",
		Name:                  "default",
		IsDefault:             true,
		ImplementInstructions: "default instructions",
	})

	// repoPromptID does not match any seeded agent → fall through to cli-agent.
	tmpl, instr := resolveImplementPrompt(s, "nonexistent-repo-agent", "cli-agent")
	if tmpl != "" {
		t.Errorf("template = %q, want empty (agent has no ImplementPrompt)", tmpl)
	}
	if instr != "cli-level instructions" {
		t.Errorf("instr = %q, want cli-level instructions", instr)
	}
}

func TestResolveImplementPrompt_DefaultFallbackWhenAgentMissing(t *testing.T) {
	s := newMemStore(t)
	seedAgent(t, s, store.Agent{
		ID:                    "default-agent",
		Name:                  "default",
		IsDefault:             true,
		ImplementPrompt:       "DEFAULT TEMPLATE",
	})

	// Neither the repo nor the agent ID exists → use global default's ImplementPrompt.
	tmpl, instr := resolveImplementPrompt(s, "", "")
	if tmpl != "DEFAULT TEMPLATE" {
		t.Errorf("template = %q, want DEFAULT TEMPLATE", tmpl)
	}
	if instr != "" {
		t.Errorf("instr = %q, want empty", instr)
	}
}

func TestResolveImplementPrompt_EmptyWhenNoAgents(t *testing.T) {
	s := newMemStore(t)

	tmpl, instr := resolveImplementPrompt(s, "anything", "also-anything")
	if tmpl != "" || instr != "" {
		t.Errorf("empty store should yield empty strings, got (%q, %q)", tmpl, instr)
	}
}

func TestResolveImplementPrompt_AgentInstructionsWhenPromptEmpty(t *testing.T) {
	// When the selected agent has ImplementInstructions but no ImplementPrompt,
	// return ("", instructions). This is the injection-into-default path.
	s := newMemStore(t)
	seedAgent(t, s, store.Agent{
		ID:                    "repo-agent",
		Name:                  "repo",
		ImplementInstructions: "inject me into the default template",
	})

	tmpl, instr := resolveImplementPrompt(s, "repo-agent", "")
	if tmpl != "" {
		t.Errorf("template = %q, want empty", tmpl)
	}
	if instr != "inject me into the default template" {
		t.Errorf("instr = %q, want 'inject me into the default template'", instr)
	}
}
