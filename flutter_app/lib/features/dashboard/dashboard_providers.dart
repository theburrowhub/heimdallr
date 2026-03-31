import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/api/api_client.dart';
import '../../core/api/sse_client.dart';
import '../../core/models/pr.dart';
import '../../main.dart' show sendPRNotification;

final apiClientProvider = Provider<ApiClient>((ref) => ApiClient());

final sseClientProvider = Provider<SseClient>((ref) => SseClient());

/// Streams raw SSE events. Consumers should NOT watch this to avoid
/// rebuilding on every event — use [prListRefreshProvider] instead.
final sseStreamProvider = StreamProvider<SseEvent>((ref) {
  final client = ref.watch(sseClientProvider);
  ref.onDispose(() => client.disconnect());
  return client.connect();
});

/// Increments only when the PR list needs a refresh (review completed).
/// Watching this avoids the constant flickering caused by watching the raw stream.
final prListRefreshProvider = StateProvider<int>((ref) {
  ref.listen(sseStreamProvider, (_, next) {
    next.whenData((event) {
      _handleSseNotification(ref, event);
    });
  });
  return 0;
});

void _handleSseNotification(Ref ref, SseEvent event) {
  try {
    final data = jsonDecode(event.data) as Map<String, dynamic>;
    final repo = data['repo'] as String? ?? '';
    final prNumber = (data['pr_number'] as num?)?.toInt();
    final prId = (data['pr_id'] as num?)?.toInt();

    switch (event.type) {
      case 'review_completed':
        final severity = data['severity'] as String? ?? '';
        sendPRNotification(
          title: 'Review Complete — $severity',
          body: '$repo #$prNumber',
          prId: prId,
        );
        // Trigger PR list refresh
        ref.read(prListRefreshProvider.notifier).update((s) => s + 1);

      case 'review_started':
        sendPRNotification(
          title: 'Review Started',
          body: '$repo #$prNumber',
          prId: prId,
        );
    }
    // pr_detected is silent — avoids notification spam on first poll
  } catch (_) {}
}

/// Fetches the PR list. Only refreshes when [prListRefreshProvider] changes,
/// not on every SSE heartbeat — prevents flickering.
final prsProvider = FutureProvider<List<PR>>((ref) async {
  ref.watch(prListRefreshProvider);
  final api = ref.watch(apiClientProvider);
  return api.fetchPRs();
});
