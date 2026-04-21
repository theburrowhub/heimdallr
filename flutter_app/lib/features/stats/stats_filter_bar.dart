import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'stats_filters.dart';

/// Compact filter bar for Stats: org and repo multi-select + reset.
class StatsFilterBar extends ConsumerWidget {
  final Set<String> allRepos;

  const StatsFilterBar({super.key, required this.allRepos});

  Set<String> get _allOrgs =>
      allRepos.map((r) => r.contains('/') ? r.split('/').first : r).toSet();

  Set<String> _filteredRepos(StatsFilters filters) {
    if (filters.orgs.isEmpty) return allRepos;
    return allRepos.where((r) {
      final org = r.contains('/') ? r.split('/').first : r;
      return filters.orgs.contains(org);
    }).toSet();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filters = ref.watch(statsFiltersProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('Filter:', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),

          // Org multi-select
          if (_allOrgs.isNotEmpty)
            _multiSelectPopup(
              context: context,
              label: 'Org',
              icon: Icons.business,
              allItems: _allOrgs.toList()..sort(),
              selected: filters.orgs,
              onChanged: (orgs) {
                // Clear repos that no longer match the selected orgs
                final validRepos = filters.repos.where((r) {
                  final org = r.contains('/') ? r.split('/').first : r;
                  return orgs.isEmpty || orgs.contains(org);
                }).toSet();
                ref.read(statsFiltersProvider.notifier).state =
                    filters.copyWith(orgs: orgs, repos: validRepos);
              },
            ),

          // Repo multi-select
          if (_filteredRepos(filters).isNotEmpty)
            _multiSelectPopup(
              context: context,
              label: 'Repo',
              icon: Icons.folder_outlined,
              allItems: _filteredRepos(filters).toList()..sort(),
              selected: filters.repos,
              onChanged: (repos) {
                ref.read(statsFiltersProvider.notifier).state =
                    filters.copyWith(repos: repos);
              },
            ),

          // Reset
          if (filters.hasFilters)
            ActionChip(
              avatar: const Icon(Icons.clear, size: 14),
              label: const Text('Reset', style: TextStyle(fontSize: 12)),
              visualDensity: VisualDensity.compact,
              onPressed: () {
                ref.read(statsFiltersProvider.notifier).state =
                    const StatsFilters();
              },
            ),
        ],
      ),
    );
  }

  Widget _multiSelectPopup({
    required BuildContext context,
    required String label,
    required IconData icon,
    required List<String> allItems,
    required Set<String> selected,
    required ValueChanged<Set<String>> onChanged,
  }) {
    final isActive = selected.isNotEmpty;
    return PopupMenuButton<String>(
      tooltip: label,
      offset: const Offset(0, 36),
      constraints: const BoxConstraints(minWidth: 220, maxWidth: 320),
      itemBuilder: (_) => allItems.map((item) {
        final checked = selected.contains(item);
        return PopupMenuItem<String>(
          value: item,
          padding: EdgeInsets.zero,
          child: StatefulBuilder(
            builder: (ctx, setMenuState) => CheckboxListTile(
              dense: true,
              title: Text(item, style: const TextStyle(fontSize: 13)),
              value: checked,
              onChanged: (val) {
                final updated = Set<String>.from(selected);
                if (val == true) {
                  updated.add(item);
                } else {
                  updated.remove(item);
                }
                onChanged(updated);
                setMenuState(() {});
              },
            ),
          ),
        );
      }).toList(),
      child: Chip(
        avatar: Icon(icon, size: 14,
            color: isActive ? Theme.of(context).colorScheme.primary : Colors.grey),
        label: Text(
          isActive ? '$label (${selected.length})' : label,
          style: TextStyle(
            fontSize: 12,
            color: isActive ? Theme.of(context).colorScheme.primary : null,
          ),
        ),
        visualDensity: VisualDensity.compact,
        side: isActive
            ? BorderSide(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5))
            : const BorderSide(color: Colors.transparent),
      ),
    );
  }
}
