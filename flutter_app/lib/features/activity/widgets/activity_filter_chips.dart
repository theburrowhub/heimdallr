import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/activity.dart';
import '../activity_providers.dart';

/// Three chips (Organization / Repository / Action) with multi-select popups,
/// plus a Clear-filters button when any filter is active.
class ActivityFilterChips extends ConsumerWidget {
  final List<String> availableOrgs;
  final List<String> availableRepos;

  const ActivityFilterChips({
    super.key,
    required this.availableOrgs,
    required this.availableRepos,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final q = ref.watch(activityQueryProvider);
    final n = ref.read(activityQueryProvider.notifier);
    final anyActive = q.orgs.isNotEmpty || q.repos.isNotEmpty || q.actions.isNotEmpty;

    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _chip(context,
            label: 'Organization',
            count: q.orgs.length,
            onTap: () => _pickStrings(context,
                options: availableOrgs,
                selected: q.orgs,
                toggle: n.toggleOrg)),
        _chip(context,
            label: 'Repository',
            count: q.repos.length,
            onTap: () => _pickStrings(context,
                options: availableRepos,
                selected: q.repos,
                toggle: n.toggleRepo)),
        _chip(context,
            label: 'Action',
            count: q.actions.length,
            onTap: () => _pickActions(context,
                selected: q.actions, toggle: n.toggleAction)),
        if (anyActive)
          TextButton(
            onPressed: n.clearFilters,
            child: const Text('Clear filters'),
          ),
      ],
    );
  }

  Widget _chip(BuildContext context,
      {required String label, required int count, required VoidCallback onTap}) {
    return ActionChip(
      label: Text(count == 0 ? label : '$label · $count'),
      onPressed: onTap,
    );
  }

  Future<void> _pickStrings(BuildContext context,
      {required List<String> options,
      required Set<String> selected,
      required void Function(String) toggle}) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setState) => ListView(
          children: options
              .map((o) => CheckboxListTile(
                    value: selected.contains(o),
                    title: Text(o),
                    onChanged: (_) {
                      toggle(o);
                      setState(() {});
                    },
                  ))
              .toList(),
        ),
      ),
    );
  }

  Future<void> _pickActions(BuildContext context,
      {required Set<ActivityAction> selected,
      required void Function(ActivityAction) toggle}) async {
    const options = [
      ActivityAction.review,
      ActivityAction.triage,
      ActivityAction.implement,
      ActivityAction.promote,
      ActivityAction.error,
    ];
    await showModalBottomSheet<void>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setState) => ListView(
          children: options
              .map((a) => CheckboxListTile(
                    value: selected.contains(a),
                    title: Text(a.name),
                    onChanged: (_) {
                      toggle(a);
                      setState(() {});
                    },
                  ))
              .toList(),
        ),
      ),
    );
  }
}
