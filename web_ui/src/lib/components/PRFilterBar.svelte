<script lang="ts">
  interface Filters {
    repo: string;
    severity: string;
    state: string;
  }

  interface Props {
    filters: Filters;
    repos: string[];
    onChange: (next: Filters) => void;
  }

  let { filters, repos, onChange }: Props = $props();

  const severities = ['any', 'critical', 'high', 'medium', 'low'];
  const states = ['open', 'closed', 'all'];

  function update(field: keyof Filters, value: string): void {
    onChange({ ...filters, [field]: value });
  }
</script>

<div
  class="mb-4 flex flex-wrap items-center gap-3 rounded-md border border-gray-200 bg-gray-50 p-3 dark:border-gray-800 dark:bg-gray-900"
>
  <label class="flex items-center gap-1 text-xs text-gray-600 dark:text-gray-300">
    <span>Repo:</span>
    <select
      class="rounded border border-gray-300 bg-white px-2 py-1 text-xs dark:border-gray-700 dark:bg-gray-800 dark:text-gray-100"
      value={filters.repo}
      onchange={(e) => update('repo', (e.currentTarget as HTMLSelectElement).value)}
    >
      <option value="">any</option>
      {#each repos as repo (repo)}
        <option value={repo}>{repo}</option>
      {/each}
    </select>
  </label>

  <label class="flex items-center gap-1 text-xs text-gray-600 dark:text-gray-300">
    <span>Severity:</span>
    <select
      class="rounded border border-gray-300 bg-white px-2 py-1 text-xs dark:border-gray-700 dark:bg-gray-800 dark:text-gray-100"
      value={filters.severity || 'any'}
      onchange={(e) => update('severity', (e.currentTarget as HTMLSelectElement).value)}
    >
      {#each severities as s (s)}
        <option value={s}>{s}</option>
      {/each}
    </select>
  </label>

  <label class="flex items-center gap-1 text-xs text-gray-600 dark:text-gray-300">
    <span>State:</span>
    <select
      class="rounded border border-gray-300 bg-white px-2 py-1 text-xs dark:border-gray-700 dark:bg-gray-800 dark:text-gray-100"
      value={filters.state ?? 'open'}
      onchange={(e) => update('state', (e.currentTarget as HTMLSelectElement).value)}
    >
      {#each states as s (s)}
        <option value={s}>{s}</option>
      {/each}
    </select>
  </label>
</div>
