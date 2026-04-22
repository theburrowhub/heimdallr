package pipeline_test

import (
	"testing"

	"github.com/heimdallm/daemon/internal/pipeline"
)

func TestEvaluate(t *testing.T) {
	cases := []struct {
		name string
		pr   pipeline.PRGate
		cfg  pipeline.GateConfig
		want pipeline.SkipReason
	}{
		{
			name: "open non-draft by human — allowed",
			pr:   pipeline.PRGate{State: "open", Draft: false, Author: "alice"},
			cfg:  pipeline.GateConfig{SkipDrafts: true, SkipSelfAuthor: true, BotLogin: "heimdallm-bot"},
			want: pipeline.SkipReasonNone,
		},
		{
			name: "closed — not_open wins over everything",
			pr:   pipeline.PRGate{State: "closed", Draft: true, Author: "heimdallm-bot"},
			cfg:  pipeline.GateConfig{SkipDrafts: true, SkipSelfAuthor: true, BotLogin: "heimdallm-bot"},
			want: pipeline.SkipReasonNotOpen,
		},
		{
			name: "merged — not_open",
			pr:   pipeline.PRGate{State: "merged", Draft: false, Author: "alice"},
			cfg:  pipeline.GateConfig{SkipDrafts: true, SkipSelfAuthor: true, BotLogin: "heimdallm-bot"},
			want: pipeline.SkipReasonNotOpen,
		},
		{
			name: "open draft with skip_drafts=true — draft",
			pr:   pipeline.PRGate{State: "open", Draft: true, Author: "alice"},
			cfg:  pipeline.GateConfig{SkipDrafts: true, SkipSelfAuthor: true, BotLogin: "heimdallm-bot"},
			want: pipeline.SkipReasonDraft,
		},
		{
			name: "open draft with skip_drafts=false — allowed",
			pr:   pipeline.PRGate{State: "open", Draft: true, Author: "alice"},
			cfg:  pipeline.GateConfig{SkipDrafts: false, SkipSelfAuthor: true, BotLogin: "heimdallm-bot"},
			want: pipeline.SkipReasonNone,
		},
		{
			name: "open self-authored with skip_self_author=true — self_authored",
			pr:   pipeline.PRGate{State: "open", Draft: false, Author: "heimdallm-bot"},
			cfg:  pipeline.GateConfig{SkipDrafts: true, SkipSelfAuthor: true, BotLogin: "heimdallm-bot"},
			want: pipeline.SkipReasonSelfAuthored,
		},
		{
			name: "open self-authored with skip_self_author=false — allowed",
			pr:   pipeline.PRGate{State: "open", Draft: false, Author: "heimdallm-bot"},
			cfg:  pipeline.GateConfig{SkipDrafts: true, SkipSelfAuthor: false, BotLogin: "heimdallm-bot"},
			want: pipeline.SkipReasonNone,
		},
		{
			name: "empty bot login disables self-author check",
			pr:   pipeline.PRGate{State: "open", Draft: false, Author: ""},
			cfg:  pipeline.GateConfig{SkipDrafts: true, SkipSelfAuthor: true, BotLogin: ""},
			want: pipeline.SkipReasonNone,
		},
		{
			name: "draft + self-authored — draft wins (priority)",
			pr:   pipeline.PRGate{State: "open", Draft: true, Author: "heimdallm-bot"},
			cfg:  pipeline.GateConfig{SkipDrafts: true, SkipSelfAuthor: true, BotLogin: "heimdallm-bot"},
			want: pipeline.SkipReasonDraft,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := pipeline.Evaluate(tc.pr, tc.cfg)
			if got != tc.want {
				t.Errorf("Evaluate(%+v, %+v) = %q, want %q", tc.pr, tc.cfg, got, tc.want)
			}
		})
	}
}
