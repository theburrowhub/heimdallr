import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/models/agent.dart';
import '../../shared/widgets/toast.dart';
import '../dashboard/dashboard_providers.dart';

// ── Provider ─────────────────────────────────────────────────────────────────

final agentsProvider = FutureProvider<List<Agent>>((ref) async {
  final api = ref.watch(apiClientProvider);
  final raw = await api.fetchAgents();
  return raw.map(Agent.fromJson).toList();
});

// ── Screen ───────────────────────────────────────────────────────────────────

class AgentsScreen extends ConsumerWidget {
  const AgentsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agentsAsync = ref.watch(agentsProvider);

    return agentsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (agents) => _AgentsList(agents: agents),
    );
  }
}

class _AgentsList extends ConsumerWidget {
  final List<Agent> agents;
  const _AgentsList({required this.agents});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Configure the AI agents used for reviews. '
                  'Each agent has a custom prompt template with placeholders.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                icon: const Icon(Icons.add, size: 16),
                label: const Text('New Agent'),
                onPressed: () => _showEditor(context, ref, null),
              ),
            ],
          ),
        ),
        // Placeholder chips
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Wrap(
            spacing: 6, runSpacing: 4,
            children: Agent.placeholders.map((p) => Chip(
              label: Text(p, style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
              padding: EdgeInsets.zero,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            )).toList(),
          ),
        ),
        const Divider(height: 1),
        // List
        Expanded(
          child: agents.isEmpty
              ? const Center(child: Text('No agents configured.\nCreate one to customize the review prompt.'))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: agents.length,
                  itemBuilder: (_, i) => _AgentTile(
                    agent: agents[i],
                    onEdit: () => _showEditor(context, ref, agents[i]),
                    onDelete: () => _delete(context, ref, agents[i]),
                    onSetDefault: () => _setDefault(context, ref, agents[i]),
                  ),
                ),
        ),
      ],
    );
  }

  Future<void> _showEditor(BuildContext context, WidgetRef ref, Agent? existing) async {
    final saved = await showDialog<Agent>(
      context: context,
      builder: (_) => _AgentEditorDialog(agent: existing),
    );
    if (saved == null) return;
    try {
      await ref.read(apiClientProvider).upsertAgent(saved.toJson());
      ref.invalidate(agentsProvider);
      if (context.mounted) showToast(context, 'Agent saved');
    } catch (e) {
      if (context.mounted) showToast(context, 'Error: $e', isError: true);
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, Agent agent) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete agent?'),
        content: Text('Delete "${agent.name}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(apiClientProvider).deleteAgent(agent.id);
      ref.invalidate(agentsProvider);
    } catch (e) {
      if (context.mounted) showToast(context, 'Error: $e', isError: true);
    }
  }

  Future<void> _setDefault(BuildContext context, WidgetRef ref, Agent agent) async {
    try {
      await ref.read(apiClientProvider).upsertAgent(
          agent.copyWith(isDefault: true).toJson());
      ref.invalidate(agentsProvider);
      if (context.mounted) showToast(context, '${agent.name} set as default');
    } catch (e) {
      if (context.mounted) showToast(context, 'Error: $e', isError: true);
    }
  }
}

class _AgentTile extends StatelessWidget {
  final Agent agent;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onSetDefault;

  const _AgentTile({
    required this.agent,
    required this.onEdit,
    required this.onDelete,
    required this.onSetDefault,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: agent.isDefault
              ? Theme.of(context).colorScheme.primaryContainer
              : null,
          child: Text(agent.cli.substring(0, 1).toUpperCase(),
              style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
        title: Row(
          children: [
            Text(agent.name, style: const TextStyle(fontWeight: FontWeight.w600)),
            if (agent.isDefault) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text('DEFAULT',
                    style: TextStyle(color: Colors.white, fontSize: 10,
                        fontWeight: FontWeight.bold)),
              ),
            ],
          ],
        ),
        subtitle: Text(agent.cli,
            style: const TextStyle(fontSize: 12)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!agent.isDefault)
              TextButton(onPressed: onSetDefault, child: const Text('Set default')),
            IconButton(icon: const Icon(Icons.edit, size: 18), onPressed: onEdit),
            IconButton(
              icon: const Icon(Icons.delete, size: 18),
              color: Colors.red.shade400,
              onPressed: onDelete,
            ),
          ],
        ),
        onTap: onEdit,
      ),
    );
  }
}

