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
            : _PRList(prs: prs),
      ),
    );
  }
}

class _PRList extends ConsumerWidget {
  final List<PR> prs;
  const _PRList({required this.prs});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: prs.length,
      separatorBuilder: (_, __) => const SizedBox(height: 4),
      itemBuilder: (_, i) => _PRTile(pr: prs[i], ref: ref),
    );
  }
}

class _PRTile extends StatelessWidget {
  final PR pr;
  final WidgetRef ref;
  const _PRTile({required this.pr, required this.ref});

  @override
  Widget build(BuildContext context) {
    final reviewed = pr.latestReview != null;

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.push('/prs/${pr.id}'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              // Severity strip
              Container(
                width: 4, height: 48,
                margin: const EdgeInsets.only(right: 12),
                decoration: BoxDecoration(
                  color: reviewed
                      ? _severityColor(pr.latestReview!.severity)
                      : Colors.grey.shade600,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),

              // Title + meta
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      pr.title,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${pr.repo} · #${pr.number} · ${pr.author}',
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),

              // Right: badge + button
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (reviewed)
                    SeverityBadge(severity: pr.latestReview!.severity)
                  else
                    _chip('PENDING', Colors.grey.shade700),
                  const SizedBox(height: 6),
                  SizedBox(
                    height: 28,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        textStyle: const TextStyle(fontSize: 12),
                      ),
                      onPressed: () async {
                        final api = ref.read(apiClientProvider);
                        await api.triggerReview(pr.id);
                      },
                      child: const Text('Review'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4)),
    child: Text(label, style: const TextStyle(
        color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
  );

  Color _severityColor(String s) {
    switch (s.toLowerCase()) {
      case 'high': return Colors.red.shade700;
      case 'medium': return Colors.orange.shade700;
      default: return Colors.green.shade700;
    }
  }
}
