<script lang="ts">
  import { getContext } from 'svelte';
  import type { Readable } from 'svelte/store';

  const connected = getContext<Readable<boolean>>('sse-connected');

  const cls = $derived(
    $connected
      ? 'bg-green-100 text-green-700 dark:bg-green-950 dark:text-green-300'
      : 'bg-amber-100 text-amber-700 dark:bg-amber-950 dark:text-amber-300'
  );
  const label = $derived($connected ? 'connected' : 'disconnected');
</script>

<span class="rounded-full px-2 py-0.5 text-xs font-medium {cls}" data-testid="sse-pill">
  {label}
</span>