// ── Editor dialog ─────────────────────────────────────────────────────────────

class _AgentEditorDialog extends StatefulWidget {
  final Agent? agent;
  const _AgentEditorDialog({this.agent});

  @override
  State<_AgentEditorDialog> createState() => _AgentEditorDialogState();
}

class _AgentEditorDialogState extends State<_AgentEditorDialog> {
  final _idCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _promptCtrl = TextEditingController();
  String _cli = 'claude';
  bool _isDefault = false;

  @override
  void initState() {
    super.initState();
    final a = widget.agent;
    if (a != null) {
      _idCtrl.text = a.id;
      _nameCtrl.text = a.name;
      _promptCtrl.text = a.prompt;
      _cli = a.cli;
      _isDefault = a.isDefault;
    } else {
      _promptCtrl.text = Agent.defaultPrompt;
    }
  }

  @override
  void dispose() {
    _idCtrl.dispose();
    _nameCtrl.dispose();
    _promptCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.agent == null;

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 700),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(isNew ? 'New Agent' : 'Edit Agent',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _nameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Name',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (isNew)
                    SizedBox(
                      width: 160,
                      child: TextFormField(
                        controller: _idCtrl,
                        decoration: const InputDecoration(
                          labelText: 'ID (unique slug)',
                          border: OutlineInputBorder(),
                          hintText: 'my-agent',
                        ),
                      ),
                    ),
                  if (!isNew)
                    SizedBox(
                      width: 160,
                      child: DropdownButtonFormField<String>(
                        value: _cli,
                        decoration: const InputDecoration(
                          labelText: 'CLI',
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(value: 'claude', child: Text('claude')),
                          DropdownMenuItem(value: 'gemini', child: Text('gemini')),
                          DropdownMenuItem(value: 'codex',  child: Text('codex')),
                        ],
                        onChanged: (v) => setState(() => _cli = v!),
                      ),
                    ),
                  if (isNew) ...[
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 130,
                      child: DropdownButtonFormField<String>(
                        value: _cli,
                        decoration: const InputDecoration(
                          labelText: 'CLI',
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(value: 'claude', child: Text('claude')),
                          DropdownMenuItem(value: 'gemini', child: Text('gemini')),
                          DropdownMenuItem(value: 'codex',  child: Text('codex')),
                        ],
                        onChanged: (v) => setState(() => _cli = v!),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              // Placeholder quick-insert chips
              Wrap(
                spacing: 6, runSpacing: 4,
                children: Agent.placeholders.map((p) => ActionChip(
                  label: Text(p,
                      style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
                  padding: EdgeInsets.zero,
                  onPressed: () {
                    final sel = _promptCtrl.selection;
                    final text = _promptCtrl.text;
                    final pos = sel.isValid ? sel.baseOffset : text.length;
                    _promptCtrl.text = text.substring(0, pos) + p + text.substring(pos);
                    _promptCtrl.selection = TextSelection.collapsed(offset: pos + p.length);
                  },
                )).toList(),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: TextFormField(
                  controller: _promptCtrl,
                  maxLines: null,
                  expands: true,
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                  decoration: const InputDecoration(
                    labelText: 'Prompt template',
                    alignLabelWithHint: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Switch(
                    value: _isDefault,
                    onChanged: (v) => setState(() => _isDefault = v),
                  ),
                  const Text('Set as default agent'),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () {
                      final id = isNew ? _idCtrl.text.trim() : widget.agent!.id;
                      if (id.isEmpty || _nameCtrl.text.isEmpty) return;
                      Navigator.pop(context, Agent(
                        id: id,
                        name: _nameCtrl.text.trim(),
                        cli: _cli,
                        prompt: _promptCtrl.text,
                        isDefault: _isDefault,
                      ));
                    },
                    child: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
