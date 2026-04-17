<script lang="ts">
  import type { IssueReview, Review } from '$lib/types.js';
  import SeverityBadge from './SeverityBadge.svelte';

  interface Props {
    review: Review | IssueReview;
    variant: 'pr' | 'issue';
  }

  let { review, variant }: Props = $props();

  const asPR = $derived(variant === 'pr' ? (review as Review) : null);
  const asIssue = $derived(variant === 'issue' ? (review as IssueReview) : null);

  const triage = $derived(
    asIssue?.triage as
      | {
          severity?: string;
          category?: string;
          suggested_assignee?: string;
        }
      | undefined
  );
</script>

<article class="mb-3 rounded-md border border-gray-200 bg-white p-4">
  <header class="mb-2 flex items-center justify-between gap-2">
    <div class="flex items-center gap-2">
      {#if asPR}
        <SeverityBadge severity={asPR.severity} />
      {:else if triage?.severity}
        <SeverityBadge severity={triage.severity} />
      {/if}
      <span class="text-xs text-gray-500">{review.cli_used}</span>
    </div>
    <time class="text-xs text-gray-400" datetime={review.created_at}>
      {new Date(review.created_at).toLocaleString()}
    </time>
  </header>

  {#if review.summary}
    <p class="text-sm text-gray-800">{review.summary}</p>
  {/if}

  {#if asPR && asPR.issues.length > 0}
    <section class="mt-3">
      <h4 class="text-xs font-semibold uppercase tracking-wide text-gray-500">
        Findings ({asPR.issues.length})
      </h4>
      <ul class="mt-1 space-y-1 text-sm">
        {#each asPR.issues as f (f.file + f.line + f.description)}
          <li class="flex items-start gap-2">
            <SeverityBadge severity={f.severity} />
            <span class="font-mono text-xs text-gray-500">{f.file}:{f.line}</span>
            <span class="text-gray-800">{f.description}</span>
          </li>
        {/each}
      </ul>
    </section>
  {/if}

  {#if asIssue && triage}
    <section class="mt-3 rounded bg-gray-50 p-2 text-xs text-gray-700">
      {#if triage.severity}<div><strong>Severity:</strong> {triage.severity}</div>{/if}
      {#if triage.category}<div><strong>Category:</strong> {triage.category}</div>{/if}
      {#if triage.suggested_assignee}<div>
          <strong>Suggested assignee:</strong>
          {triage.suggested_assignee}
        </div>{/if}
    </section>
  {/if}

  {#if review.suggestions && review.suggestions.length > 0}
    <section class="mt-3">
      <h4 class="text-xs font-semibold uppercase tracking-wide text-gray-500">Suggestions</h4>
      <ul class="mt-1 list-disc space-y-1 pl-5 text-sm text-gray-800">
        {#each review.suggestions as s, i (i)}
          <li>{typeof s === 'string' ? s : JSON.stringify(s)}</li>
        {/each}
      </ul>
    </section>
  {/if}

  {#if asIssue && asIssue.action_taken === 'auto_implement' && asIssue.pr_created > 0}
    <p class="mt-3 text-xs">
      <a href="/prs/{asIssue.pr_created}" class="text-indigo-600 hover:underline">
        View created PR →
      </a>
    </p>
  {/if}
</article>
