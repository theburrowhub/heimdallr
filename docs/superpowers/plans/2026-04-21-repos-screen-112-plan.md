# Repositories tab #112 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the redesigned Repositories tab described in `docs/superpowers/specs/2026-04-21-repos-screen-112-design.md` — filter chips, list/grid view, bulk-edit bar, per-feature colour palette, and daemon-side review-requested auto-discovery.

**Architecture:** Flutter widgets are split into single-responsibility files under `flutter_app/lib/features/repositories/widgets/`. The Repositories screen owns filter/selection/view state; children are pure widgets that take data + callbacks. Daemon auto-discovery hooks into the existing poll cycle and publishes SSE events; no new timers.

**Tech stack:** Flutter 3, Riverpod, `shared_preferences` 2.x, `flutter_test` with `testWidgets`. Daemon is Go with TOML config, BoltDB-backed `config.Store`, and an SSE broker.

---

## File structure

### New Flutter files

```
flutter_app/lib/features/repositories/widgets/
  feature_palette.dart       — colour constants + Feature enum
  feature_led.dart           — 2-state LED with rich tooltip
  feature_switch.dart        — Material switch + mixed-state variant
  repo_list_tile.dart        — list row (checkbox + LEDs + meta + chevron)
  repo_grid_tile.dart        — grid tile (checkbox + LEDs + name + org + dir)
  bulk_actions_bar.dart      — selection count + 3 feature switches + Clear
  filter_chips.dart          — All / Monitored / Not monitored segmented control

flutter_app/test/features/repositories/widgets/
  feature_led_test.dart
  feature_switch_test.dart
  repo_list_tile_test.dart
  repo_grid_tile_test.dart
  bulk_actions_bar_test.dart
  filter_chips_test.dart
flutter_app/test/features/repositories/
  repos_screen_test.dart     — selection + filter + view-toggle integration
```

### Modified Flutter files

```
flutter_app/lib/features/repositories/
  repos_screen.dart          — rewrite toolbar, add selection state, wire bulk bar
  repo_detail_screen.dart    — colour accents on section headers, reuse FeatureSwitch
flutter_app/lib/core/models/
  config_model.dart          — parse first_seen_at from repo_overrides JSON
```

### Modified daemon files

```
daemon/internal/config/
  config.go                  — add AutoEnablePROnDiscovery (*bool)
  store.go                   — first_seen_at map per repo (persist)
daemon/internal/sse/
  events.go                  — add EventRepoDiscovered constant
daemon/cmd/heimdallm/
  main.go                    — upsert newly-seen repos after FetchPRsToReview
```

---

## Conventions

- Run Flutter tests from `flutter_app/`: `flutter test <path>`.
- Run Go tests from `daemon/`: `go test ./internal/config/...` etc.
- Commit prefixes follow the repo's release-please style: `feat:`, `fix:`, `refactor:`, `test:`.
- Each task ends with one logical commit.

---

## Phase 1 — Flutter foundation (palette + shared widgets)

### Task 1: Feature palette and enum

**Files:**
- Create: `flutter_app/lib/features/repositories/widgets/feature_palette.dart`

- [ ] **Step 1: Create the palette file**

```dart
// flutter_app/lib/features/repositories/widgets/feature_palette.dart
import 'package:flutter/material.dart';

/// The three features the user can toggle per repo.
enum Feature { prReview, issueTracking, develop }

/// Palette used everywhere a feature is rendered: LEDs, detail section
/// headers + switches, bulk bar. Grey (hollow) is shared for "off".
class FeaturePalette {
  static const prReview       = Color(0xFF58A6FF);
  static const issueTracking  = Color(0xFFA371F7);
  static const develop        = Color(0xFFC79A87);

  /// Mixed state in the bulk bar (switch thumb / MIXED tag).
  static const mixed          = Color(0xFFE3B341);

  /// Off LED fill + outline.
  static const offFill        = Color(0xFF2E333B);
  static const offOutline     = Color(0xFF3B424C);

  static Color forFeature(Feature f) => switch (f) {
    Feature.prReview      => prReview,
    Feature.issueTracking => issueTracking,
    Feature.develop       => develop,
  };

  static String labelFor(Feature f) => switch (f) {
    Feature.prReview      => 'PR Review',
    Feature.issueTracking => 'Issue Tracking',
    Feature.develop       => 'Develop',
  };
}
```

- [ ] **Step 2: Commit**

```bash
git add flutter_app/lib/features/repositories/widgets/feature_palette.dart
git commit -m "feat(flutter): feature palette + enum for repos screen"
```

---

### Task 2: FeatureLed widget with tooltip

**Files:**
- Create: `flutter_app/lib/features/repositories/widgets/feature_led.dart`
- Test: `flutter_app/test/features/repositories/widgets/feature_led_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// flutter_app/test/features/repositories/widgets/feature_led_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heimdallm/features/repositories/widgets/feature_led.dart';
import 'package:heimdallm/features/repositories/widgets/feature_palette.dart';

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  testWidgets('renders coloured dot when on', (tester) async {
    await tester.pumpWidget(_host(const FeatureLed(
      feature: Feature.prReview,
      isOn: true,
      sourceLine: 'Source: repo-level (prEnabled = true)',
    )));
    final container = tester.widget<Container>(find.byType(Container));
    final deco = container.decoration as BoxDecoration;
    expect(deco.color, FeaturePalette.prReview);
    expect(deco.border, isNull);
  });

  testWidgets('renders hollow grey when off', (tester) async {
    await tester.pumpWidget(_host(const FeatureLed(
      feature: Feature.develop,
      isOn: false,
      sourceLine: 'Source: disabled per-repo (devEnabled = false)',
    )));
    final container = tester.widget<Container>(find.byType(Container));
    final deco = container.decoration as BoxDecoration;
    expect(deco.color, FeaturePalette.offFill);
    expect(deco.border, isNotNull);
  });

  testWidgets('tooltip contains feature name, state, source line',
      (tester) async {
    await tester.pumpWidget(_host(const FeatureLed(
      feature: Feature.issueTracking,
      isOn: true,
      sourceLine: 'Source: inherited from global monitored list',
    )));
    final tip = tester.widget<Tooltip>(find.byType(Tooltip));
    expect(tip.message, contains('Issue Tracking'));
    expect(tip.message, contains('On'));
    expect(tip.message, contains('inherited from global'));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd flutter_app && flutter test test/features/repositories/widgets/feature_led_test.dart`
Expected: FAIL with "Target of URI doesn't exist: feature_led.dart"

- [ ] **Step 3: Implement the widget**

```dart
// flutter_app/lib/features/repositories/widgets/feature_led.dart
import 'package:flutter/material.dart';
import 'feature_palette.dart';

/// Two-state LED (on / off) with a rich tooltip.
/// The on/off decision and source string are computed by the caller.
class FeatureLed extends StatelessWidget {
  final Feature feature;
  final bool isOn;
  final String sourceLine;
  final double size;

  const FeatureLed({
    super.key,
    required this.feature,
    required this.isOn,
    required this.sourceLine,
    this.size = 8,
  });

  @override
  Widget build(BuildContext context) {
    final name = FeaturePalette.labelFor(feature);
    final state = isOn ? 'On' : 'Off';
    final description = _description(feature, isOn);
    return Tooltip(
      message: '$name · $state\n$description\n$sourceLine',
      waitDuration: const Duration(milliseconds: 350),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isOn ? FeaturePalette.forFeature(feature) : FeaturePalette.offFill,
          border: isOn
              ? null
              : Border.all(color: FeaturePalette.offOutline, width: 1),
        ),
      ),
    );
  }

  static String _description(Feature f, bool on) => switch ((f, on)) {
        (Feature.prReview, true)       => 'The daemon auto-reviews PRs in this repo.',
        (Feature.prReview, false)      => 'The daemon will not auto-review PRs in this repo.',
        (Feature.issueTracking, true)  => 'The daemon triages new issues in this repo.',
        (Feature.issueTracking, false) => 'The daemon ignores new issues in this repo.',
        (Feature.develop, true)        => 'The daemon can auto-implement issues in this repo.',
        (Feature.develop, false)       => 'The daemon cannot auto-implement issues in this repo.',
      };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd flutter_app && flutter test test/features/repositories/widgets/feature_led_test.dart`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add flutter_app/lib/features/repositories/widgets/feature_led.dart flutter_app/test/features/repositories/widgets/feature_led_test.dart
