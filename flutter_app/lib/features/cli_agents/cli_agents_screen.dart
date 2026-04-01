import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/models/config_model.dart';
import '../../shared/widgets/toast.dart';
import '../agents/agents_screen.dart' show agentsProvider;
import '../config/config_providers.dart';

const _cliNames = ['claude', 'gemini', 'codex'];

class CLIAgentsScreen extends ConsumerStatefulWidget {
  const CLIAgentsScreen({super.key});

  @override
  ConsumerState<CLIAgentsScreen> createState() => _CLIAgentsScreenState();
}

class _CLIAgentsScreenState extends ConsumerState<CLIAgentsScreen> {
  // Global
  String _aiPrimary = 'claude';
  String _aiFallback = '';
  String _reviewMode = 'single';

  // Per-agent — keys match _cliNames
  final Map<String, _AgentState> _agents = {
    for (final n in _cliNames) n: _AgentState(),
  };

  bool _initialized = false;

  void _initFrom(AppConfig config) {
    if (_initialized) return;
    _initialized = true;
    _aiPrimary  = config.aiPrimary;
    _aiFallback = config.aiFallback;
    _reviewMode = config.reviewMode;
    for (final name in _cliNames) {
      final ac = config.agentConfigs[name] ?? const CLIAgentConfig();
      _agents[name] = _AgentState.from(ac);
    }
  }

  Future<void> _save(AppConfig current) async {
    final agentConfigs = <String, CLIAgentConfig>{
      for (final name in _cliNames)
        name: _agents[name]!.toConfig(),
    };
    final updated = current.copyWith(
      aiPrimary:    _aiPrimary,
      aiFallback:   _aiFallback,
      reviewMode:   _reviewMode,
      agentConfigs: agentConfigs,
    );
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
    final prompts = ref.watch(agentsProvider).valueOrNull ?? [];

    return configAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, __) => const Center(child: Text('Could not load config')),
      data: (config) {
        _initFrom(config);
        return Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // ── Global ──────────────────────────────────────────────
                  _sectionHeader('Global defaults'),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(child: _dropdown(
                      label: 'Primary agent',
                      value: _aiPrimary,
                      items: _cliNames,
                      onChanged: (v) => setState(() => _aiPrimary = v!),
                    )),
                    const SizedBox(width: 12),
                    Expanded(child: DropdownButtonFormField<String?>(
                      // ignore: deprecated_member_use
                      value: _aiFallback.isEmpty ? null : _aiFallback,
                      decoration: const InputDecoration(
                        labelText: 'Fallback agent',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        const DropdownMenuItem<String?>(value: null, child: Text('None')),
                        ..._cliNames.map((v) => DropdownMenuItem<String?>(
                          value: v, child: Text(v))),
                      ],
                      onChanged: (v) => setState(() => _aiFallback = v ?? ''),
                    )),
                    const SizedBox(width: 12),
                    Expanded(child: DropdownButtonFormField<String>(
                      // ignore: deprecated_member_use
                      value: _reviewMode,
                      decoration: const InputDecoration(
                        labelText: 'Feedback mode',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(value: 'single', child: Text('Single (consolidated)')),
                        DropdownMenuItem(value: 'multi',  child: Text('Multi (per issue)')),
                      ],
                      onChanged: (v) => setState(() => _reviewMode = v!),
                    )),
                  ]),
                  const SizedBox(height: 24),
                  const Divider(),

                  // ── Per-agent sections ───────────────────────────────────
                  for (final name in _cliNames) ...[
                    const SizedBox(height: 16),
                    _AgentSection(
                      name: name,
                      state: _agents[name]!,
                      prompts: prompts,
                      onChanged: (s) => setState(() => _agents[name] = s),
                    ),
                    const Divider(),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => _save(config),
                  child: const Text('Save'),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _sectionHeader(String title) => Text(
    title,
    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
  );

  Widget _dropdown({
    required String label,
    required String value,
    required List<String> items,
    required ValueChanged<String?> onChanged,
  }) => DropdownButtonFormField<String>(
    // ignore: deprecated_member_use
    value: value,
    decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
    items: items.map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
    onChanged: onChanged,
  );
}

// ── Per-agent editable state ────────────────────────────────────────────────

class _AgentState {
  String model = '';
  int maxTurns = 0;
  String approvalMode = '';
  String extraFlags = '';
  String? promptId;

  _AgentState();

  _AgentState.from(CLIAgentConfig ac) {
    model        = ac.model;
    maxTurns     = ac.maxTurns;
    approvalMode = ac.approvalMode;
    extraFlags   = ac.extraFlags;
    promptId     = ac.promptId;
  }

  CLIAgentConfig toConfig() => CLIAgentConfig(
    model:        model,
    maxTurns:     maxTurns,
    approvalMode: approvalMode,
    extraFlags:   extraFlags,
    promptId:     promptId,
  );
}

