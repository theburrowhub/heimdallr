import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/activity.dart';
import '../dashboard/dashboard_providers.dart' show apiClientProvider;

/// Notifier managing the current query (date, range, filter sets).
/// Widgets read & mutate this; the entries provider watches it.
class ActivityQueryNotifier extends StateNotifier<ActivityQuery> {
  ActivityQueryNotifier() : super(_today());

  static ActivityQuery _today() {
    final now = DateTime.now();
    return ActivityQuery(date: DateTime(now.year, now.month, now.day));
  }

  void setDate(DateTime day) {
    state = ActivityQuery(
      date: DateTime(day.year, day.month, day.day),
      orgs: state.orgs,
      repos: state.repos,
      actions: state.actions,
      limit: state.limit,
    );
  }

  void setRange(DateTime from, DateTime to) {
    state = ActivityQuery(
      from: DateTime(from.year, from.month, from.day),
      to:   DateTime(to.year, to.month, to.day),
      orgs: state.orgs,
      repos: state.repos,
      actions: state.actions,
      limit: state.limit,
    );
  }

  void toggleOrg(String org)    => _replace(orgs:    _toggled(state.orgs,    org));
  void toggleRepo(String repo)  => _replace(repos:   _toggled(state.repos,   repo));
  void toggleAction(ActivityAction a) =>
      _replace(actions: _toggled(state.actions, a));

  void clearFilters() =>
      _replace(orgs: const {}, repos: const {}, actions: const {});

  void _replace({
    Set<String>? orgs,
    Set<String>? repos,
    Set<ActivityAction>? actions,
  }) {
    state = ActivityQuery(
      date:    state.date,
      from:    state.from,
      to:      state.to,
      orgs:    orgs    ?? state.orgs,
      repos:   repos   ?? state.repos,
      actions: actions ?? state.actions,
      limit:   state.limit,
    );
  }

  static Set<T> _toggled<T>(Set<T> set, T v) {
    final next = Set<T>.from(set);
    if (!next.add(v)) next.remove(v);
    return next;
  }
}

/// Current query state.
final activityQueryProvider =
    StateNotifierProvider<ActivityQueryNotifier, ActivityQuery>(
  (ref) => ActivityQueryNotifier(),
);

/// Entries for the current query. Watches the query so filter changes
/// trigger a refetch automatically.
final activityEntriesProvider = FutureProvider<ActivityPage>((ref) async {
  final q = ref.watch(activityQueryProvider);
  final api = ref.watch(apiClientProvider);
  return api.fetchActivity(q);
});
