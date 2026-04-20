<script lang="ts">
  import { decisionLabel } from '$lib/review.js';

  let { state }: { state: string | null | undefined } = $props();

  const decision = $derived(decisionLabel(state));
</script>

{#if decision}
  <span
    class="inline-flex rounded-full px-2 py-0.5 text-xs font-medium {decision.class}"
    data-testid="review-decision"
    data-state={state}
  >
    {decision.label}
  </span>
{/if}