// ── Agent section card ──────────────────────────────────────────────────────

class _AgentSection extends StatefulWidget {
  final String name;
  final _AgentState state;
  final List<dynamic> prompts;
  final ValueChanged<_AgentState> onChanged;

  const _AgentSection({
    required this.name,
    required this.state,
    required this.prompts,
    required this.onChanged,
  });

  @override
  State<_AgentSection> createState() => _AgentSectionState();
}

class _AgentSectionState extends State<_AgentSection> {
  late final TextEditingController _extraCtrl;

  @override
  void initState() {
    super.initState();
    _extraCtrl = TextEditingController(text: widget.state.extraFlags);
  }

  @override
  void dispose() {
    _extraCtrl.dispose();
    super.dispose();
  }

  void _emit() => widget.onChanged(widget.state);

  @override
  Widget build(BuildContext context) {
    final name = widget.name;
    final s    = widget.state;
    final models = CLIAgentConfig.modelOptions[name] ?? [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header row with emoji + name
        Row(children: [
          Text(_cliEmoji(name), style: const TextStyle(fontSize: 20)),
          const SizedBox(width: 8),
          Text(name,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        ]),
        const SizedBox(height: 12),

        // Row 1: Model + (claude) max-turns or (codex) approval-mode
        Row(children: [
          Expanded(child: DropdownButtonFormField<String>(
            // ignore: deprecated_member_use
            value: s.model.isEmpty ? null : s.model,
            decoration: const InputDecoration(
                labelText: 'Model', border: OutlineInputBorder()),
            items: [
              const DropdownMenuItem<String>(
                  value: null, child: Text('CLI default')),
              ...models.map((m) => DropdownMenuItem(value: m, child: Text(m))),
            ],
            onChanged: (v) {
              setState(() => s.model = v ?? '');
              _emit();
            },
          )),
          if (name == 'claude') ...[
            const SizedBox(width: 12),
            SizedBox(
              width: 130,
              child: TextFormField(
                initialValue: s.maxTurns > 0 ? '${s.maxTurns}' : '',
                decoration: const InputDecoration(
                  labelText: '--max-turns',
                  hintText: 'default',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
                onChanged: (v) {
                  setState(() => s.maxTurns = int.tryParse(v) ?? 0);
                  _emit();
                },
              ),
            ),
          ],
          if (name == 'codex') ...[
            const SizedBox(width: 12),
            SizedBox(
              width: 190,
              child: DropdownButtonFormField<String>(
                // ignore: deprecated_member_use
                value: s.approvalMode.isEmpty ? null : s.approvalMode,
                decoration: const InputDecoration(
                    labelText: '--approval-mode',
                    border: OutlineInputBorder()),
                items: [
                  const DropdownMenuItem<String>(
                      value: null, child: Text('CLI default')),
                  ...CLIAgentConfig.approvalModeOptions.map(
                      (v) => DropdownMenuItem(value: v, child: Text(v))),
                ],
                onChanged: (v) {
                  setState(() => s.approvalMode = v ?? '');
                  _emit();
                },
              ),
            ),
          ],
        ]),
        const SizedBox(height: 10),

        // Row 2: Default prompt + extra flags
        Row(children: [
          Expanded(child: _promptDropdown(s)),
          const SizedBox(width: 12),
          Expanded(child: TextFormField(
            controller: _extraCtrl,
            decoration: InputDecoration(
              labelText: 'Extra flags',
              hintText: _extraFlagsHint(name),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) {
              s.extraFlags = v;
              _emit();
            },
          )),
        ]),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _promptDropdown(_AgentState s) {
    return DropdownButtonFormField<String?>(
      // ignore: deprecated_member_use
      value: s.promptId,
      decoration: const InputDecoration(
        labelText: 'Default prompt',
        helperText: 'Overrides global; repo config overrides this',
        border: OutlineInputBorder(),
        isDense: true,
      ),
      items: [
        const DropdownMenuItem<String?>(value: null, child: Text('Global active')),
        ...widget.prompts.map((p) => DropdownMenuItem<String?>(
          value: p.id as String,
          child: Text(p.name as String),
        )),
      ],
      onChanged: (v) {
        setState(() => s.promptId = v);
        _emit();
      },
    );
  }

  String _cliEmoji(String name) {
    switch (name) {
      case 'claude': return '🔷';
      case 'gemini': return '🟡';
      case 'codex':  return '🟢';
      default:       return '🤖';
    }
  }

  String _extraFlagsHint(String name) {
    switch (name) {
      case 'claude': return '--allowedTools Bash,Read';
      case 'gemini': return '--all-files';
      case 'codex':  return '--full-auto';
      default:       return '';
    }
  }
}
