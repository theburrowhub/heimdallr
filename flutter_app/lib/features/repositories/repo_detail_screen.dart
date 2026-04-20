import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/models/config_model.dart';
import '../../core/models/agent.dart';
import '../../shared/widgets/override_field.dart';
import '../../shared/widgets/toast.dart';
import '../agents/agents_screen.dart' show agentsProvider;
import '../config/config_providers.dart';

class RepoDetailScreen extends ConsumerStatefulWidget {
  final String repoName;
  const RepoDetailScreen({super.key, required this.repoName});

  @override
  ConsumerState<RepoDetailScreen> createState() => _RepoDetailScreenState();
}

class _RepoDetailScreenState extends ConsumerState<RepoDetailScreen> {
  RepoConfig _config = const RepoConfig();
  bool _initialized = false;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _initFrom(AppConfig config) {
    if (_initialized) return;
    _initialized = true;
    _config = config.repoConfigs[widget.repoName] ?? const RepoConfig();
  }

  void _update(RepoConfig updated) {
    setState(() => _config = updated);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 800), _autoSave);
  }

  Future<void> _autoSave() async {
    final current = ref.read(configNotifierProvider).valueOrNull;
    if (current == null) return;
    final updatedRepos = Map<String, RepoConfig>.from(current.repoConfigs);
    updatedRepos[widget.repoName] = _config;
    final updated = current.copyWith(repoConfigs: updatedRepos);
    try {
      await ref.read(configNotifierProvider.notifier).save(updated);
      if (mounted) showToast(context, 'Saved');
    } catch (e) {
      if (mounted) showToast(context, 'Error: $e', isError: true);
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  String _joinList(List<String>? list) => list?.join(', ') ?? '';

  List<String>? _parseList(String? value) {
    if (value == null) return null;
    final parsed = value
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    return parsed.isEmpty ? null : parsed;
  }

  // ── Section card ─────────────────────────────────────────────────────────────

  Widget _sectionCard(String title, List<Widget> children) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 15)),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final configAsync = ref.watch(configNotifierProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.repoName),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/'),
        ),
      ),
      body: configAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) =>
            const Center(child: Text('Could not load config')),
        data: (appConfig) {
          _initFrom(appConfig);
          final prompts =
              ref.watch(agentsProvider).valueOrNull ?? <ReviewPrompt>[];

          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                // ── General ──────────────────────────────────────────────
                _sectionCard('General', [
                  const Text('Local directory',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 4),
                  Text(
                    'When set, the AI agent runs inside this directory and can read all project files.',
                    style: TextStyle(
                        fontSize: 11, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 8),
                  _LocalDirField(
                    value: _config.localDir ?? '',
                    onChanged: (dir) => _update(_config.copyWith(
                        localDir: dir.isEmpty ? null : dir)),
                  ),
                  const SizedBox(height: 12),
                  OverrideDropdown(
                    label: 'Review mode',
                    globalValue: appConfig.reviewMode,
                    overrideValue: _config.reviewMode,
                    options: const ['single', 'multi'],
                    onChanged: (v) =>
                        _update(_config.copyWith(reviewMode: v)),
                  ),
                ]),

                // ── AI Agent ─────────────────────────────────────────────
                _sectionCard('AI Agent', [
                  OverrideDropdown(
                    label: 'Primary',
                    globalValue: appConfig.aiPrimary,
                    overrideValue: _config.aiPrimary,
                    options: const ['claude', 'gemini', 'codex'],
                    onChanged: (v) =>
                        _update(_config.copyWith(aiPrimary: v)),
                  ),
                  const SizedBox(height: 10),
                  OverrideDropdown(
                    label: 'Fallback',
                    globalValue: appConfig.aiFallback.isEmpty
                        ? 'none'
                        : appConfig.aiFallback,
                    overrideValue: _config.aiFallback,
                    options: const ['claude', 'gemini', 'codex'],
                    onChanged: (v) =>
                        _update(_config.copyWith(aiFallback: v)),
                  ),
                  const SizedBox(height: 10),
                  OverrideDropdown(
                    label: 'Prompt',
                    globalValue: 'default',
                    overrideValue: _config.promptId,
                    options: prompts.map((p) => p.id).toList(),
                    onChanged: (v) =>
                        _update(_config.copyWith(promptId: v)),
                  ),
                ]),

                // ── Issue Tracking ───────────────────────────────────────
                _sectionCard('Issue Tracking', [
                  OverrideTextField(
                    label: 'Develop labels',
                    helper:
                        'Issues with these labels get a branch + PR',
                    globalValue: _joinList(
                        appConfig.issueTracking.developLabels),
                    overrideValue: _config.developLabels?.join(', '),
                    onChanged: (v) => _update(_config.copyWith(
                        developLabels:
                            v != null ? _parseList(v) : null)),
                  ),
                  const SizedBox(height: 10),
                  OverrideTextField(
                    label: 'Review-only labels',
                    helper:
                        'Issues with these labels get a review comment only',
                    globalValue: _joinList(
                        appConfig.issueTracking.reviewOnlyLabels),
                    overrideValue: _config.reviewOnlyLabels?.join(', '),
                    onChanged: (v) => _update(_config.copyWith(
                        reviewOnlyLabels:
                            v != null ? _parseList(v) : null)),
                  ),
                  const SizedBox(height: 10),
                  OverrideTextField(
                    label: 'Skip labels',
                    helper: 'Issues with these labels are ignored',
                    globalValue:
                        _joinList(appConfig.issueTracking.skipLabels),
                    overrideValue: _config.skipLabels?.join(', '),
                    onChanged: (v) => _update(_config.copyWith(
                        skipLabels:
                            v != null ? _parseList(v) : null)),
                  ),
                  const SizedBox(height: 10),
                  OverrideDropdown(
                    label: 'Filter mode',
                    globalValue:
                        appConfig.issueTracking.filterMode,
                    overrideValue: _config.issueFilterMode,
                    options: const ['exclusive', 'inclusive'],
                    onChanged: (v) => _update(
                        _config.copyWith(issueFilterMode: v)),
                  ),
                  const SizedBox(height: 10),
                  OverrideDropdown(
                    label: 'Default action',
                    globalValue:
                        appConfig.issueTracking.defaultAction,
                    overrideValue: _config.issueDefaultAction,
                    options: const ['ignore', 'review_only'],
                    onChanged: (v) => _update(
                        _config.copyWith(issueDefaultAction: v)),
                  ),
                  const SizedBox(height: 10),
                  OverrideTextField(
                    label: 'Organizations',
                    helper:
                        'Comma-separated GitHub org names to filter issues',
                    globalValue: _joinList(
                        appConfig.issueTracking.organizations),
                    overrideValue: _config.issueOrganizations?.join(', '),
                    onChanged: (v) => _update(_config.copyWith(
                        issueOrganizations:
                            v != null ? _parseList(v) : null)),
                  ),
                  const SizedBox(height: 10),
                  OverrideTextField(
                    label: 'Assignees',
                    helper:
                        'Comma-separated GitHub usernames to filter issues',
                    globalValue:
                        _joinList(appConfig.issueTracking.assignees),
                    overrideValue: _config.issueAssignees?.join(', '),
                    onChanged: (v) => _update(_config.copyWith(
                        issueAssignees:
                            v != null ? _parseList(v) : null)),
                  ),
                ]),

                // ── PR Metadata ──────────────────────────────────────────
                _sectionCard('PR Metadata', [
                  OverrideTextField(
                    label: 'Reviewers',
                    helper:
                        'Comma-separated GitHub usernames to request review',
                    globalValue: '',
                    overrideValue: _config.prReviewers?.join(', '),
                    onChanged: (v) => _update(_config.copyWith(
                        prReviewers:
                            v != null ? _parseList(v) : null)),
                  ),
                  const SizedBox(height: 10),
                  OverrideTextField(
                    label: 'Assignee',
                    helper: 'GitHub username to assign to PRs',
                    globalValue: '',
                    overrideValue: _config.prAssignee,
                    onChanged: (v) =>
                        _update(_config.copyWith(prAssignee: v)),
                  ),
                  const SizedBox(height: 10),
                  OverrideTextField(
                    label: 'Labels',
                    helper: 'Comma-separated labels to add to PRs',
                    globalValue: '',
                    overrideValue: _config.prLabels?.join(', '),
                    onChanged: (v) => _update(_config.copyWith(
                        prLabels:
                            v != null ? _parseList(v) : null)),
                  ),
                  const SizedBox(height: 10),
                  OverrideDropdown(
                    label: 'Draft',
                    globalValue: 'false',
                    overrideValue: _config.prDraft?.toString(),
                    options: const ['true', 'false'],
                    onChanged: (v) => _update(_config.copyWith(
                        prDraft: v != null ? v == 'true' : null)),
                  ),
                ]),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ── Local directory picker ─────────────────────────────────────────────────

class _LocalDirField extends StatefulWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _LocalDirField({required this.value, required this.onChanged});

  @override
  State<_LocalDirField> createState() => _LocalDirFieldState();
}

class _LocalDirFieldState extends State<_LocalDirField> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.value);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select local repository directory',
      lockParentWindow: true,
    );
    if (dir == null) return;
    setState(() => _ctrl.text = dir);
    widget.onChanged(dir);
  }

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(
        child: TextFormField(
          controller: _ctrl,
          decoration: const InputDecoration(
            hintText: '/path/to/local/repo',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: widget.onChanged,
        ),
      ),
      const SizedBox(width: 8),
      OutlinedButton.icon(
        icon: const Icon(Icons.folder_open, size: 16),
        label: const Text('Browse'),
        onPressed: _pick,
        style: OutlinedButton.styleFrom(
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        ),
      ),
      if (_ctrl.text.isNotEmpty) ...[
        const SizedBox(width: 4),
        IconButton(
          icon: const Icon(Icons.clear, size: 16),
          tooltip: 'Clear',
          onPressed: () {
            setState(() => _ctrl.clear());
            widget.onChanged('');
          },
        ),
      ],
    ]);
  }
}
