import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/models/config_model.dart';
import '../../core/setup/first_run_setup.dart';
import '../../core/setup/repo_discovery.dart';
import '../../shared/widgets/toast.dart';
import '../config/config_providers.dart';
import '../dashboard/dashboard_providers.dart';

class ReposScreen extends ConsumerStatefulWidget {
  const ReposScreen({super.key});

  @override
  ConsumerState<ReposScreen> createState() => _ReposScreenState();
}

class _ReposScreenState extends ConsumerState<ReposScreen> {
  Map<String, RepoConfig> _repoConfigs = {};
  bool _initialized = false;
  bool _discovering = false;
  String? _discoverError;
  String _search = '';

  void _initFrom(AppConfig config) {
    if (_initialized) return;
    _initialized = true;
    _repoConfigs = Map.from(config.repoConfigs);
  }

  Future<void> _discover() async {
    setState(() { _discovering = true; _discoverError = null; });
    try {
      final token = await FirstRunSetup.detectToken();
      final discovered = await RepoDiscovery.discoverFromPRs(token ?? '');
      if (!mounted) return;
      setState(() {
        for (final repo in discovered) {
          _repoConfigs.putIfAbsent(repo, () => const RepoConfig(monitored: true));
        }
        _discovering = false;
        if (discovered.isEmpty) _discoverError = 'No active PRs found.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _discovering = false; _discoverError = '$e'; });
    }
  }

  Future<void> _save(AppConfig current) async {
    final updated = current.copyWith(repoConfigs: Map.from(_repoConfigs));
    try {
      await ref.read(configNotifierProvider.notifier).save(updated);
      if (mounted) showToast(context, 'Saved');
    } catch (e) {
      if (mounted) showToast(context, 'Error: $e', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final configAsync = ref.watch(configNotifierProvider);

    return configAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, __) => const Center(child: Text('Could not load config')),
      data: (config) {
        _initFrom(config);

        final sorted = _repoConfigs.keys.toList()..sort();
        final filtered = _search.isEmpty
            ? sorted
            : sorted.where((r) => r.toLowerCase().contains(_search.toLowerCase())).toList();

        return Column(
          children: [
            // Toolbar
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      decoration: const InputDecoration(
                        hintText: 'Filter repos…',
                        prefixIcon: Icon(Icons.search, size: 18),
                        isDense: true,
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(vertical: 8),
                      ),
                      onChanged: (v) => setState(() => _search = v),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonalIcon(
                    icon: _discovering
                        ? const SizedBox(width: 14, height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.sync, size: 16),
                    label: const Text('Discover'),
                    onPressed: _discovering ? null : _discover,
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => _save(config),
                    child: const Text('Save'),
                  ),
                ],
              ),
            ),
            if (_discoverError != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Text(_discoverError!, style: const TextStyle(color: Colors.orange)),
              ),
            // Repo list
            Expanded(
              child: filtered.isEmpty
                  ? const Center(child: Text('No repos yet. Tap Discover.'))
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: filtered.length,
                      itemBuilder: (_, i) => _RepoTile(
                        repo: filtered[i],
                        config: _repoConfigs[filtered[i]]!,
                        onChanged: (rc) => setState(() => _repoConfigs[filtered[i]] = rc),
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _RepoTile extends StatelessWidget {
  final String repo;
  final RepoConfig config;
  final ValueChanged<RepoConfig> onChanged;

  const _RepoTile({
    required this.repo,
    required this.config,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
      child: ExpansionTile(
        leading: Switch(
          value: config.monitored,
          onChanged: (v) => onChanged(config.copyWith(monitored: v)),
        ),
        title: Text(repo,
            style: TextStyle(
              fontWeight: config.monitored ? FontWeight.w600 : FontWeight.normal,
              color: config.monitored ? null : Colors.grey,
            )),
        subtitle: config.hasAiOverride
            ? Text('AI: ${config.aiPrimary ?? "global"}',
                style: const TextStyle(fontSize: 12))
            : null,
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          const Divider(height: 1),
          const SizedBox(height: 10),
          const Text('AI overrides for this repo',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _aiDropdown('Primary agent', config.aiPrimary,
                  (v) => onChanged(config.copyWith(aiPrimary: v)))),
              const SizedBox(width: 12),
              Expanded(child: _aiDropdown('Fallback', config.aiFallback,
                  (v) => onChanged(config.copyWith(aiFallback: v)))),
            ],
          ),
        ],
      ),
    );
  }

  Widget _aiDropdown(String label, String? value, ValueChanged<String?> onChanged) {
    return DropdownButtonFormField<String?>(
      value: value,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      items: const [
        DropdownMenuItem<String?>(value: null, child: Text('Global (no override)')),
        DropdownMenuItem<String?>(value: 'claude', child: Text('claude')),
        DropdownMenuItem<String?>(value: 'gemini', child: Text('gemini')),
        DropdownMenuItem<String?>(value: 'codex', child: Text('codex')),
      ],
      onChanged: onChanged,
    );
  }
}
