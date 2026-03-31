import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../dashboard/dashboard_providers.dart';

final prDetailProvider = FutureProvider.family<Map<String, dynamic>, int>((ref, prId) async {
  ref.watch(sseStreamProvider);
  final api = ref.watch(apiClientProvider);
  return api.fetchPR(prId);
});

final triggerReviewProvider = FutureProvider.family<void, int>((ref, prId) async {
  final api = ref.watch(apiClientProvider);
  await api.triggerReview(prId);
  ref.invalidate(prDetailProvider(prId));
  ref.invalidate(prsProvider);
});
