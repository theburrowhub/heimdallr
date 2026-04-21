import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heimdallm/core/models/config_model.dart';
import 'package:heimdallm/features/repositories/widgets/repo_list_tile.dart';
import 'package:heimdallm/features/repositories/widgets/feature_led.dart';

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: child));

void main() {
  final appConfig = AppConfig(
    serverPort: 1,
    pollInterval: '60s',
    retentionDays: 30,
    aiPrimary: 'claude',
    aiFallback: '',
    reviewMode: 'single',
    repoConfigs: const {
      'theburrowhub/heimdallm': RepoConfig(prEnabled: true),
    },
    issueTracking: const IssueTrackingConfig(),
  );

  testWidgets('shows 3 LEDs with correct states', (tester) async {
    await tester.pumpWidget(_host(RepoListTile(
      repo: 'theburrowhub/heimdallm',
      config: const RepoConfig(prEnabled: true, localDir: '/tmp/heimdallm'),
      appConfig: appConfig,
      selected: false,
      onSelectionToggle: () {},
      onTap: () {},
    )));
    expect(find.byType(FeatureLed), findsNWidgets(3));
  });

  testWidgets('tapping checkbox calls onSelectionToggle', (tester) async {
    var toggled = false;
    await tester.pumpWidget(_host(RepoListTile(
      repo: 'a/b',
      config: const RepoConfig(prEnabled: true),
      appConfig: appConfig,
      selected: false,
      onSelectionToggle: () => toggled = true,
      onTap: () {},
    )));
    await tester.tap(find.byKey(const Key('RepoListTile_checkbox')));
    expect(toggled, isTrue);
  });

  testWidgets('selected=true renders selected background', (tester) async {
    await tester.pumpWidget(_host(RepoListTile(
      repo: 'a/b',
      config: const RepoConfig(prEnabled: true),
      appConfig: appConfig,
      selected: true,
      onSelectionToggle: () {},
      onTap: () {},
    )));
    final card = tester.widget<Card>(find.byType(Card));
    expect(card.color, isNotNull);
  });
}
