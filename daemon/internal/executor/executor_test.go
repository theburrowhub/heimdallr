package executor_test

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/heimdallr/daemon/internal/executor"
)

func TestDetect(t *testing.T) {
	_, file, _, _ := runtime.Caller(0)
	binDir := filepath.Join(filepath.Dir(file), "testdata", "bin")
	oldPath := os.Getenv("PATH")
	os.Setenv("PATH", binDir+":"+oldPath)
	defer os.Setenv("PATH", oldPath)

	e := executor.New()
	cli, err := e.Detect("claude", "")
	if err != nil {
		t.Fatalf("detect: %v", err)
	}
	if cli != "claude" {
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
	cli, err := e.Detect("codex", "gemini")
	if err != nil {
		t.Fatalf("detect with fallback: %v", err)
	}
	if cli != "gemini" {
		t.Errorf("expected fake_gemini fallback, got %q", cli)
	}
}

func TestDetect_NoneAvailable(t *testing.T) {
	oldPath := os.Getenv("PATH")
	os.Setenv("PATH", "")
	defer os.Setenv("PATH", oldPath)

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
	result, err := e.Execute("claude", "Review this diff", executor.ExecOptions{})
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

func TestValidateExtraFlags(t *testing.T) {
	tests := []struct {
		name    string
		flags   string
		wantErr bool
	}{
		{
			name:    "empty — allowed",
			flags:   "",
			wantErr: false,
		},
		{
			name:    "safe flags — allowed",
			flags:   "--output json --verbose",
			wantErr: false,
		},
		{
			name:    "--dangerously-skip-permissions — rejected",
			flags:   "--dangerously-skip-permissions",
			wantErr: true,
		},
		{
			name:    "--dangerously-skip-permissions mixed with safe flags — rejected",
			flags:   "--output json --dangerously-skip-permissions",
			wantErr: true,
		},
		{
			name:    "--danger prefix — rejected",
			flags:   "--dangerous-flag",
			wantErr: true,
		},
		{
			name:    "--allow-dangerously prefix — rejected",
			flags:   "--allow-dangerously-skip-permissions",
			wantErr: true,
		},
		{
			name:    "bypassPermissions value — rejected",
			flags:   "--permission-mode bypassPermissions",
			wantErr: true,
		},
		{
			name:    "bypassPermissions value standalone — rejected",
			flags:   "bypassPermissions",
			wantErr: true,
		},
		{
			name:    "case-insensitive --DANGER prefix — rejected",
			flags:   "--DANGEROUSLY-SKIP-PERMISSIONS",
			wantErr: true,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			err := executor.ValidateExtraFlags(tc.flags)
			if tc.wantErr && err == nil {
				t.Errorf("expected error for flags %q, got nil", tc.flags)
			}
			if !tc.wantErr && err != nil {
				t.Errorf("unexpected error for flags %q: %v", tc.flags, err)
			}
		})
	}
}
