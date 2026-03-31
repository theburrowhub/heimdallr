import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/api/api_client.dart';
import '../../core/api/sse_client.dart';
import '../../core/models/pr.dart';
import '../../main.dart' show sendPRNotification;

final apiClientProvider = Provider<ApiClient>((ref) => ApiClient());

final sseClientProvider = Provider<SseClient>((ref) => SseClient());

/// Streams SSE events from the daemon and sends Flutter notifications.
final sseStreamProvider = StreamProvider<SseEvent>((ref) {
  final client = ref.watch(sseClientProvider);
  ref.onDispose(() => client.disconnect());

  final stream = client.connect();
  // Side-effect: fire macOS notifications from the Flutter app
  stream.listen((event) {
    _handleSseNotification(event);
  });
  return stream;
});

void _handleSseNotification(SseEvent event) {
  try {
    final data = jsonDecode(event.data) as Map<String, dynamic>;
    final repo = data['repo'] as String? ?? '';
    final prNumber = (data['pr_number'] as num?)?.toInt();
    // pr_id is the store DB id — included in review_completed events
    final prId = (data['pr_id'] as num?)?.toInt();

    switch (event.type) {
      case 'review_completed':
        final severity = data['severity'] as String? ?? '';
        sendPRNotification(
          title: 'Review Complete',
          body: '$repo #$prNumber — $severity',
          prId: prId,
        );
      case 'pr_detected':
        sendPRNotification(
          title: 'New PR',
          body: '$repo #$prNumber',
          prId: prId,
        );
    }
  } catch (_) {}
}

/// Fetches the PR list and refreshes whenever an SSE event arrives.
final prsProvider = FutureProvider<List<PR>>((ref) async {
  ref.watch(sseStreamProvider);
  final api = ref.watch(apiClientProvider);
  return api.fetchPRs();
});