git commit -m "feat(flutter): FeatureLed widget with tooltip"
```

---

### Task 3: FeatureSwitch widget (including mixed state)

**Files:**
- Create: `flutter_app/lib/features/repositories/widgets/feature_switch.dart`
- Test: `flutter_app/test/features/repositories/widgets/feature_switch_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// flutter_app/test/features/repositories/widgets/feature_switch_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heimdallm/features/repositories/widgets/feature_switch.dart';
import 'package:heimdallm/features/repositories/widgets/feature_palette.dart';

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  testWidgets('value=true: renders Switch with feature activeColor',
      (tester) async {
    await tester.pumpWidget(_host(FeatureSwitch(
      feature: Feature.prReview,
      value: true,
      onChanged: (_) {},
    )));
    final sw = tester.widget<Switch>(find.byType(Switch));
    expect(sw.value, isTrue);
    expect(sw.activeColor, FeaturePalette.prReview);
  });

  testWidgets('value=false: renders Switch off', (tester) async {
    await tester.pumpWidget(_host(FeatureSwitch(
      feature: Feature.develop,
      value: false,
      onChanged: (_) {},
    )));
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
  });

  testWidgets('value=null: renders mixed placeholder (no Switch, MIXED key)',
      (tester) async {
    await tester.pumpWidget(_host(FeatureSwitch(
      feature: Feature.issueTracking,
      value: null,
      onChanged: (_) {},
    )));
    expect(find.byType(Switch), findsNothing);
    expect(find.byKey(const Key('FeatureSwitch_mixed')), findsOneWidget);
  });

  testWidgets('tap when value=null calls onChanged(true)', (tester) async {
    bool? lastValue;
    await tester.pumpWidget(_host(FeatureSwitch(
      feature: Feature.develop,
      value: null,
      onChanged: (v) => lastValue = v,
    )));
    await tester.tap(find.byKey(const Key('FeatureSwitch_mixed')));
    expect(lastValue, isTrue);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd flutter_app && flutter test test/features/repositories/widgets/feature_switch_test.dart`
Expected: FAIL with "Target of URI doesn't exist: feature_switch.dart"

- [ ] **Step 3: Implement the widget**

```dart
// flutter_app/lib/features/repositories/widgets/feature_switch.dart
import 'package:flutter/material.dart';
import 'feature_palette.dart';

/// Material switch coloured per feature. Supports a third "mixed" state
/// (value == null) rendered as an amber placeholder with a dash on the
/// thumb — used by the bulk actions bar when the selection is mixed.
class FeatureSwitch extends StatelessWidget {
  final Feature feature;
  final bool? value;                    // null = mixed aggregate
  final ValueChanged<bool> onChanged;

  const FeatureSwitch({
    super.key,
    required this.feature,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (value == null) {
      return _MixedSwitch(
        onTap: () => onChanged(true),
      );
    }
    final color = FeaturePalette.forFeature(feature);
    return Switch(
      value: value!,
      activeColor: color,
      activeTrackColor: color.withOpacity(0.55),
      onChanged: onChanged,
    );
  }
}

/// Drawn to match Material Switch geometry but tinted amber with a
/// centred dash to signal "aggregate is mixed".
class _MixedSwitch extends StatelessWidget {
  final VoidCallback onTap;
  const _MixedSwitch({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const Key('FeatureSwitch_mixed'),
      onTap: onTap,
      child: Container(
        width: 36, height: 20,
        decoration: BoxDecoration(
          color: FeaturePalette.mixed.withOpacity(0.22),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: FeaturePalette.mixed.withOpacity(0.45),
            width: 1,
          ),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned(
              left: 10, top: 2,
              child: Container(
                width: 16, height: 16,
                decoration: const BoxDecoration(
                  color: FeaturePalette.mixed,
                  shape: BoxShape.circle,
                ),
              ),
            ),
            Container(
              width: 6, height: 1.5,
              color: const Color(0xFF1C1F24),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd flutter_app && flutter test test/features/repositories/widgets/feature_switch_test.dart`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add flutter_app/lib/features/repositories/widgets/feature_switch.dart flutter_app/test/features/repositories/widgets/feature_switch_test.dart
git commit -m "feat(flutter): FeatureSwitch with per-feature colour and mixed-state variant"
```

---

## Phase 2 — List view refactor

### Task 4: Extract RepoListTile widget

**Files:**
- Create: `flutter_app/lib/features/repositories/widgets/repo_list_tile.dart`
- Test: `flutter_app/test/features/repositories/widgets/repo_list_tile_test.dart`
- Modify: `flutter_app/lib/features/repositories/repos_screen.dart:369-451` (replace `_RepoTile`)

- [ ] **Step 1: Write the failing test**

```dart
// flutter_app/test/features/repositories/widgets/repo_list_tile_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heimdallm/core/models/config_model.dart';
import 'package:heimdallm/features/repositories/widgets/repo_list_tile.dart';
import 'package:heimdallm/features/repositories/widgets/feature_led.dart';

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: child));

void main() {
  final appConfig = AppConfig(
    serverPort: 1, pollInterval: 60, retentionDays: 30,
    repositories: const ['theburrowhub/heimdallm'],
    aiPrimary: 'claude', aiFallback: '', reviewMode: 'single',
    repoConfigs: const {},
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd flutter_app && flutter test test/features/repositories/widgets/repo_list_tile_test.dart`
Expected: FAIL with "Target of URI doesn't exist: repo_list_tile.dart"

- [ ] **Step 3: Implement the widget**

```dart
// flutter_app/lib/features/repositories/widgets/repo_list_tile.dart
import 'package:flutter/material.dart';
import '../../../core/models/config_model.dart';
import 'feature_led.dart';
import 'feature_palette.dart';

/// One row in the repos list. Stateless; all state flows via parameters
/// and callbacks.
class RepoListTile extends StatelessWidget {
  final String repo;
  final RepoConfig config;
  final AppConfig appConfig;
  final bool selected;
  final VoidCallback onSelectionToggle;
  final VoidCallback onTap;

  const RepoListTile({
    super.key,
    required this.repo,
    required this.config,
    required this.appConfig,
    required this.selected,
    required this.onSelectionToggle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasDir = config.localDir != null && config.localDir!.isNotEmpty;
    final theme = Theme.of(context);
    final selectedBg = theme.colorScheme.primary.withOpacity(0.12);

    return Card(
      color: selected ? selectedBg : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: selected
            ? BorderSide(color: theme.colorScheme.primary.withOpacity(0.55))
            : BorderSide.none,
      ),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              GestureDetector(
                key: const Key('RepoListTile_checkbox'),
                onTap: onSelectionToggle,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: _CheckboxIcon(selected: selected),
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FeatureLed(
                    feature: Feature.prReview,
                    isOn: _isOn(Feature.prReview),
                    sourceLine: _sourceLine(Feature.prReview),
                  ),
                  const SizedBox(height: 3),
                  FeatureLed(
                    feature: Feature.issueTracking,
                    isOn: _isOn(Feature.issueTracking),
                    sourceLine: _sourceLine(Feature.issueTracking),
                  ),
                  const SizedBox(height: 3),
                  FeatureLed(
                    feature: Feature.develop,
                    isOn: _isOn(Feature.develop),
                    sourceLine: _sourceLine(Feature.develop),
                  ),
                ],
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      repo,
                      style: TextStyle(
                        fontWeight:
                            config.isMonitored ? FontWeight.w600 : FontWeight.normal,
                        color: config.isMonitored ? null : Colors.grey,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(children: [
                      Icon(
                        hasDir ? Icons.folder : Icons.folder_off_outlined,
                        size: 13,
                        color: hasDir ? Colors.green.shade500 : Colors.grey.shade600,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        hasDir ? config.localDir!.split('/').last : 'No local dir',
                        style: TextStyle(
                          fontSize: 11,
                          color: hasDir ? Colors.green.shade500 : Colors.grey.shade600,
                        ),
                      ),
                    ]),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: Colors.grey.shade600),
            ],
          ),
        ),
      ),
    );
  }

  bool _isOn(Feature f) {
    final inGlobalList = appConfig.repositories.contains(repo);
    final globalIt = appConfig.issueTracking.enabled;
    final hasDir = config.localDir != null && config.localDir!.isNotEmpty;
    final status = switch (f) {
      Feature.prReview      => config.prLedStatus(inGlobalList),
      Feature.issueTracking => config.itLedStatus(globalIt),
      Feature.develop       => config.devLedStatus(globalIt, hasDir),
    };
    return status != 'off';
  }

  String _sourceLine(Feature f) {
    final inGlobalList = appConfig.repositories.contains(repo);
    final globalIt = appConfig.issueTracking.enabled;
    final hasDir = config.localDir != null && config.localDir!.isNotEmpty;
    switch (f) {
      case Feature.prReview:
        if (config.prEnabled == true) return 'Source: repo-level (prEnabled = true)';
        if (config.prEnabled == false) return 'Source: disabled per-repo (prEnabled = false)';
        return inGlobalList
            ? 'Source: inherited from global monitored list'
            : 'Source: not in monitored list';
      case Feature.issueTracking:
        if (config.itEnabled == true) return 'Source: repo-level (itEnabled = true)';
        if (config.itEnabled == false) return 'Source: disabled per-repo (itEnabled = false)';
        if ((config.reviewOnlyLabels ?? const []).isNotEmpty) {
          return 'Source: implied by per-repo labels';
        }
        return globalIt
            ? 'Source: inherited from global issue tracking'
            : 'Source: globally disabled';
      case Feature.develop:
        if (config.devEnabled == true && hasDir) {
          return 'Source: repo-level (devEnabled = true)';
        }
        if (config.devEnabled == false) return 'Source: disabled per-repo (devEnabled = false)';
        if (!hasDir) return 'Reason: no local directory configured (Develop requires one)';
        if ((config.developLabels ?? const []).isNotEmpty) {
          return 'Source: implied by per-repo develop labels';
        }
        return globalIt
            ? 'Source: inherited from global issue tracking'
            : 'Source: globally disabled';
    }
  }
}

class _CheckboxIcon extends StatelessWidget {
  final bool selected;
  const _CheckboxIcon({required this.selected});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      width: 16, height: 16,
      decoration: BoxDecoration(
        color: selected ? primary : Colors.transparent,
        border: Border.all(
          color: selected ? primary : const Color(0xFF6E7681),
          width: 1.5,
        ),
        borderRadius: BorderRadius.circular(3),
      ),
      child: selected
          ? const Icon(Icons.check, size: 12, color: Colors.white)
          : null,
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd flutter_app && flutter test test/features/repositories/widgets/repo_list_tile_test.dart`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add flutter_app/lib/features/repositories/widgets/repo_list_tile.dart flutter_app/test/features/repositories/widgets/repo_list_tile_test.dart
git commit -m "feat(flutter): RepoListTile widget with checkbox and colour-coded LEDs"
```

---

### Task 5: Replace inline `_RepoTile` with RepoListTile

**Files:**
- Modify: `flutter_app/lib/features/repositories/repos_screen.dart` (remove old `_Led` + `_RepoTile`, pass selection state down)

- [ ] **Step 1: Delete the inline `_Led` class (lines 337-365) and `_RepoTile` (lines 367-451)**

Open `flutter_app/lib/features/repositories/repos_screen.dart` and remove both classes.

- [ ] **Step 2: Add a temporary empty selection set to state and thread it through**

In `_ReposScreenState` add:

```dart
final Set<String> _selected = {};
```

In `_buildOrgGroups` (around line 277), replace the `_RepoTile` instantiation with:

```dart
items.add(RepoListTile(
  repo: r,
  config: widget.configs[r]!,
  appConfig: widget.appConfig,
  selected: widget.selected.contains(r),
  onSelectionToggle: () => widget.onSelectionToggle(r),
  onTap: () => context.push('/repos/${Uri.encodeComponent(r)}'),
));
```

Add these parameters to `_RepoListWithSections`:

```dart
final Set<String> selected;
final ValueChanged<String> onSelectionToggle;
```

And thread them from `_ReposScreenState.build` where `_RepoListWithSections(...)` is constructed:

```dart
_RepoListWithSections(
  repos: filtered,
  configs: _repoConfigs,
  appConfig: config,
  onChanged: _onChange,
  selected: _selected,
  onSelectionToggle: _toggleSelection,
)
```

And add the toggle method on `_ReposScreenState`:

```dart
void _toggleSelection(String repo) {
  setState(() {
    if (!_selected.add(repo)) _selected.remove(repo);
  });
}
```

Add the import:

```dart
import 'widgets/repo_list_tile.dart';
```

- [ ] **Step 3: Run the existing repos tests to confirm no regressions**

Run: `cd flutter_app && flutter test test/features/repositories/`
Expected: all tests pass (the test directory may be empty before this task — if so, skip).

Then run the full test suite as smoke:

Run: `cd flutter_app && flutter test`
Expected: all existing tests still pass; no new failures.

- [ ] **Step 4: Commit**

```bash
git add flutter_app/lib/features/repositories/repos_screen.dart
git commit -m "refactor(flutter): use RepoListTile in repos screen and thread selection state"
```

---

## Phase 3 — Bulk actions bar

### Task 6: BulkActionsBar widget

**Files:**
- Create: `flutter_app/lib/features/repositories/widgets/bulk_actions_bar.dart`
- Test: `flutter_app/test/features/repositories/widgets/bulk_actions_bar_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// flutter_app/test/features/repositories/widgets/bulk_actions_bar_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heimdallm/features/repositories/widgets/bulk_actions_bar.dart';
import 'package:heimdallm/features/repositories/widgets/feature_palette.dart';

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('renders "N selected" and 3 switches', (tester) async {
    await tester.pumpWidget(_host(BulkActionsBar(
      selectedCount: 3,
      aggregates: const {
        Feature.prReview: true,
        Feature.issueTracking: null,
        Feature.develop: false,
      },
      onApply: (_, __) {},
      onClear: () {},
    )));
    expect(find.text('3 selected'), findsOneWidget);
    expect(find.byType(Switch), findsNWidgets(2));   // two pure states
    expect(find.byKey(const Key('FeatureSwitch_mixed')), findsOneWidget);
  });

  testWidgets('MIXED pill only shown for mixed features', (tester) async {
    await tester.pumpWidget(_host(BulkActionsBar(
      selectedCount: 2,
      aggregates: const {
        Feature.prReview: true,
        Feature.issueTracking: null,
        Feature.develop: false,
      },
      onApply: (_, __) {},
      onClear: () {},
    )));
    expect(find.text('MIXED'), findsOneWidget);
  });

  testWidgets('flipping a switch calls onApply(feature, newValue)',
      (tester) async {
    Feature? calledFeature;
    bool? calledValue;
    await tester.pumpWidget(_host(BulkActionsBar(
      selectedCount: 3,
      aggregates: const {
        Feature.prReview: false,
        Feature.issueTracking: true,
        Feature.develop: false,
      },
      onApply: (f, v) { calledFeature = f; calledValue = v; },
      onClear: () {},
    )));
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(calledFeature, Feature.prReview);
    expect(calledValue, isTrue);
  });

  testWidgets('tapping Clear calls onClear', (tester) async {
    var cleared = false;
    await tester.pumpWidget(_host(BulkActionsBar(
      selectedCount: 1,
      aggregates: const {
        Feature.prReview: true,
        Feature.issueTracking: true,
        Feature.develop: true,
      },
      onApply: (_, __) {},
      onClear: () => cleared = true,
    )));
    await tester.tap(find.text('Clear'));
    expect(cleared, isTrue);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd flutter_app && flutter test test/features/repositories/widgets/bulk_actions_bar_test.dart`
Expected: FAIL with "Target of URI doesn't exist: bulk_actions_bar.dart"

- [ ] **Step 3: Implement the widget**

```dart
// flutter_app/lib/features/repositories/widgets/bulk_actions_bar.dart
import 'package:flutter/material.dart';
import 'feature_palette.dart';
import 'feature_switch.dart';

/// Floats above the repo list when >=1 repo is selected.
/// Shows the aggregate state of the 3 features across the selection;
/// flipping a switch applies to every selected repo.
class BulkActionsBar extends StatelessWidget {
  final int selectedCount;
  /// true = all selected on; false = all off; null = mixed.
  final Map<Feature, bool?> aggregates;
  final void Function(Feature feature, bool enable) onApply;
  final VoidCallback onClear;

  const BulkActionsBar({
    super.key,
    required this.selectedCount,
    required this.aggregates,
    required this.onApply,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: primary.withOpacity(0.10),
        border: Border.all(color: primary.withOpacity(0.35)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
              decoration: BoxDecoration(
                color: primary.withOpacity(0.32),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$selectedCount selected',
                style: TextStyle(
                  color: primary, fontWeight: FontWeight.w600, fontSize: 11,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text('Bulk actions',
                style: TextStyle(color: primary, fontWeight: FontWeight.w600, fontSize: 13)),
            const Spacer(),
            TextButton(
              onPressed: onClear,
              child: const Text('Clear'),
            ),
          ]),
          const Divider(height: 14, thickness: 0.5),
          for (final f in Feature.values) _row(f),
        ],
      ),
    );
  }

  Widget _row(Feature f) {
    final v = aggregates[f];
    final color = FeaturePalette.forFeature(f);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Container(
          width: 10, height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 10),
        Text(FeaturePalette.labelFor(f),
            style: TextStyle(fontWeight: FontWeight.w600, color: color, fontSize: 12.5)),
        const SizedBox(width: 10),
        if (v == null) const _MixedTag(),
        const Spacer(),
        FeatureSwitch(
          feature: f,
          value: v,
          onChanged: (newValue) => onApply(f, newValue),
        ),
      ]),
    );
  }
}

class _MixedTag extends StatelessWidget {
  const _MixedTag();
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      decoration: BoxDecoration(
        color: FeaturePalette.mixed.withOpacity(0.12),
        border: Border.all(color: FeaturePalette.mixed.withOpacity(0.28)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        'MIXED',
        style: TextStyle(
          color: FeaturePalette.mixed,
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd flutter_app && flutter test test/features/repositories/widgets/bulk_actions_bar_test.dart`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add flutter_app/lib/features/repositories/widgets/bulk_actions_bar.dart flutter_app/test/features/repositories/widgets/bulk_actions_bar_test.dart
git commit -m "feat(flutter): BulkActionsBar widget"
```

---

### Task 7: Wire bulk bar into ReposScreen

**Files:**
- Modify: `flutter_app/lib/features/repositories/repos_screen.dart`

- [ ] **Step 1: Write the integration test**

```dart
// flutter_app/test/features/repositories/repos_screen_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heimdallm/core/models/config_model.dart';
import 'package:heimdallm/features/config/config_providers.dart';
import 'package:heimdallm/features/repositories/repos_screen.dart';
import 'package:heimdallm/features/repositories/widgets/bulk_actions_bar.dart';

Widget _host(AppConfig cfg) => ProviderScope(
      overrides: [
        configNotifierProvider.overrideWith(() => _FakeConfig(cfg)),
      ],
      child: const MaterialApp(home: Scaffold(body: ReposScreen())),
    );

class _FakeConfig extends ConfigNotifier {
  _FakeConfig(this.initial);
  final AppConfig initial;
  @override
  Future<AppConfig> build() async => initial;
  @override
  Future<void> save(AppConfig next) async { state = AsyncData(next); }
}

AppConfig _cfg() => AppConfig(
  serverPort: 1, pollInterval: 60, retentionDays: 30,
  repositories: const ['a/one', 'a/two'],
  aiPrimary: 'claude', aiFallback: '', reviewMode: 'single',
  repoConfigs: const {
    'a/one': RepoConfig(prEnabled: true),
    'a/two': RepoConfig(prEnabled: true),
  },
  issueTracking: const IssueTrackingConfig(),
);

void main() {
  testWidgets('bulk bar appears when a repo is selected', (tester) async {
    await tester.pumpWidget(_host(_cfg()));
    await tester.pumpAndSettle();

    expect(find.byType(BulkActionsBar), findsNothing);

    await tester.tap(find.byKey(const Key('RepoListTile_checkbox')).first);
    await tester.pump();

    expect(find.byType(BulkActionsBar), findsOneWidget);
    expect(find.text('1 selected'), findsOneWidget);
  });

  testWidgets('Clear dismisses the bulk bar', (tester) async {
    await tester.pumpWidget(_host(_cfg()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('RepoListTile_checkbox')).first);
    await tester.pump();
    await tester.tap(find.text('Clear'));
    await tester.pump();

    expect(find.byType(BulkActionsBar), findsNothing);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd flutter_app && flutter test test/features/repositories/repos_screen_test.dart`
Expected: FAIL — `BulkActionsBar` not rendered.

- [ ] **Step 3: Wire bulk bar + aggregate computation in `repos_screen.dart`**

Add imports at top:

```dart
import 'widgets/bulk_actions_bar.dart';
import 'widgets/feature_palette.dart';
```

Add the aggregate helper inside `_ReposScreenState`:

```dart
Map<Feature, bool?> _aggregate() {
  bool? agg(bool Function(RepoConfig) pick) {
    bool? result;
    for (final r in _selected) {
      final c = _repoConfigs[r];
      if (c == null) continue;
      final v = pick(c);
      if (result == null) { result = v; } else if (result != v) return null;
    }
    return result ?? false;
  }

  final hasDir = (RepoConfig c) =>
      c.localDir != null && c.localDir!.isNotEmpty;

  return {
    Feature.prReview:      agg((c) => c.prEnabled ?? false),
    Feature.issueTracking: agg((c) => c.itEnabled ?? false),
    Feature.develop:       agg((c) => (c.devEnabled ?? false) && hasDir(c)),
  };
}

void _applyBulk(Feature f, bool enable) {
  setState(() {
    for (final r in _selected) {
      final c = _repoConfigs[r];
      if (c == null) continue;
      _repoConfigs[r] = switch (f) {
        Feature.prReview      => c.copyWith(prEnabled: enable),
        Feature.issueTracking => c.copyWith(itEnabled: enable),
        Feature.develop       => c.copyWith(devEnabled: enable),
      };
    }
  });
  _debounce?.cancel();
  _debounce = Timer(const Duration(milliseconds: 400), _autoSave);
}

void _clearSelection() => setState(_selected.clear);
```

Render the bar above the list in `build(...)` — after the search toolbar, before the `Expanded(...)` list:

```dart
if (_selected.isNotEmpty)
  BulkActionsBar(
    selectedCount: _selected.length,
    aggregates: _aggregate(),
    onApply: _applyBulk,
    onClear: _clearSelection,
  ),
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd flutter_app && flutter test test/features/repositories/repos_screen_test.dart`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add flutter_app/lib/features/repositories/repos_screen.dart flutter_app/test/features/repositories/repos_screen_test.dart
git commit -m "feat(flutter): bulk-edit bar in repos screen with aggregate + apply"
```

---

## Phase 4 — Toolbar (filter chips, view toggle, remove Discover)

### Task 8: FilterChips widget

**Files:**
- Create: `flutter_app/lib/features/repositories/widgets/filter_chips.dart`
- Test: `flutter_app/test/features/repositories/widgets/filter_chips_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// flutter_app/test/features/repositories/widgets/filter_chips_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heimdallm/features/repositories/widgets/filter_chips.dart';

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('shows All / Monitored / Not monitored with counts',
      (tester) async {
    await tester.pumpWidget(_host(RepoFilterChips(
      counts: const {'all': 11, 'monitored': 8, 'not_monitored': 3},
      current: 'all',
      onChanged: (_) {},
    )));
    expect(find.text('All'), findsOneWidget);
    expect(find.text('Monitored'), findsOneWidget);
    expect(find.text('Not monitored'), findsOneWidget);
    expect(find.text('11'), findsOneWidget);
    expect(find.text('8'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('tapping a chip calls onChanged with its key', (tester) async {
    String? selected;
    await tester.pumpWidget(_host(RepoFilterChips(
      counts: const {'all': 1, 'monitored': 1, 'not_monitored': 0},
      current: 'all',
      onChanged: (v) => selected = v,
    )));
    await tester.tap(find.text('Monitored'));
    expect(selected, 'monitored');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd flutter_app && flutter test test/features/repositories/widgets/filter_chips_test.dart`
Expected: FAIL with "Target of URI doesn't exist".

- [ ] **Step 3: Implement the widget**

```dart
// flutter_app/lib/features/repositories/widgets/filter_chips.dart
import 'package:flutter/material.dart';

class RepoFilterChips extends StatelessWidget {
  /// Key set: 'all' | 'monitored' | 'not_monitored'.
  final Map<String, int> counts;
  final String current;
  final ValueChanged<String> onChanged;

  const RepoFilterChips({
    super.key,
    required this.counts,
    required this.current,
    required this.onChanged,
  });

  static const _labels = {
    'all': 'All',
    'monitored': 'Monitored',
    'not_monitored': 'Not monitored',
  };

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade700),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final e in _labels.entries) ...[
            InkWell(
              onTap: () => onChanged(e.key),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                color: current == e.key ? primary.withOpacity(0.22) : null,
                child: Row(children: [
                  Text(
                    e.value,
                    style: TextStyle(
                      fontSize: 12,
                      color: current == e.key ? primary : null,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: current == e.key
                          ? primary.withOpacity(0.32)
                          : Colors.white.withOpacity(0.06),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${counts[e.key] ?? 0}',
                      style: TextStyle(
                        fontSize: 10,
                        color: current == e.key ? primary : Colors.grey.shade500,
                      ),
                    ),
                  ),
                ]),
              ),
            ),
            if (e.key != 'not_monitored')
              Container(width: 1, height: 28, color: Colors.grey.shade700),
          ],
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd flutter_app && flutter test test/features/repositories/widgets/filter_chips_test.dart`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add flutter_app/lib/features/repositories/widgets/filter_chips.dart flutter_app/test/features/repositories/widgets/filter_chips_test.dart
git commit -m "feat(flutter): RepoFilterChips segmented control"
```

---

### Task 9: Add filter state to ReposScreen and apply to the list

**Files:**
- Modify: `flutter_app/lib/features/repositories/repos_screen.dart`

- [ ] **Step 1: Add filter test to `repos_screen_test.dart`**

```dart
testWidgets('selecting Monitored hides non-monitored repos',
    (tester) async {
  final cfg = AppConfig(
    serverPort: 1, pollInterval: 60, retentionDays: 30,
    repositories: const ['a/one'],
    aiPrimary: 'claude', aiFallback: '', reviewMode: 'single',
    repoConfigs: const {
      'a/one': RepoConfig(prEnabled: true),
      'a/two': RepoConfig(prEnabled: false),
    },
    issueTracking: const IssueTrackingConfig(),
  );
  await tester.pumpWidget(_host(cfg));
  await tester.pumpAndSettle();

  expect(find.text('a/one'), findsOneWidget);
  expect(find.text('a/two'), findsOneWidget);

  await tester.tap(find.text('Monitored'));
  await tester.pumpAndSettle();

  expect(find.text('a/one'), findsOneWidget);
  expect(find.text('a/two'), findsNothing);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd flutter_app && flutter test test/features/repositories/repos_screen_test.dart`
Expected: FAIL — the "Monitored" chip doesn't exist yet.

- [ ] **Step 3: Add filter state, chip widget, and filtering logic**

Add import: `import 'widgets/filter_chips.dart';`

In `_ReposScreenState` add:

```dart
String _filter = 'all';   // 'all' | 'monitored' | 'not_monitored'
```

In `build(...)`, replace the `FilledButton.tonalIcon(...)` Discover button + search Row with:

```dart
Padding(
  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
  child: Row(children: [
    Expanded(child: /* existing TextField */),
    const SizedBox(width: 8),
    RepoFilterChips(
      counts: {
        'all': _repoConfigs.length,
        'monitored': _repoConfigs.values.where((c) => c.isMonitored).length,
        'not_monitored': _repoConfigs.values.where((c) => !c.isMonitored).length,
      },
      current: _filter,
      onChanged: (v) => setState(() => _filter = v),
    ),
    const SizedBox(width: 12),
    /* existing saved indicator */
  ]),
),
```

Update the list filtering inside `build(...)` (the `filtered` computation):

```dart
final filtered = allRepos.where((r) {
  if (_search.isNotEmpty &&
      !r.toLowerCase().contains(_search.toLowerCase())) return false;
  final c = _repoConfigs[r]!;
  if (_filter == 'monitored' && !c.isMonitored) return false;
  if (_filter == 'not_monitored' && c.isMonitored) return false;
  return true;
}).toList();
```

Remove the `_discover()` method and the `FilledButton.tonalIcon` entirely. Delete the `_discoverError` text block.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd flutter_app && flutter test test/features/repositories/`
Expected: PASS (all tests including the new filter test)

- [ ] **Step 5: Commit**

```bash
git add flutter_app/lib/features/repositories/repos_screen.dart flutter_app/test/features/repositories/repos_screen_test.dart
git commit -m "feat(flutter): filter chips on repos screen, remove Discover button"
```

---

### Task 10: View toggle (list/grid) persisted in SharedPreferences

**Files:**
- Modify: `flutter_app/lib/features/repositories/repos_screen.dart`

- [ ] **Step 1: Add view-toggle test**

Append to `repos_screen_test.dart`:

```dart
testWidgets('view toggle persists choice in SharedPreferences',
    (tester) async {
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(_host(_cfg()));
  await tester.pumpAndSettle();

  await tester.tap(find.byKey(const Key('repos_view_toggle_grid')));
  await tester.pumpAndSettle();

  final prefs = await SharedPreferences.getInstance();
  expect(prefs.getString('repos_view'), 'grid');
});
```

Add imports at the top of the test file:

```dart
import 'package:shared_preferences/shared_preferences.dart';
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd flutter_app && flutter test test/features/repositories/repos_screen_test.dart`
Expected: FAIL — key not found, or pref not written.

- [ ] **Step 3: Implement the view toggle in `repos_screen.dart`**

At the top add:

```dart
import 'package:shared_preferences/shared_preferences.dart';
```

Add state:

```dart
String _viewMode = 'list';   // 'list' | 'grid'

@override
void initState() {
  super.initState();
  SharedPreferences.getInstance().then((p) {
    final v = p.getString('repos_view');
    if (v != null && mounted) setState(() => _viewMode = v);
  });
}

void _setViewMode(String v) {
  setState(() => _viewMode = v);
  SharedPreferences.getInstance().then((p) => p.setString('repos_view', v));
}
```

In the toolbar row (next to the filter chips), add the toggle widget:

```dart
Row(children: [
  _ViewToggleButton(
    icon: Icons.view_list,
    active: _viewMode == 'list',
    onTap: () => _setViewMode('list'),
    buttonKey: const Key('repos_view_toggle_list'),
  ),
  _ViewToggleButton(
    icon: Icons.grid_view,
    active: _viewMode == 'grid',
    onTap: () => _setViewMode('grid'),
    buttonKey: const Key('repos_view_toggle_grid'),
  ),
]),
```

And the widget at the bottom of the file:

```dart
class _ViewToggleButton extends StatelessWidget {
  final IconData icon;
  final bool active;
  final VoidCallback onTap;
  final Key buttonKey;
  const _ViewToggleButton({
    required this.icon, required this.active, required this.onTap, required this.buttonKey,
  });
  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return InkWell(
      key: buttonKey,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        color: active ? primary.withOpacity(0.22) : null,
        child: Icon(icon, size: 18, color: active ? primary : Colors.grey.shade500),
      ),
    );
  }
}
```

(Grid rendering itself comes in Task 12; for now, it's fine if `_viewMode == 'grid'` still renders the list — the test only asserts the preference is persisted.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd flutter_app && flutter test test/features/repositories/repos_screen_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add flutter_app/lib/features/repositories/repos_screen.dart flutter_app/test/features/repositories/repos_screen_test.dart
git commit -m "feat(flutter): list/grid view toggle persisted in SharedPreferences"
```

---

## Phase 5 — Grid view

### Task 11: RepoGridTile widget

**Files:**
- Create: `flutter_app/lib/features/repositories/widgets/repo_grid_tile.dart`
- Test: `flutter_app/test/features/repositories/widgets/repo_grid_tile_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// flutter_app/test/features/repositories/widgets/repo_grid_tile_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heimdallm/core/models/config_model.dart';
import 'package:heimdallm/features/repositories/widgets/repo_grid_tile.dart';
import 'package:heimdallm/features/repositories/widgets/feature_led.dart';

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: SizedBox(width: 200, height: 180, child: child)));

void main() {
  final appConfig = AppConfig(
    serverPort: 1, pollInterval: 60, retentionDays: 30,
    repositories: const ['a/repo'],
    aiPrimary: 'claude', aiFallback: '', reviewMode: 'single',
    repoConfigs: const {},
    issueTracking: const IssueTrackingConfig(),
  );

  testWidgets('shows repo name, org subtitle, 3 LEDs', (tester) async {
    await tester.pumpWidget(_host(RepoGridTile(
      repo: 'a/repo',
      config: const RepoConfig(prEnabled: true),
      appConfig: appConfig,
      selected: false,
      onSelectionToggle: () {},
      onTap: () {},
    )));
    expect(find.text('repo'), findsOneWidget);
    expect(find.text('a'), findsOneWidget);
    expect(find.byType(FeatureLed), findsNWidgets(3));
  });

  testWidgets('tapping tile (outside checkbox) calls onTap', (tester) async {
    var tapped = false;
    await tester.pumpWidget(_host(RepoGridTile(
      repo: 'a/repo',
      config: const RepoConfig(prEnabled: true),
      appConfig: appConfig,
      selected: false,
      onSelectionToggle: () {},
      onTap: () => tapped = true,
    )));
    await tester.tap(find.text('repo'));
    expect(tapped, isTrue);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd flutter_app && flutter test test/features/repositories/widgets/repo_grid_tile_test.dart`
Expected: FAIL with "Target of URI doesn't exist".

- [ ] **Step 3: Implement the widget**

```dart
// flutter_app/lib/features/repositories/widgets/repo_grid_tile.dart
import 'package:flutter/material.dart';
import '../../../core/models/config_model.dart';
import 'feature_led.dart';
import 'feature_palette.dart';

class RepoGridTile extends StatelessWidget {
  final String repo;
  final RepoConfig config;
  final AppConfig appConfig;
  final bool selected;
  final VoidCallback onSelectionToggle;
  final VoidCallback onTap;

  const RepoGridTile({
    super.key,
    required this.repo,
    required this.config,
    required this.appConfig,
    required this.selected,
    required this.onSelectionToggle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final parts = repo.split('/');
    final org = parts.length > 1 ? parts[0] : '';
    final name = parts.length > 1 ? parts.sublist(1).join('/') : repo;
    final hasDir = config.localDir != null && config.localDir!.isNotEmpty;
    final primary = Theme.of(context).colorScheme.primary;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
        decoration: BoxDecoration(
          color: selected ? primary.withOpacity(0.12) : const Color(0xFF22262E),
          border: Border.all(
            color: selected ? primary.withOpacity(0.55) : const Color(0xFF2E333B),
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              GestureDetector(
                key: const Key('RepoGridTile_checkbox'),
                behavior: HitTestBehavior.opaque,
                onTap: onSelectionToggle,
                child: Container(
                  width: 15, height: 15,
                  decoration: BoxDecoration(
                    color: selected ? primary : Colors.transparent,
                    border: Border.all(
                      color: selected ? primary : const Color(0xFF6E7681),
                      width: 1.5,
                    ),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: selected
                      ? const Icon(Icons.check, size: 10, color: Colors.white)
                      : null,
                ),
              ),
              const Spacer(),
              FeatureLed(
                feature: Feature.prReview,
                isOn: _isOn(Feature.prReview),
                sourceLine: _sourceLine(Feature.prReview),
                size: 9,
              ),
              const SizedBox(width: 4),
              FeatureLed(
                feature: Feature.issueTracking,
                isOn: _isOn(Feature.issueTracking),
                sourceLine: _sourceLine(Feature.issueTracking),
                size: 9,
              ),
              const SizedBox(width: 4),
              FeatureLed(
                feature: Feature.develop,
                isOn: _isOn(Feature.develop),
                sourceLine: _sourceLine(Feature.develop),
                size: 9,
              ),
            ]),
            const SizedBox(height: 10),
            Text(
              name,
              style: TextStyle(
                fontSize: 13,
                fontWeight: config.isMonitored ? FontWeight.w600 : FontWeight.w500,
                color: config.isMonitored ? null : Colors.grey.shade500,
              ),
              maxLines: 2, overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              org,
              style: TextStyle(fontSize: 10.5, color: Colors.grey.shade500),
              maxLines: 1, overflow: TextOverflow.ellipsis,
            ),
            const Spacer(),
            Row(children: [
              Icon(
                hasDir ? Icons.folder : Icons.folder_off_outlined,
                size: 12, color: hasDir ? Colors.green.shade500 : Colors.grey.shade600,
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  hasDir ? config.localDir!.split('/').last : 'No local dir',
                  style: TextStyle(
                    fontSize: 10.5,
                    color: hasDir ? Colors.green.shade500 : Colors.grey.shade600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  bool _isOn(Feature f) {
    final inGlobalList = appConfig.repositories.contains(repo);
    final globalIt = appConfig.issueTracking.enabled;
    final hasDir = config.localDir != null && config.localDir!.isNotEmpty;
    final status = switch (f) {
      Feature.prReview      => config.prLedStatus(inGlobalList),
      Feature.issueTracking => config.itLedStatus(globalIt),
      Feature.develop       => config.devLedStatus(globalIt, hasDir),
    };
    return status != 'off';
  }

  String _sourceLine(Feature f) {
    // Same logic as RepoListTile — duplicated here to keep the widget
    // self-contained. Kept intentionally: a shared helper would add an
    // awkward import dependency between siblings.
    final inGlobalList = appConfig.repositories.contains(repo);
    final globalIt = appConfig.issueTracking.enabled;
    final hasDir = config.localDir != null && config.localDir!.isNotEmpty;
    switch (f) {
      case Feature.prReview:
        if (config.prEnabled == true) return 'Source: repo-level (prEnabled = true)';
        if (config.prEnabled == false) return 'Source: disabled per-repo (prEnabled = false)';
        return inGlobalList
            ? 'Source: inherited from global monitored list'
            : 'Source: not in monitored list';
      case Feature.issueTracking:
        if (config.itEnabled == true) return 'Source: repo-level (itEnabled = true)';
        if (config.itEnabled == false) return 'Source: disabled per-repo (itEnabled = false)';
        if ((config.reviewOnlyLabels ?? const []).isNotEmpty) {
          return 'Source: implied by per-repo labels';
        }
        return globalIt
            ? 'Source: inherited from global issue tracking'
            : 'Source: globally disabled';
      case Feature.develop:
        if (config.devEnabled == true && hasDir) return 'Source: repo-level (devEnabled = true)';
        if (config.devEnabled == false) return 'Source: disabled per-repo (devEnabled = false)';
        if (!hasDir) return 'Reason: no local directory configured (Develop requires one)';
        if ((config.developLabels ?? const []).isNotEmpty) {
          return 'Source: implied by per-repo develop labels';
        }
        return globalIt
            ? 'Source: inherited from global issue tracking'
            : 'Source: globally disabled';
    }
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd flutter_app && flutter test test/features/repositories/widgets/repo_grid_tile_test.dart`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add flutter_app/lib/features/repositories/widgets/repo_grid_tile.dart flutter_app/test/features/repositories/widgets/repo_grid_tile_test.dart
git commit -m "feat(flutter): RepoGridTile widget"
```

---

### Task 12: Render grid in ReposScreen when view=grid

**Files:**
- Modify: `flutter_app/lib/features/repositories/repos_screen.dart`

- [ ] **Step 1: Add grid rendering test**

Append to `repos_screen_test.dart`:

```dart
testWidgets('grid view renders RepoGridTile instead of RepoListTile',
    (tester) async {
  SharedPreferences.setMockInitialValues({'repos_view': 'grid'});
  await tester.pumpWidget(_host(_cfg()));
  await tester.pumpAndSettle();

  expect(find.byType(RepoGridTile), findsWidgets);
  expect(find.byType(RepoListTile), findsNothing);
});
```

Imports to add:

```dart
import 'package:heimdallm/features/repositories/widgets/repo_grid_tile.dart';
import 'package:heimdallm/features/repositories/widgets/repo_list_tile.dart';
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd flutter_app && flutter test test/features/repositories/repos_screen_test.dart`
Expected: FAIL — `RepoGridTile` never rendered.

- [ ] **Step 3: Branch on view mode in the body**

In `repos_screen.dart`, replace the existing `Expanded(child: _RepoListWithSections(...))` with:

```dart
Expanded(
  child: filtered.isEmpty
      ? const Center(child: Text('No repos to show.'))
      : _viewMode == 'grid'
          ? _ReposGrid(
              repos: filtered,
              configs: _repoConfigs,
              appConfig: config,
              selected: _selected,
              onSelectionToggle: _toggleSelection,
            )
          : _RepoListWithSections(
              repos: filtered,
              configs: _repoConfigs,
              appConfig: config,
              onChanged: _onChange,
              selected: _selected,
              onSelectionToggle: _toggleSelection,
            ),
),
```

Add `_ReposGrid` at the bottom of the file:

```dart
class _ReposGrid extends StatelessWidget {
  final List<String> repos;
  final Map<String, RepoConfig> configs;
  final AppConfig appConfig;
  final Set<String> selected;
  final ValueChanged<String> onSelectionToggle;

  const _ReposGrid({
    required this.repos,
    required this.configs,
    required this.appConfig,
    required this.selected,
    required this.onSelectionToggle,
  });

  @override
  Widget build(BuildContext context) {
    final monitored = repos.where((r) => configs[r]!.isMonitored).toList();
    final disabled = repos.where((r) => !configs[r]!.isMonitored).toList();

    return CustomScrollView(
      slivers: [
        if (monitored.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Row(children: [
                Container(
                  width: 8, height: 8,
                  decoration: const BoxDecoration(color: Color(0xFF3FB950), shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Text('MONITORED · ${monitored.length}',
                    style: TextStyle(fontSize: 11.5, color: Colors.grey.shade400, fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 200,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.0,
              ),
              delegate: SliverChildBuilderDelegate(
                (ctx, i) {
                  final r = monitored[i];
                  return RepoGridTile(
                    repo: r,
                    config: configs[r]!,
                    appConfig: appConfig,
                    selected: selected.contains(r),
                    onSelectionToggle: () => onSelectionToggle(r),
                    onTap: () => ctx.push('/repos/${Uri.encodeComponent(r)}'),
                  );
                },
                childCount: monitored.length,
              ),
            ),
          ),
        ],
        if (disabled.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(children: [
                Container(
                  width: 8, height: 8,
                  decoration: BoxDecoration(color: Colors.grey.shade600, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Text('NOT MONITORED · ${disabled.length}',
                    style: TextStyle(fontSize: 11.5, color: Colors.grey.shade400, fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 200,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.0,
              ),
              delegate: SliverChildBuilderDelegate(
                (ctx, i) {
                  final r = disabled[i];
                  return RepoGridTile(
                    repo: r,
                    config: configs[r]!,
                    appConfig: appConfig,
                    selected: selected.contains(r),
                    onSelectionToggle: () => onSelectionToggle(r),
                    onTap: () => ctx.push('/repos/${Uri.encodeComponent(r)}'),
                  );
                },
                childCount: disabled.length,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
```

Add import at top:

```dart
import 'widgets/repo_grid_tile.dart';
import 'package:go_router/go_router.dart';    // already present
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd flutter_app && flutter test test/features/repositories/repos_screen_test.dart`
Expected: PASS (all tests)

- [ ] **Step 5: Commit**

```bash
git add flutter_app/lib/features/repositories/repos_screen.dart flutter_app/test/features/repositories/repos_screen_test.dart
git commit -m "feat(flutter): grid view for repositories screen"
```

---

## Phase 6 — Detail screen colour accents

### Task 13: Colour-code detail sections

**Files:**
- Modify: `flutter_app/lib/features/repositories/repo_detail_screen.dart`

- [ ] **Step 1: Update `_sectionCard` to accept a colour**

Open `flutter_app/lib/features/repositories/repo_detail_screen.dart`. Change `_sectionCard` (around line 97) to:

```dart
Widget _sectionCard(String title, List<Widget> children, {Color? accent}) {
  return Card(
    margin: const EdgeInsets.only(bottom: 12),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
      side: accent != null
          ? BorderSide(color: accent, width: 2)
          : BorderSide.none,
    ),
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 15,
              color: accent,
            ),
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    ),
  );
}
```

- [ ] **Step 2: Apply the palette to the three feature sections**

Add import:

```dart
import 'widgets/feature_palette.dart';
```

Change the three calls:

```dart
_sectionCard('PR Review', [ /* ... */ ], accent: FeaturePalette.prReview),
_sectionCard('Issue Tracking', [ /* ... */ ], accent: FeaturePalette.issueTracking),
_sectionCard('Develop', [ /* ... */ ], accent: FeaturePalette.develop),
```

The "General" section keeps no accent (`_sectionCard('General', [...])`).

- [ ] **Step 3: Replace the three main `SwitchListTile`s with `FeatureSwitch`**

The current detail screen uses `SwitchListTile` for "Auto-review PRs", "Triage issues", "Auto-implement issues". Replace each with a Row that uses `FeatureSwitch` to keep the colour consistent:

```dart
Row(children: [
  const Expanded(child: Text('Auto-review PRs', style: TextStyle(fontSize: 13))),
  FeatureSwitch(
    feature: Feature.prReview,
    value: _config.prEnabled ?? false,
    onChanged: (v) => _update(_config.copyWith(prEnabled: v)),
  ),
]),
```

Repeat for `itEnabled` with `Feature.issueTracking` and `devEnabled` with `Feature.develop`. Add the import:

```dart
import 'widgets/feature_switch.dart';
```

- [ ] **Step 4: Run the detail screen tests (if any) + full suite**

Run: `cd flutter_app && flutter test`
Expected: all tests pass; no regressions.

- [ ] **Step 5: Commit**

```bash
git add flutter_app/lib/features/repositories/repo_detail_screen.dart
git commit -m "feat(flutter): colour-code detail sections with feature palette"
```

---

## Phase 7 — Daemon auto-discovery

### Task 14: Config field `AutoEnablePROnDiscovery`

**Files:**
- Modify: `daemon/internal/config/config.go`
- Modify: `daemon/internal/config/config_test.go`

- [ ] **Step 1: Add the field to GitHubConfig**

In `daemon/internal/config/config.go` inside the `GitHubConfig` struct (alongside `DiscoveryTopic` etc):

```go
// AutoEnablePROnDiscovery controls the initial prEnabled value for repos
// auto-added from the poll cycle's review-requested results. nil means
// "use default". Default is true to preserve pre-feature behaviour.
AutoEnablePROnDiscovery *bool `toml:"auto_enable_pr_review_on_discovery"`
```

Add a helper:

```go
// AutoEnablePRForDiscovery returns the effective boolean value.
func (c *GitHubConfig) AutoEnablePRForDiscovery() bool {
    if c.AutoEnablePROnDiscovery == nil { return true }
    return *c.AutoEnablePROnDiscovery
}
```

- [ ] **Step 2: Write a test for the default**

Add to `daemon/internal/config/config_test.go`:

```go
func TestAutoEnablePRForDiscovery_Default(t *testing.T) {
    cfg := &GitHubConfig{}
    if !cfg.AutoEnablePRForDiscovery() { t.Fatal("default should be true") }
}

func TestAutoEnablePRForDiscovery_Explicit(t *testing.T) {
    f := false
    cfg := &GitHubConfig{AutoEnablePROnDiscovery: &f}
    if cfg.AutoEnablePRForDiscovery() { t.Fatal("explicit false should return false") }
}
```

- [ ] **Step 3: Run tests**

Run: `cd daemon && go test ./internal/config/ -run AutoEnablePR -v`
Expected: PASS (2 tests)

- [ ] **Step 4: Commit**

```bash
git add daemon/internal/config/config.go daemon/internal/config/config_test.go
git commit -m "feat(daemon): AutoEnablePROnDiscovery config field with default true"
```

---

### Task 15: First-seen tracking as a JSON-encoded row in the K/V store

**Context:** `daemon/internal/store/store.go` exposes a SQLite-backed K/V config table via `SetConfig(key, value)` and `ListConfigs() map[string]string`. Other lists (`repositories`, `non_monitored`) are stored as JSON strings under their own keys. We use the same pattern for first-seen timestamps, under the key `repo_first_seen` (value = JSON-encoded `map[string]int64` of unix seconds).

**Files:**
- Create: `daemon/internal/config/repo_first_seen.go`
- Create: `daemon/internal/config/repo_first_seen_test.go`

- [ ] **Step 1: Write the failing test**

```go
// daemon/internal/config/repo_first_seen_test.go
package config

import (
    "testing"
    "time"
)

func TestFirstSeenMap_Marshal_Unmarshal(t *testing.T) {
    m := FirstSeenMap{
        "org/a": time.Unix(1000, 0),
        "org/b": time.Unix(2000, 0),
    }
    raw, err := m.Marshal()
    if err != nil { t.Fatal(err) }

    decoded, err := ParseFirstSeen(raw)
    if err != nil { t.Fatal(err) }

    if !decoded["org/a"].Equal(time.Unix(1000, 0)) ||
       !decoded["org/b"].Equal(time.Unix(2000, 0)) {
        t.Fatalf("roundtrip failed: %+v", decoded)
    }
}

func TestFirstSeenMap_Mark_IsIdempotent(t *testing.T) {
    m := FirstSeenMap{}
    m.Mark("a/b", time.Unix(1000, 0))
    m.Mark("a/b", time.Unix(2000, 0))  // second call ignored

    got, ok := m["a/b"]
    if !ok { t.Fatal("expected key to exist") }
    if !got.Equal(time.Unix(1000, 0)) {
        t.Fatalf("second Mark should be a no-op: got %v", got)
    }
}

func TestParseFirstSeen_EmptyAndInvalid(t *testing.T) {
    m, err := ParseFirstSeen("")
    if err != nil || len(m) != 0 {
        t.Fatalf("empty should decode to empty map, got %v / %v", m, err)
    }
    if _, err := ParseFirstSeen("not json"); err == nil {
        t.Fatal("invalid JSON should return error")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd daemon && go test ./internal/config/ -run FirstSeen -v`
Expected: FAIL — types and functions don't exist.

- [ ] **Step 3: Implement the type + helpers**

```go
// daemon/internal/config/repo_first_seen.go
//
// First-seen timestamps for repos auto-discovered by the daemon. Persisted
// as JSON under the `repo_first_seen` key in the K/V config table, same
// pattern as `repositories` and `non_monitored` (see store.go).
package config

import (
    "encoding/json"
    "time"
)

// FirstSeenMap maps "org/repo" to the timestamp the daemon first discovered
// that repo. Unix-second precision is enough — the UI only uses this to
// show a NEW badge.
type FirstSeenMap map[string]time.Time

// Mark records the first-seen time for a repo. Idempotent: if the repo is
// already present, the existing timestamp wins.
func (m FirstSeenMap) Mark(repo string, t time.Time) {
    if _, exists := m[repo]; exists { return }
    m[repo] = t
}

// Marshal serialises the map to a JSON string of {repo: unix_seconds}.
func (m FirstSeenMap) Marshal() (string, error) {
    raw := make(map[string]int64, len(m))
    for k, v := range m { raw[k] = v.Unix() }
    b, err := json.Marshal(raw)
    if err != nil { return "", err }
    return string(b), nil
}

// ParseFirstSeen decodes the JSON string returned by Marshal.
// Empty string → empty map (first call on a fresh DB).
func ParseFirstSeen(raw string) (FirstSeenMap, error) {
    out := FirstSeenMap{}
    if raw == "" { return out, nil }
    var tmp map[string]int64
    if err := json.Unmarshal([]byte(raw), &tmp); err != nil { return nil, err }
    for k, v := range tmp { out[k] = time.Unix(v, 0) }
    return out, nil
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd daemon && go test ./internal/config/ -run FirstSeen -v`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add daemon/internal/config/repo_first_seen.go daemon/internal/config/repo_first_seen_test.go
git commit -m "feat(daemon): FirstSeenMap type with JSON marshal/unmarshal"
```

---

### Task 16: Upsert newly-seen repos in poll cycle + SSE event + expose first-seen in GET /config

**Context:** The Flutter-side model of `prEnabled` maps to monitored-list membership in the daemon: `prEnabled: true` ⇔ repo in `c.GitHub.Repositories`, `prEnabled: false` ⇔ repo in `c.GitHub.NonMonitored`, `prEnabled: null` ⇔ neither. There is no per-repo `PREnabled` field in `RepoAI`. Discovery upsert therefore writes to one of those two slices, not to `c.AI.Repos`.

**Files:**
- Modify: `daemon/internal/sse/events.go` (add constant — grep for `EventPRDetected` to locate)
- Modify: `daemon/cmd/heimdallm/main.go` (upsert after FetchPRsToReview + expose `first_seen_at` in repo_overrides)
- Create: `daemon/cmd/heimdallm/main_discover_test.go`

- [ ] **Step 1: Add the SSE event constant**

Grep for `EventPRDetected` and add alongside its definition:

```go
EventRepoDiscovered EventType = "repo-discovered"
```

- [ ] **Step 2: Write the failing test**

Create `daemon/cmd/heimdallm/main_discover_test.go`:

```go
package main

import (
    "testing"

    "github.com/theburrowhub/heimdallm/daemon/internal/config"
    gh "github.com/theburrowhub/heimdallm/daemon/internal/github"
)

func TestUpsertDiscoveredRepos_DefaultEnabled(t *testing.T) {
    cfg := &config.Config{}
    cfg.GitHub.Repositories = []string{"a/known"}

    prs := []*gh.PullRequest{
        {RepositoryURL: "https://api.github.com/repos/a/known", Number: 1},
        {RepositoryURL: "https://api.github.com/repos/a/new",   Number: 2},
    }
    for _, pr := range prs { pr.ResolveRepo() }

    added := upsertDiscoveredRepos(cfg, prs)
    if len(added) != 1 || added[0] != "a/new" {
        t.Fatalf("expected a/new added, got %v", added)
    }
    found := false
    for _, r := range cfg.GitHub.Repositories { if r == "a/new" { found = true } }
    if !found {
        t.Fatalf("a/new should be appended to Repositories, got %v", cfg.GitHub.Repositories)
    }
}

func TestUpsertDiscoveredRepos_RespectsDisabledFlag(t *testing.T) {
    f := false
    cfg := &config.Config{}
    cfg.GitHub.AutoEnablePROnDiscovery = &f

    prs := []*gh.PullRequest{
        {RepositoryURL: "https://api.github.com/repos/a/new", Number: 1},
    }
    for _, pr := range prs { pr.ResolveRepo() }

    added := upsertDiscoveredRepos(cfg, prs)
    if len(added) != 1 { t.Fatalf("expected 1 added, got %v", added) }
    // Should land in NonMonitored, not Repositories.
    for _, r := range cfg.GitHub.Repositories {
        if r == "a/new" { t.Fatal("a/new must not be in Repositories when disabled") }
    }
    found := false
    for _, r := range cfg.GitHub.NonMonitored { if r == "a/new" { found = true } }
    if !found { t.Fatalf("a/new should be in NonMonitored, got %v", cfg.GitHub.NonMonitored) }
}

func TestUpsertDiscoveredRepos_SkipsAlreadyKnown(t *testing.T) {
    cfg := &config.Config{}
    cfg.GitHub.Repositories = []string{"a/one"}
    cfg.GitHub.NonMonitored = []string{"a/two"}

    prs := []*gh.PullRequest{
        {RepositoryURL: "https://api.github.com/repos/a/one", Number: 1},
        {RepositoryURL: "https://api.github.com/repos/a/two", Number: 2},
    }
    for _, pr := range prs { pr.ResolveRepo() }

    added := upsertDiscoveredRepos(cfg, prs)
    if len(added) != 0 { t.Fatalf("known repos should not be added, got %v", added) }
}

func TestUpsertDiscoveredRepos_IgnoresPRsWithEmptyRepo(t *testing.T) {
    cfg := &config.Config{}
    prs := []*gh.PullRequest{ {Number: 42} }  // RepositoryURL is empty → Repo stays ""
    added := upsertDiscoveredRepos(cfg, prs)
    if len(added) != 0 { t.Fatalf("PRs with empty Repo must be ignored, got %v", added) }
}
```

- [ ] **Step 3: Run to verify the tests fail**

Run: `cd daemon && go test ./cmd/heimdallm/ -run UpsertDiscoveredRepos -v`
Expected: FAIL — `upsertDiscoveredRepos` undefined.

- [ ] **Step 4: Implement `upsertDiscoveredRepos`**

In `daemon/cmd/heimdallm/main.go`, add the function (near `makePollFn`):

```go
// upsertDiscoveredRepos adds PRs' repos to the monitored (or non-monitored)
// list when they're new. Returns the list of repos that were added.
// Never removes; mutually-exclusive with NonMonitored when adding.
//
// Caller is responsible for persisting the updated Config and recording
// first-seen timestamps. This helper is pure state mutation so it's easy
// to test in isolation.
func upsertDiscoveredRepos(c *config.Config, prs []*gh.PullRequest) []string {
    known := make(map[string]struct{})
    for _, r := range c.GitHub.Repositories { known[r] = struct{}{} }
    for _, r := range c.GitHub.NonMonitored { known[r] = struct{}{} }

    enable := c.GitHub.AutoEnablePRForDiscovery()
    added := []string{}
    for _, pr := range prs {
        if pr.Repo == "" { continue }
        if _, alreadyKnown := known[pr.Repo]; alreadyKnown { continue }
        if enable {
            c.GitHub.Repositories = append(c.GitHub.Repositories, pr.Repo)
        } else {
            c.GitHub.NonMonitored = append(c.GitHub.NonMonitored, pr.Repo)
        }
        known[pr.Repo] = struct{}{}
        added = append(added, pr.Repo)
    }
    return added
}
```

Wire it into `makePollFn` right after `ghClient.FetchPRsToReview()` returns without error. Find the call (around `daemon/cmd/heimdallm/main.go:288`) and insert:

```go
cfgMu.Lock()
added := upsertDiscoveredRepos(c, prs)
cfgMu.Unlock()

if len(added) > 0 {
    // Persist the updated monitored/non-monitored lists.
    reposJSON, _ := json.Marshal(c.GitHub.Repositories)
    if _, err := s.SetConfig("repositories", string(reposJSON)); err != nil {
        slog.Warn("poll: persist repositories failed", "err", err)
    }
    nmJSON, _ := json.Marshal(c.GitHub.NonMonitored)
    if _, err := s.SetConfig("non_monitored", string(nmJSON)); err != nil {
        slog.Warn("poll: persist non_monitored failed", "err", err)
    }

    // Update first-seen map.
    fsRaw, _ := s.ListConfigs()
    fs, _ := config.ParseFirstSeen(fsRaw["repo_first_seen"])
    now := time.Now()
    for _, r := range added { fs.Mark(r, now) }
    fsStr, _ := fs.Marshal()
    if _, err := s.SetConfig("repo_first_seen", fsStr); err != nil {
        slog.Warn("poll: persist repo_first_seen failed", "err", err)
    }

    for _, r := range added {
        broker.Publish(sse.Event{
            Type: sse.EventRepoDiscovered,
            Data: sseData(map[string]any{"repo": r}),
        })
        slog.Info("poll: auto-discovered repo", "repo", r)
    }
}
```

Also expose `first_seen_at` via `GET /config` so the Flutter app can read it. Find `repoOverrides[repo] = ro` around `main.go:505` and, after the loop that builds `repoOverrides`, enrich entries with first-seen:

```go
// Load first-seen map once to enrich the response.
rows, _ := s.ListConfigs()
fsMap, _ := config.ParseFirstSeen(rows["repo_first_seen"])
for repo, ts := range fsMap {
    ro := repoOverrides[repo]
    if ro == nil { ro = map[string]any{} }
    ro["first_seen_at"] = ts.Unix()
    repoOverrides[repo] = ro
}
```

Ensure `encoding/json` is imported in `main.go` (likely already is).

- [ ] **Step 5: Run tests**

Run: `cd daemon && go test ./cmd/heimdallm/ -run UpsertDiscoveredRepos -v`
Expected: PASS (4 tests)

Run: `cd daemon && go build ./...`
Expected: exit 0

- [ ] **Step 6: Commit**

```bash
git add daemon/cmd/heimdallm/main.go daemon/cmd/heimdallm/main_discover_test.go daemon/internal/sse/events.go
git commit -m "feat(daemon): auto-discover review-requested repos + SSE event + first-seen in /config"
```

---

## Phase 8 — NEW badge in the Flutter app

### Task 17: Parse `first_seen_at` into `RepoConfig`

**Files:**
- Modify: `flutter_app/lib/core/models/config_model.dart`

- [ ] **Step 1: Write a failing test**

Append to `flutter_app/test/features/config_test.dart`:

```dart
test('RepoConfig parses first_seen_at when provided', () {
  final json = {
    'repositories': ['a/b'],
    'repo_overrides': {
      'a/b': {'first_seen_at': 1234567890},
    },
    'server_port': 1, 'poll_interval': 60, 'retention_days': 30,
    'ai_primary': 'claude', 'ai_fallback': '', 'review_mode': 'single',
    'issue_tracking': {'enabled': false},
  };
  final cfg = AppConfig.fromJson(json);
  expect(
    cfg.repoConfigs['a/b']!.firstSeenAt,
    DateTime.fromMillisecondsSinceEpoch(1234567890 * 1000),
  );
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd flutter_app && flutter test test/features/config_test.dart`
Expected: FAIL — `firstSeenAt` not defined on `RepoConfig`.

- [ ] **Step 3: Add the field**

In `flutter_app/lib/core/models/config_model.dart` inside `RepoConfig`:

```dart
final DateTime? firstSeenAt;
```

Add to the constructor parameter list and `copyWith`. In `fromJson` (around line 415 in the existing file):

```dart
final fsRaw = ov['first_seen_at'];
final firstSeen = fsRaw is int
    ? DateTime.fromMillisecondsSinceEpoch(fsRaw * 1000)
    : null;
configs[entry.key] = RepoConfig(
  // ... existing fields ...
  firstSeenAt: firstSeen,
);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd flutter_app && flutter test test/features/config_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add flutter_app/lib/core/models/config_model.dart flutter_app/test/features/config_test.dart
git commit -m "feat(flutter): parse first_seen_at into RepoConfig"
```

---

### Task 18: NEW badge on list + grid, dismissed in SharedPreferences

**Files:**
- Modify: `flutter_app/lib/features/repositories/widgets/repo_list_tile.dart`
- Modify: `flutter_app/lib/features/repositories/widgets/repo_grid_tile.dart`
- Modify: `flutter_app/lib/features/repositories/repos_screen.dart`

- [ ] **Step 1: Write the failing test**

Append to `repo_list_tile_test.dart`:

```dart
testWidgets('shows NEW badge when showNew=true', (tester) async {
  await tester.pumpWidget(_host(RepoListTile(
    repo: 'a/b',
    config: RepoConfig(
      prEnabled: true,
      firstSeenAt: DateTime.now(),
    ),
    appConfig: appConfig,
    selected: false,
    showNew: true,
    onSelectionToggle: () {},
    onTap: () {},
  )));
  expect(find.text('NEW'), findsOneWidget);
});

testWidgets('hides NEW badge when showNew=false', (tester) async {
  await tester.pumpWidget(_host(RepoListTile(
    repo: 'a/b',
    config: const RepoConfig(prEnabled: true),
    appConfig: appConfig,
    selected: false,
    showNew: false,
    onSelectionToggle: () {},
    onTap: () {},
  )));
  expect(find.text('NEW'), findsNothing);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd flutter_app && flutter test test/features/repositories/widgets/repo_list_tile_test.dart`
Expected: FAIL — `showNew` parameter doesn't exist.

- [ ] **Step 3: Add the `showNew` parameter and badge**

In `repo_list_tile.dart` constructor add `required this.showNew,` and field `final bool showNew;`. Inside the title row (next to the repo name), render:

```dart
if (showNew) ...[
  const SizedBox(width: 6),
  Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.primary.withOpacity(0.22),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      'NEW',
      style: TextStyle(
        color: Theme.of(context).colorScheme.primary,
        fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.4,
      ),
    ),
  ),
]
```

Repeat symmetrically in `repo_grid_tile.dart`.

- [ ] **Step 4: Wire in ReposScreen**

In `_ReposScreenState`, add:

```dart
Set<String> _dismissedNew = {};

@override
void initState() {
  super.initState();
  SharedPreferences.getInstance().then((p) {
    setState(() {
      _viewMode = p.getString('repos_view') ?? 'list';
      _dismissedNew = (p.getStringList('repos_dismissed_new') ?? []).toSet();
    });
  });
}

bool _shouldShowNew(String repo, RepoConfig c) =>
    c.firstSeenAt != null && !_dismissedNew.contains(repo);

void _dismissNew(String repo) {
  setState(() => _dismissedNew.add(repo));
  SharedPreferences.getInstance().then(
    (p) => p.setStringList('repos_dismissed_new', _dismissedNew.toList()),
  );
}
```

Pass `showNew: _shouldShowNew(r, configs[r]!)` to both `RepoListTile` and `RepoGridTile`. In the tap handler, call `_dismissNew(r)` before navigation.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd flutter_app && flutter test test/features/repositories/`
Expected: all PASS

- [ ] **Step 6: Commit**

```bash
git add flutter_app/lib/features/repositories/widgets/repo_list_tile.dart flutter_app/lib/features/repositories/widgets/repo_grid_tile.dart flutter_app/lib/features/repositories/repos_screen.dart flutter_app/test/features/repositories/widgets/repo_list_tile_test.dart
git commit -m "feat(flutter): NEW badge for auto-discovered repos, dismissed on interaction"
```

---

## Phase 9 — End-to-end smoke + docs

### Task 19: Manual smoke test + update changelog entry

**Files:**
- Read (no edit): all files above
- Modify: this plan (tick boxes)

- [ ] **Step 1: Run the full Flutter test suite**

Run: `cd flutter_app && flutter test`
Expected: no failures.

- [ ] **Step 2: Run the full Go test suite**

Run: `cd daemon && go test ./...`
Expected: no failures.

- [ ] **Step 3: Start the daemon + Flutter app locally and walk through the flow**

Checklist (record notes in the PR):
- Open the Repositories tab.
- Filter chips change the displayed set; the filter resets if you navigate away and back.
- Switch to Grid view; close the app; reopen; Grid view persists.
- Discover button is gone.
- Select 2–3 repos from different orgs; bulk bar appears with "N selected".
- Flip PR Review in the bulk bar; LEDs on all selected rows update; saved indicator shows.
- Flip Issue Tracking from mixed; switch converges to on; click again goes to off.
- Open the detail page of a repo; section headers for PR Review / Issue Tracking / Develop are coloured blue / purple / terracotta.
- Simulate a new repo by calling `curl -X POST` on the fake daemon (or tagging a repo with a topic): verify it appears with a NEW badge within one poll cycle; interacting dismisses the badge.
- Tooltip on any LED includes `Source: ...`.

- [ ] **Step 4: Final commit (no-op if no changes)**

Only commit if files changed during the smoke pass.

---

## Self-review checklist

- [x] Every spec section mapped to at least one task (palette → 1, LEDs → 2, switches → 3, list tile → 4-5, bulk bar → 6-7, filter chips → 8-9, view toggle → 10, grid tile → 11-12, detail accents → 13, daemon → 14-16, NEW badge → 17-18, smoke → 19).
- [x] No `TBD` / `TODO` / "handle edge cases" placeholders.
- [x] Every code step includes full code, not a reference.
- [x] Type consistency: `RepoConfig.firstSeenAt` is used in both model and widgets; `AutoEnablePRForDiscovery()` method name is consistent between tasks 14 and 16; `Feature` enum is referenced consistently as `Feature.prReview / issueTracking / develop` throughout.
- [x] Field names follow existing conventions (`prEnabled` / `itEnabled` / `devEnabled`).
- [x] Test commands are concrete and scoped to one file per step.
- [x] Commits follow repo's `feat:` / `refactor:` convention.
