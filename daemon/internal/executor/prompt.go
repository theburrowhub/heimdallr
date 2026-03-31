package executor

import (
	"fmt"
	"strings"
)

const maxDiffBytes = 32 * 1024 // 32KB ~ 8k tokens

// PRContext holds all substitutable data for a prompt template.
type PRContext struct {
	Title  string
	Number int
	Repo   string
	Author string
	Link   string
	Diff   string
}

// defaultTemplate is used when no custom agent template is configured.
const defaultTemplate = `You are a senior software engineer performing a pull request code review.

PR: {title} (#{number})
Repo: {repo}
Author: {author}
Link: {link}

Diff:
{diff}

Review the above diff and respond with ONLY valid JSON in this exact format (no markdown, no explanation):
{
  "summary": "brief overall assessment",
  "issues": [
    {"file": "filename", "line": 0, "description": "issue description", "severity": "low|medium|high"}
  ],
  "suggestions": ["suggestion 1", "suggestion 2"],
  "severity": "low|medium|high"
}

The top-level "severity" is the highest severity found. If no issues, return empty arrays and severity "low".`

// DefaultTemplate returns the built-in prompt template.
func DefaultTemplate() string { return defaultTemplate }

// BuildPrompt builds a prompt from the default template.
// Kept for backwards compatibility.
func BuildPrompt(title, author, diff string) string {
	return BuildPromptFromTemplate(defaultTemplate, PRContext{
		Title:  title,
		Author: author,
		Diff:   diff,
	})
}

// BuildPromptFromTemplate substitutes placeholders in a custom template.
// Supported: {title} {number} {repo} {author} {link} {diff}
func BuildPromptFromTemplate(template string, ctx PRContext) string {
	if len(ctx.Diff) > maxDiffBytes {
		ctx.Diff = ctx.Diff[:maxDiffBytes] + "\n... (diff truncated)"
	}

	r := strings.NewReplacer(
		"{title}", ctx.Title,
		"{number}", fmt.Sprintf("%d", ctx.Number),
		"{repo}", ctx.Repo,
		"{author}", ctx.Author,
		"{link}", ctx.Link,
		"{diff}", ctx.Diff,
	)
	return r.Replace(template)
}
