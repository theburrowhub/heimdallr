<script lang="ts">
  import '../app.css';
  import { browser } from '$app/environment';
  import { page } from '$app/stores';
  import { connectEvents, type EventsHandle } from '$lib/sse.js';
  import { initSseBridge, watchReconnectAndSweep } from '$lib/sseBridge.js';
  import { auth } from '$lib/stores.js';
  import { initTheme, setThemeChoice, type ThemeChoice } from '$lib/theme.js';
  import { onDestroy, onMount, setContext } from 'svelte';
  import { writable, type Readable } from 'svelte/store';

  let { children } = $props();

  // Shared connection state. Populated by onMount; exposed to child pages
  // via context so they don't open their own EventSource.
  const connected = writable(false);
  setContext<Readable<boolean>>('sse-connected', { subscribe: connected.subscribe });

  let sse: EventsHandle | undefined;
  let connUnsub: (() => void) | undefined;
  let bridgeUnsub: (() => void) | undefined;
  let reconnectUnsub: (() => void) | undefined;

  let themeChoice = $state<ThemeChoice>('system');

  onMount(() => {
    if (!browser) return;
    themeChoice = initTheme();
    sse = connectEvents();
    connUnsub = sse.connected.subscribe((v) => connected.set(v));
    bridgeUnsub = initSseBridge(sse.events);
    reconnectUnsub = watchReconnectAndSweep(sse.connected);
  });

  onDestroy(() => {
    reconnectUnsub?.();
    bridgeUnsub?.();
    connUnsub?.();
    sse?.close();
  });

  function chooseTheme(choice: ThemeChoice) {
    themeChoice = choice;
    setThemeChoice(choice);
  }

  const navItems = [
    { href: '/', label: 'Dashboard' },
    { href: '/prs', label: 'PRs' },
    { href: '/issues', label: 'Issues' },
    { href: '/agents', label: 'Agents' },
    { href: '/config', label: 'Config' },
    { href: '/logs', label: 'Logs' }
  ];

  const themeOptions: { value: ThemeChoice; label: string; title: string }[] = [
    { value: 'light', label: '☀', title: 'Light' },
    { value: 'system', label: '🖥', title: 'System' },
    { value: 'dark', label: '🌙', title: 'Dark' }
  ];
</script>

<header class="border-b border-gray-200 bg-white dark:border-gray-800 dark:bg-gray-900">
  <nav class="mx-auto flex max-w-6xl items-center justify-between gap-4 px-6 py-3">
    <a href="/" class="text-lg font-semibold tracking-tight text-gray-900 dark:text-gray-100"
      >Heimdallm</a
    >
    <ul class="flex items-center gap-4 text-sm">
      {#each navItems as item (item.href)}
        <li>
          <a
            href={item.href}
            aria-current={$page.url.pathname === item.href ? 'page' : undefined}
            class="hover:text-indigo-600 dark:hover:text-indigo-400 {$page.url.pathname ===
            item.href
              ? 'font-medium text-indigo-600 dark:text-indigo-400'
              : 'text-gray-600 dark:text-gray-400'}"
          >
            {item.label}
          </a>
        </li>
      {/each}
    </ul>
    <div class="flex items-center gap-3">
      <div
        role="radiogroup"
        aria-label="Theme"
        class="inline-flex overflow-hidden rounded-md border border-gray-200 text-xs dark:border-gray-700"
      >
        {#each themeOptions as opt (opt.value)}
          <button
            type="button"
            role="radio"
            aria-checked={themeChoice === opt.value}
            title={opt.title}
            onclick={() => chooseTheme(opt.value)}
            class="px-2 py-1 {themeChoice === opt.value
              ? 'bg-indigo-600 text-white dark:bg-indigo-500'
              : 'bg-white text-gray-600 hover:bg-gray-50 dark:bg-gray-900 dark:text-gray-400 dark:hover:bg-gray-800'}"
          >
            <span aria-hidden="true">{opt.label}</span>
            <span class="sr-only">{opt.title}</span>
          </button>
        {/each}
      </div>
      <span class="text-sm text-gray-500 dark:text-gray-400" data-testid="login">
        {$auth.login ?? '—'}
      </span>
    </div>
  </nav>
</header>

{#if $auth.authError}
  <div
    class="border-b border-red-200 bg-red-50 px-6 py-2 text-sm text-red-700 dark:border-red-900 dark:bg-red-950 dark:text-red-300"
  >
    Daemon unreachable — check <code>HEIMDALLM_API_URL</code>. ({$auth.authError})
  </div>
{/if}

<main class="mx-auto max-w-6xl px-6 py-8">
  {@render children()}
</main>
