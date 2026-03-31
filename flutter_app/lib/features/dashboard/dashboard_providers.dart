import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/api/api_client.dart';
import '../../core/api/sse_client.dart';
import '../../core/models/pr.dart';

final apiClientProvider = Provider<ApiClient>((ref) => ApiClient());

final sseClientProvider = Provider<SseClient>((ref) => SseClient());

/// Streams SSE events from the daemon.
final sseStreamProvider = StreamProvider<SseEvent>((ref) {
  final client = ref.watch(sseClientProvider);
  ref.onDispose(() => client.disconnect());
  return client.connect();
});

/// Fetches the PR list and refreshes whenever an SSE event arrives.
final prsProvider = FutureProvider<List<PR>>((ref) async {
  ref.watch(sseStreamProvider);
  final api = ref.watch(apiClientProvider);
  return api.fetchPRs();
});
