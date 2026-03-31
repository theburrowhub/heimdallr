import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/models/pr.dart';
import '../../shared/widgets/severity_badge.dart';
import 'dashboard_providers.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prsAsync = ref.watch(prsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Heimdallr'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => context.push('/config'),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(prsProvider),
          ),
        ],
      ),
      body: prsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.wifi_off, size: 48, color: Colors.grey),
              const SizedBox(height: 12),
              const Text('Could not reach the Heimdallr daemon.',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              const Text('Go to Settings to configure and start it.',
                  style: TextStyle(color: Colors.grey)),
              const SizedBox(height: 16),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: () => ref.invalidate(prsProvider),
                    child: const Text('Retry'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    icon: const Icon(Icons.settings, size: 16),
                    label: const Text('Settings'),
                    onPressed: () => context.push('/config'),
                  ),
                ],
              ),
            ],
          ),
        ),
        data: (prs) => prs.isEmpty
            ? const Center(child: Text('No open PRs found'))
            : _PRTable(prs: prs),
      ),
    );
  }
}

class _PRTable extends ConsumerWidget {
  final List<PR> prs;
  const _PRTable({required this.prs});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SingleChildScrollView(
      child: DataTable(
        columnSpacing: 16,
        columns: const [
          DataColumn(label: SizedBox(width: 200, child: Text('Repo'))),
          DataColumn(label: Expanded(child: Text('PR'))),
          DataColumn(label: SizedBox(width: 100, child: Text('Author'))),
          DataColumn(label: SizedBox(width: 80, child: Text('Severity'))),
          DataColumn(label: SizedBox(width: 80, child: Text('Status'))),
          DataColumn(label: SizedBox(width: 110, child: Text('Actions'))),
        ],
        rows: prs.map((pr) => DataRow(
          cells: [
            DataCell(SizedBox(
              width: 200,
              child: Text(pr.repo,
                overflow: TextOverflow.ellipsis, maxLines: 1),
            )),
            DataCell(
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  style: TextButton.styleFrom(alignment: Alignment.centerLeft),
                  onPressed: () => context.push('/prs/${pr.id}'), // push = back button appears
                  child: Text(
                    '#${pr.number} ${pr.title}',
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
              ),
            ),
            DataCell(SizedBox(
              width: 100,
              child: Text(pr.author, overflow: TextOverflow.ellipsis, maxLines: 1),
            )),
            DataCell(pr.latestReview != null
                ? SeverityBadge(severity: pr.latestReview!.severity)
                : const Text('—')),
            DataCell(Text(pr.latestReview != null ? 'Reviewed' : 'Pending')),
            DataCell(
              SizedBox(
                width: 110,
                child: ElevatedButton(
                  onPressed: () async {
                    final api = ref.read(apiClientProvider);
                    await api.triggerReview(pr.id);
                    ref.invalidate(prsProvider);
                  },
                  child: const Text('Review Now'),
                ),
              ),
            ),
          ],
        )).toList(),
      ),
    );
  }
}
