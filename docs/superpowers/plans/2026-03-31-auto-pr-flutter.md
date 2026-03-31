# auto-pr Flutter App — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Flutter macOS desktop app that displays PR reviews from the auto-pr daemon, triggers re-reviews, and manages configuration — communicating via REST + SSE on localhost:7842.

**Architecture:** Riverpod for state management. `ApiClient` wraps HTTP calls. `SseClient` wraps the SSE stream. `DaemonLifecycle` starts/stops the daemon process. Screens: Dashboard, PR Detail, Config. Models generated with `json_serializable`.

**Tech Stack:** Flutter 3.x, Dart 3.x, `flutter_riverpod ^2.5.0`, `http ^1.2.0`, `json_serializable ^6.7.0`, `build_runner ^2.4.0`, `go_router ^14.0.0`, `shared_preferences ^2.2.0`.

**Prerequisite:** Daemon plan (`2026-03-31-auto-pr-daemon.md`) must be complete. The daemon binary must be at `daemon/bin/auto-pr-daemon`.

---

## File Map

```
flutter_app/
├── lib/
│   ├── main.dart                             # app entry point, ProviderScope
│   ├── core/
│   │   ├── api/
│   │   │   ├── api_client.dart              # HTTP client wrapping all REST calls
│   │   │   └── sse_client.dart              # SSE stream client
│   │   ├── models/
│   │   │   ├── pr.dart                      # PR model + json_serializable
│   │   │   ├── pr.g.dart                    # generated
│   │   │   ├── review.dart                  # Review model + json_serializable
│   │   │   ├── review.g.dart                # generated
│   │   │   ├── issue.dart                   # Issue model
│   │   │   ├── issue.g.dart                 # generated
│   │   │   └── config_model.dart            # AppConfig model
│   │   └── daemon/
│   │       └── daemon_lifecycle.dart        # start/stop/health-check daemon process
│   ├── features/
│   │   ├── dashboard/
│   │   │   ├── dashboard_screen.dart        # PR list with severity badges
│   │   │   └── dashboard_providers.dart     # Riverpod providers for PR list
│   │   ├── pr_detail/
│   │   │   ├── pr_detail_screen.dart        # PR detail + reviews
│   │   │   └── pr_detail_providers.dart     # providers for single PR
│   │   └── config/
│   │       ├── config_screen.dart           # settings form
│   │       └── config_providers.dart        # providers for config
│   ├── shared/
│   │   ├── widgets/
│   │   │   ├── severity_badge.dart          # colored badge: low/medium/high
│   │   │   └── toast.dart                   # in-app toast notifications
│   │   └── router.dart                      # go_router config
├── test/
│   ├── core/
│   │   ├── api_client_test.dart
│   │   └── sse_client_test.dart
│   ├── features/
│   │   ├── dashboard_test.dart
│   │   ├── pr_detail_test.dart
│   │   └── config_test.dart
│   └── shared/
│       └── severity_badge_test.dart
├── macos/
│   └── Runner/
│       └── DebugProfile.entitlements        # network client entitlement
├── pubspec.yaml
└── Makefile
```

---

### Task 1: Project setup

**Files:**
- Create: `flutter_app/pubspec.yaml` (via `flutter create`)
- Create: `flutter_app/Makefile`

- [ ] **Step 1: Create Flutter project**

```bash
cd /Users/jamuriano/personal-workspace/auto-pr
flutter create flutter_app --platforms=macos --org=com.autopr
```

- [ ] **Step 2: Update pubspec.yaml**

Replace the `dependencies` and `dev_dependencies` sections in `flutter_app/pubspec.yaml`:
```yaml
name: auto_pr
description: GitHub PR Auto-Review Desktop App
version: 1.0.0+1

environment:
  sdk: '>=3.0.0 <4.0.0'

dependencies:
  flutter:
    sdk: flutter
  flutter_riverpod: ^2.5.0
  http: ^1.2.0
  go_router: ^14.0.0
  shared_preferences: ^2.2.0
  json_annotation: ^4.8.0

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^3.0.0
  json_serializable: ^6.7.0
  build_runner: ^2.4.0
  mocktail: ^1.0.0

flutter:
  uses-material-design: true
```

- [ ] **Step 3: Install dependencies**

```bash
cd flutter_app && flutter pub get
```
Expected: no errors.

- [ ] **Step 4: Add network entitlement for macOS**

Edit `flutter_app/macos/Runner/DebugProfile.entitlements` — add inside the `<dict>`:
```xml
<key>com.apple.security.network.client</key>
<true/>
```

Do the same for `flutter_app/macos/Runner/Release.entitlements`.

- [ ] **Step 5: Create Makefile**

Create `flutter_app/Makefile`:
```makefile
.PHONY: build test gen run clean

gen:
	dart run build_runner build --delete-conflicting-outputs

build:
	flutter build macos --release

test:
	flutter test

run:
	flutter run -d macos

clean:
	flutter clean
```

- [ ] **Step 6: Verify Flutter project runs**

```bash
cd flutter_app && flutter build macos --debug 2>&1 | tail -5
```
Expected: build succeeds (default Flutter counter app).

- [ ] **Step 7: Commit**

```bash
cd /Users/jamuriano/personal-workspace/auto-pr
git add flutter_app/
git commit -m "chore: scaffold Flutter macOS app"
```

---

### Task 2: Models

**Files:**
- Create: `flutter_app/lib/core/models/pr.dart`
- Create: `flutter_app/lib/core/models/review.dart`
- Create: `flutter_app/lib/core/models/issue.dart`
- Create: `flutter_app/lib/core/models/config_model.dart`

- [ ] **Step 1: Create issue.dart**

Create `flutter_app/lib/core/models/issue.dart`:
```dart
import 'package:json_annotation/json_annotation.dart';
part 'issue.g.dart';

@JsonSerializable()
class Issue {
  final String file;
  final int line;
  final String description;
  final String severity;

  const Issue({
    required this.file,
    required this.line,
    required this.description,
    required this.severity,
  });

  factory Issue.fromJson(Map<String, dynamic> json) => _$IssueFromJson(json);
  Map<String, dynamic> toJson() => _$IssueToJson(this);
}
```

- [ ] **Step 2: Create review.dart**

Create `flutter_app/lib/core/models/review.dart`:
```dart
import 'package:json_annotation/json_annotation.dart';
import 'issue.dart';
part 'review.g.dart';

@JsonSerializable()
class Review {
  final int id;
  @JsonKey(name: 'pr_id')
  final int prId;
  @JsonKey(name: 'cli_used')
  final String cliUsed;
  final String summary;
  final List<Issue> issues;
  final List<String> suggestions;
  final String severity;
  @JsonKey(name: 'created_at')
  final DateTime createdAt;

  const Review({
    required this.id,
    required this.prId,
    required this.cliUsed,
    required this.summary,
    required this.issues,
    required this.suggestions,
    required this.severity,
    required this.createdAt,
  });

  factory Review.fromJson(Map<String, dynamic> json) => _$ReviewFromJson(json);
  Map<String, dynamic> toJson() => _$ReviewToJson(this);
}
```

Note: The daemon stores `issues` and `suggestions` as JSON strings. The API layer (`api_client.dart`) will decode them before constructing `Review`.

- [ ] **Step 3: Create pr.dart**

Create `flutter_app/lib/core/models/pr.dart`:
```dart
import 'package:json_annotation/json_annotation.dart';
import 'review.dart';
part 'pr.g.dart';

@JsonSerializable()
class PR {
  final int id;
  @JsonKey(name: 'github_id')
  final int githubId;
  final String repo;
  final int number;
  final String title;
  final String author;
  final String url;
  final String state;
  @JsonKey(name: 'updated_at')
  final DateTime updatedAt;
  @JsonKey(name: 'latest_review', includeIfNull: false)
  final Review? latestReview;

  const PR({
    required this.id,
    required this.githubId,
    required this.repo,
    required this.number,
    required this.title,
    required this.author,
    required this.url,
    required this.state,
    required this.updatedAt,
    this.latestReview,
  });

  factory PR.fromJson(Map<String, dynamic> json) => _$PRFromJson(json);
  Map<String, dynamic> toJson() => _$PRToJson(this);
}
```

- [ ] **Step 4: Create config_model.dart**

Create `flutter_app/lib/core/models/config_model.dart`:
```dart
class AppConfig {
  final int serverPort;
  final String pollInterval;
  final List<String> repositories;
  final String aiPrimary;
  final String aiFallback;
  final int retentionDays;

  const AppConfig({
    this.serverPort = 7842,
    this.pollInterval = '5m',
    this.repositories = const [],
    this.aiPrimary = 'claude',
    this.aiFallback = '',
    this.retentionDays = 90,
  });

  AppConfig copyWith({
    int? serverPort,
    String? pollInterval,
    List<String>? repositories,
    String? aiPrimary,
    String? aiFallback,
    int? retentionDays,
  }) {
    return AppConfig(
      serverPort: serverPort ?? this.serverPort,
      pollInterval: pollInterval ?? this.pollInterval,
      repositories: repositories ?? this.repositories,
      aiPrimary: aiPrimary ?? this.aiPrimary,
      aiFallback: aiFallback ?? this.aiFallback,
      retentionDays: retentionDays ?? this.retentionDays,
    );
  }

  Map<String, dynamic> toJson() => {
    'server_port': serverPort,
    'poll_interval': pollInterval,
    'repositories': repositories,
    'ai_primary': aiPrimary,
    'ai_fallback': aiFallback,
    'retention_days': retentionDays,
  };

  factory AppConfig.fromJson(Map<String, dynamic> json) => AppConfig(
    serverPort: (json['server_port'] as int?) ?? 7842,
    pollInterval: (json['poll_interval'] as String?) ?? '5m',
    repositories: (json['repositories'] as List<dynamic>?)?.cast<String>() ?? [],
    aiPrimary: (json['ai_primary'] as String?) ?? 'claude',
    aiFallback: (json['ai_fallback'] as String?) ?? '',
    retentionDays: (json['retention_days'] as int?) ?? 90,
  );
}
```

- [ ] **Step 5: Run code generation**

```bash
cd flutter_app && dart run build_runner build --delete-conflicting-outputs
```
Expected: generates `pr.g.dart`, `review.g.dart`, `issue.g.dart`.

- [ ] **Step 6: Verify compilation**

```bash
cd flutter_app && flutter analyze lib/core/models/
```
Expected: no errors.

- [ ] **Step 7: Commit**

```bash
cd /Users/jamuriano/personal-workspace/auto-pr
git add flutter_app/lib/core/models/ flutter_app/lib/core/models/*.g.dart
git commit -m "feat(models): PR, Review, Issue, AppConfig with json_serializable"
```

---

### Task 3: API client

**Files:**
- Create: `flutter_app/lib/core/api/api_client.dart`
- Create: `flutter_app/test/core/api_client_test.dart`

- [ ] **Step 1: Write failing test**

Create `flutter_app/test/core/api_client_test.dart`:
```dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:auto_pr/core/api/api_client.dart';
import 'package:auto_pr/core/models/pr.dart';

void main() {
  group('ApiClient', () {
    test('fetchPRs returns list of PRs', () async {
      final mockClient = MockClient((request) async {
        if (request.url.path == '/prs') {
          return http.Response(jsonEncode([
            {
              'id': 1, 'github_id': 101, 'repo': 'org/repo', 'number': 42,
              'title': 'Fix bug', 'author': 'alice', 'url': 'https://github.com/org/repo/pull/42',
              'state': 'open', 'updated_at': '2026-03-31T10:00:00Z',
              'latest_review': null,
            }
          ]), 200);
        }
        return http.Response('not found', 404);
      });

      final client = ApiClient(httpClient: mockClient, port: 7842);
      final prs = await client.fetchPRs();
      expect(prs.length, 1);
      expect(prs.first.title, 'Fix bug');
    });

    test('triggerReview returns 202', () async {
      final mockClient = MockClient((request) async {
        if (request.url.path == '/prs/1/review' && request.method == 'POST') {
          return http.Response(jsonEncode({'status': 'review queued'}), 202);
        }
        return http.Response('not found', 404);
      });

      final client = ApiClient(httpClient: mockClient, port: 7842);
      await expectLater(client.triggerReview(1), completes);
    });

    test('checkHealth returns true when daemon up', () async {
      final mockClient = MockClient((_) async =>
          http.Response(jsonEncode({'status': 'ok'}), 200));
      final client = ApiClient(httpClient: mockClient, port: 7842);
      final healthy = await client.checkHealth();
      expect(healthy, isTrue);
    });

    test('checkHealth returns false when daemon down', () async {
      final mockClient = MockClient((_) async => throw Exception('Connection refused'));
      final client = ApiClient(httpClient: mockClient, port: 7842);
      final healthy = await client.checkHealth();
      expect(healthy, isFalse);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd flutter_app && flutter test test/core/api_client_test.dart 2>&1 | head -10
```
Expected: compilation error — `api_client.dart` not found.

- [ ] **Step 3: Implement api_client.dart**

Create `flutter_app/lib/core/api/api_client.dart`:
```dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/pr.dart';
import '../models/review.dart';

class ApiClient {
  final http.Client _client;
  final int port;

  ApiClient({http.Client? httpClient, this.port = 7842})
      : _client = httpClient ?? http.Client();

  Uri _uri(String path) => Uri.parse('http://127.0.0.1:$port$path');

  Future<bool> checkHealth() async {
    try {
      final resp = await _client
          .get(_uri('/health'))
          .timeout(const Duration(seconds: 3));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<List<PR>> fetchPRs() async {
    final resp = await _client.get(_uri('/prs'));
    if (resp.statusCode != 200) {
      throw ApiException('GET /prs failed: ${resp.statusCode}');
    }
    final list = jsonDecode(resp.body) as List<dynamic>;
    return list.map((e) => _parsePRWithReview(e as Map<String, dynamic>)).toList();
  }

  Future<Map<String, dynamic>> fetchPR(int id) async {
    final resp = await _client.get(_uri('/prs/$id'));
    if (resp.statusCode != 200) {
      throw ApiException('GET /prs/$id failed: ${resp.statusCode}');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final pr = _parsePRWithReview(body['pr'] as Map<String, dynamic>);
    final reviewsRaw = body['reviews'] as List<dynamic>? ?? [];
    final reviews = reviewsRaw
        .map((r) => _parseReview(r as Map<String, dynamic>))
        .toList();
    return {'pr': pr, 'reviews': reviews};
  }

  Future<void> triggerReview(int prId) async {
    final resp = await _client.post(_uri('/prs/$prId/review'));
    if (resp.statusCode != 202) {
      throw ApiException('POST /prs/$prId/review failed: ${resp.statusCode}');
    }
  }

  Future<Map<String, dynamic>> fetchConfig() async {
    final resp = await _client.get(_uri('/config'));
    if (resp.statusCode != 200) {
      throw ApiException('GET /config failed: ${resp.statusCode}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<void> updateConfig(Map<String, dynamic> config) async {
    final resp = await _client.put(
      _uri('/config'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(config),
    );
    if (resp.statusCode != 200) {
      throw ApiException('PUT /config failed: ${resp.statusCode}');
    }
  }

  /// Parses a PR JSON object, handling issues/suggestions as either
  /// JSON strings (from daemon) or already-decoded lists.
  PR _parsePRWithReview(Map<String, dynamic> json) {
    if (json['latest_review'] != null) {
      json = Map.from(json);
      json['latest_review'] = _parseReviewMap(
          json['latest_review'] as Map<String, dynamic>);
    }
    return PR.fromJson(json);
  }

  Review _parseReview(Map<String, dynamic> json) {
    return Review.fromJson(_parseReviewMap(json));
  }

  Map<String, dynamic> _parseReviewMap(Map<String, dynamic> json) {
    final result = Map<String, dynamic>.from(json);
    // issues and suggestions may be JSON strings from the daemon
    if (result['issues'] is String) {
      result['issues'] = jsonDecode(result['issues'] as String);
    }
    if (result['suggestions'] is String) {
      result['suggestions'] = jsonDecode(result['suggestions'] as String);
    }
    result['issues'] ??= <dynamic>[];
    result['suggestions'] ??= <dynamic>[];
    return result;
  }
}

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => 'ApiException: $message';
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd flutter_app && flutter test test/core/api_client_test.dart -v
```
Expected: all 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/jamuriano/personal-workspace/auto-pr
git add flutter_app/lib/core/api/api_client.dart flutter_app/test/core/api_client_test.dart
git commit -m "feat(api): HTTP client for daemon REST API"
```

---

### Task 4: SSE client + daemon lifecycle

**Files:**
- Create: `flutter_app/lib/core/api/sse_client.dart`
- Create: `flutter_app/lib/core/daemon/daemon_lifecycle.dart`
- Create: `flutter_app/test/core/sse_client_test.dart`

- [ ] **Step 1: Write SSE client test**

Create `flutter_app/test/core/sse_client_test.dart`:
```dart
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:auto_pr/core/api/sse_client.dart';

void main() {
  test('SseEvent parses type and data', () {
    const raw = 'event: review_completed\ndata: {"pr_id":1}\n\n';
    final events = SseClient.parseEvents(raw);
    expect(events.length, 1);
    expect(events.first.type, 'review_completed');
    expect(events.first.data, '{"pr_id":1}');
  });

  test('SseEvent parses data-only event', () {
    const raw = 'data: hello\n\n';
    final events = SseClient.parseEvents(raw);
    expect(events.length, 1);
    expect(events.first.type, 'message');
    expect(events.first.data, 'hello');
  });

  test('SseEvent skips comment lines', () {
    const raw = ': connected\n\ndata: ping\n\n';
    final events = SseClient.parseEvents(raw);
    expect(events.length, 1);
    expect(events.first.data, 'ping');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd flutter_app && flutter test test/core/sse_client_test.dart 2>&1 | head -5
```
Expected: compilation error.

- [ ] **Step 3: Implement sse_client.dart**

Create `flutter_app/lib/core/api/sse_client.dart`:
```dart
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

class SseEvent {
  final String type;
  final String data;
  const SseEvent({required this.type, required this.data});
}

class SseClient {
  final int port;
  final http.Client _httpClient;
  StreamController<SseEvent>? _controller;
  http.StreamedResponse? _response;

  SseClient({this.port = 7842, http.Client? httpClient})
      : _httpClient = httpClient ?? http.Client();

  /// Parses SSE wire format into events. Static for testability.
  static List<SseEvent> parseEvents(String raw) {
    final events = <SseEvent>[];
    for (final block in raw.split('\n\n')) {
      if (block.trim().isEmpty) continue;
      String type = 'message';
      final dataParts = <String>[];
      for (final line in block.split('\n')) {
        if (line.startsWith('event:')) {
          type = line.substring(6).trim();
        } else if (line.startsWith('data:')) {
          dataParts.add(line.substring(5).trim());
        }
        // Skip comment lines (start with ':')
      }
      if (dataParts.isNotEmpty) {
        events.add(SseEvent(type: type, data: dataParts.join('\n')));
      }
    }
    return events;
  }

  /// Returns a stream of SSE events from the daemon.
  Stream<SseEvent> connect() {
    _controller = StreamController<SseEvent>.broadcast(
      onCancel: () => disconnect(),
    );
    _startListening();
    return _controller!.stream;
  }

  void _startListening() async {
    try {
      final request = http.Request('GET', Uri.parse('http://127.0.0.1:$port/events'));
      request.headers['Accept'] = 'text/event-stream';
      request.headers['Cache-Control'] = 'no-cache';
      _response = await _httpClient.send(request);

      String buffer = '';
      _response!.stream.transform(utf8.decoder).listen(
        (chunk) {
          buffer += chunk;
          // Process complete events (double newline terminated)
          while (buffer.contains('\n\n')) {
            final idx = buffer.indexOf('\n\n');
            final block = buffer.substring(0, idx + 2);
            buffer = buffer.substring(idx + 2);
            for (final event in parseEvents(block)) {
              _controller?.add(event);
            }
          }
        },
        onError: (e) => _controller?.addError(e),
        onDone: () => _controller?.close(),
      );
    } catch (e) {
      _controller?.addError(e);
    }
  }

  void disconnect() {
    _response?.stream.timeout(Duration.zero);
    _controller?.close();
    _controller = null;
  }
}
```

- [ ] **Step 4: Run SSE client tests**

```bash
cd flutter_app && flutter test test/core/sse_client_test.dart -v
```
Expected: all 3 tests PASS.

- [ ] **Step 5: Implement daemon_lifecycle.dart**

Create `flutter_app/lib/core/daemon/daemon_lifecycle.dart`:
```dart
import 'dart:io';
import '../api/api_client.dart';

class DaemonLifecycle {
  final int port;
  final String daemonBinaryPath;
  final ApiClient _client;
  Process? _process;

  DaemonLifecycle({
    this.port = 7842,
    required this.daemonBinaryPath,
    ApiClient? client,
  }) : _client = client ?? ApiClient(port: port);

  /// Returns true if daemon is healthy.
  Future<bool> isRunning() => _client.checkHealth();

  /// Starts the daemon if not already running.
  Future<void> ensureRunning() async {
    if (await isRunning()) return;

    final binary = File(daemonBinaryPath);
    if (!binary.existsSync()) {
      throw DaemonException('Daemon binary not found: $daemonBinaryPath');
    }

    _process = await Process.start(daemonBinaryPath, []);

    // Wait up to 5 seconds for daemon to be healthy
    for (var i = 0; i < 50; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
      if (await isRunning()) return;
    }
    throw DaemonException('Daemon did not become healthy within 5 seconds');
  }

  /// Sends SIGTERM to the managed process (if we started it).
  Future<void> stop() async {
    _process?.kill();
    _process = null;
  }

  /// Returns the path where the daemon binary is expected inside the .app bundle.
  static String defaultBinaryPath() {
    final exe = Platform.resolvedExecutable;
    // In .app: auto-pr.app/Contents/MacOS/auto-pr
    // Daemon lives alongside: auto-pr.app/Contents/MacOS/auto-pr-daemon
    final dir = File(exe).parent.path;
    return '$dir/auto-pr-daemon';
  }
}

class DaemonException implements Exception {
  final String message;
  DaemonException(this.message);
  @override
  String toString() => 'DaemonException: $message';
}
```

- [ ] **Step 6: Commit**

```bash
cd /Users/jamuriano/personal-workspace/auto-pr
git add flutter_app/lib/core/ flutter_app/test/core/sse_client_test.dart
git commit -m "feat(sse+daemon): SSE stream client and daemon lifecycle manager"
```

---

### Task 5: Riverpod providers

**Files:**
- Create: `flutter_app/lib/features/dashboard/dashboard_providers.dart`
- Create: `flutter_app/lib/features/pr_detail/pr_detail_providers.dart`
- Create: `flutter_app/lib/features/config/config_providers.dart`

- [ ] **Step 1: Create dashboard_providers.dart**

Create `flutter_app/lib/features/dashboard/dashboard_providers.dart`:
```dart
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

/// Fetches the PR list and refreshes on SSE review_completed events.
final prsProvider = FutureProvider<List<PR>>((ref) async {
  // Re-fetch whenever an SSE event arrives
  ref.watch(sseStreamProvider);
  final api = ref.watch(apiClientProvider);
  return api.fetchPRs();
});
```

- [ ] **Step 2: Create pr_detail_providers.dart**

Create `flutter_app/lib/features/pr_detail/pr_detail_providers.dart`:
```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/models/pr.dart';
import '../../core/models/review.dart';
import '../dashboard/dashboard_providers.dart';

final prDetailProvider = FutureProvider.family<Map<String, dynamic>, int>((ref, prId) async {
  // Re-fetch on SSE events
  ref.watch(sseStreamProvider);
  final api = ref.watch(apiClientProvider);
  return api.fetchPR(prId);
});

final triggerReviewProvider = FutureProvider.family<void, int>((ref, prId) async {
  final api = ref.watch(apiClientProvider);
  await api.triggerReview(prId);
  // Invalidate so it refreshes
  ref.invalidate(prDetailProvider(prId));
  ref.invalidate(prsProvider);
});
```

- [ ] **Step 3: Create config_providers.dart**

Create `flutter_app/lib/features/config/config_providers.dart`:
```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/models/config_model.dart';
import '../dashboard/dashboard_providers.dart';

final configProvider = FutureProvider<AppConfig>((ref) async {
  final api = ref.watch(apiClientProvider);
  final json = await api.fetchConfig();
  return AppConfig.fromJson(json);
});

class ConfigNotifier extends AsyncNotifier<AppConfig> {
  @override
  Future<AppConfig> build() async {
    final api = ref.watch(apiClientProvider);
    final json = await api.fetchConfig();
    return AppConfig.fromJson(json);
  }

  Future<void> save(AppConfig config) async {
    final api = ref.read(apiClientProvider);
    await api.updateConfig(config.toJson());
    state = AsyncValue.data(config);
  }
}

final configNotifierProvider = AsyncNotifierProvider<ConfigNotifier, AppConfig>(
  ConfigNotifier.new,
);
```

- [ ] **Step 4: Commit**

```bash
cd /Users/jamuriano/personal-workspace/auto-pr
git add flutter_app/lib/features/
git commit -m "feat(providers): Riverpod providers for PRs, detail, and config"
```

---

### Task 6: Shared widgets + router

**Files:**
- Create: `flutter_app/lib/shared/widgets/severity_badge.dart`
- Create: `flutter_app/lib/shared/widgets/toast.dart`
- Create: `flutter_app/lib/shared/router.dart`
- Create: `flutter_app/test/shared/severity_badge_test.dart`

- [ ] **Step 1: Write severity badge test**

Create `flutter_app/test/shared/severity_badge_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:auto_pr/shared/widgets/severity_badge.dart';

void main() {
  testWidgets('SeverityBadge shows correct color for high', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SeverityBadge(severity: 'high'))),
    );
    final container = tester.widget<Container>(find.byType(Container).first);
    final decoration = container.decoration as BoxDecoration;
    expect(decoration.color, Colors.red.shade700);
  });

  testWidgets('SeverityBadge shows correct color for medium', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SeverityBadge(severity: 'medium'))),
    );
    final container = tester.widget<Container>(find.byType(Container).first);
    final decoration = container.decoration as BoxDecoration;
    expect(decoration.color, Colors.orange.shade700);
  });

  testWidgets('SeverityBadge shows correct color for low', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SeverityBadge(severity: 'low'))),
    );
    final container = tester.widget<Container>(find.byType(Container).first);
    final decoration = container.decoration as BoxDecoration;
    expect(decoration.color, Colors.green.shade700);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd flutter_app && flutter test test/shared/severity_badge_test.dart 2>&1 | head -5
```
Expected: compilation error.

- [ ] **Step 3: Implement severity_badge.dart**

Create `flutter_app/lib/shared/widgets/severity_badge.dart`:
```dart
import 'package:flutter/material.dart';

class SeverityBadge extends StatelessWidget {
  final String severity;

  const SeverityBadge({super.key, required this.severity});

  Color get _color {
    switch (severity.toLowerCase()) {
      case 'high':
        return Colors.red.shade700;
      case 'medium':
        return Colors.orange.shade700;
      default:
        return Colors.green.shade700;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: _color,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        severity.toUpperCase(),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run severity badge tests**

```bash
cd flutter_app && flutter test test/shared/severity_badge_test.dart -v
```
Expected: all 3 tests PASS.

- [ ] **Step 5: Implement toast.dart**

Create `flutter_app/lib/shared/widgets/toast.dart`:
```dart
import 'package:flutter/material.dart';

void showToast(BuildContext context, String message, {bool isError = false}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: isError ? Colors.red.shade700 : Colors.green.shade700,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 3),
      margin: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
  );
}
```

- [ ] **Step 6: Implement router.dart**

Create `flutter_app/lib/shared/router.dart`:
```dart
import 'package:go_router/go_router.dart';
import '../features/dashboard/dashboard_screen.dart';
import '../features/pr_detail/pr_detail_screen.dart';
import '../features/config/config_screen.dart';

final appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const DashboardScreen(),
    ),
    GoRoute(
      path: '/prs/:id',
      builder: (context, state) {
        final id = int.parse(state.pathParameters['id']!);
        return PRDetailScreen(prId: id);
      },
    ),
    GoRoute(
      path: '/config',
      builder: (context, state) => const ConfigScreen(),
    ),
  ],
);
```

- [ ] **Step 7: Commit**

```bash
cd /Users/jamuriano/personal-workspace/auto-pr
git add flutter_app/lib/shared/ flutter_app/test/shared/
git commit -m "feat(widgets): SeverityBadge, Toast, and GoRouter setup"
```

---

### Task 7: Dashboard screen

**Files:**
- Create: `flutter_app/lib/features/dashboard/dashboard_screen.dart`
- Create: `flutter_app/test/features/dashboard_test.dart`

- [ ] **Step 1: Write dashboard widget test**

Create `flutter_app/test/features/dashboard_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:auto_pr/core/models/pr.dart';
import 'package:auto_pr/features/dashboard/dashboard_providers.dart';
import 'package:auto_pr/features/dashboard/dashboard_screen.dart';

void main() {
  testWidgets('DashboardScreen shows PR title', (tester) async {
    final pr = PR(
      id: 1, githubId: 101, repo: 'org/repo', number: 42,
      title: 'Fix critical bug', author: 'alice', url: 'https://github.com',
      state: 'open', updatedAt: DateTime.now(),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prsProvider.overrideWith((ref) => Future.value([pr])),
          sseStreamProvider.overrideWith((ref) => const Stream.empty()),
        ],
        child: MaterialApp.router(
          routerConfig: GoRouter(
            routes: [GoRoute(path: '/', builder: (_, __) => const DashboardScreen())],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Fix critical bug'), findsOneWidget);
    expect(find.text('org/repo'), findsOneWidget);
  });

  testWidgets('DashboardScreen shows loading indicator while fetching', (tester) async {
    final completer = Completer<List<PR>>(); // requires: import 'dart:async';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prsProvider.overrideWith((ref) => completer.future),
          sseStreamProvider.overrideWith((ref) => const Stream.empty()),
        ],
        child: MaterialApp.router(
          routerConfig: GoRouter(
            routes: [GoRoute(path: '/', builder: (_, __) => const DashboardScreen())],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd flutter_app && flutter test test/features/dashboard_test.dart 2>&1 | head -10
```
Expected: compilation error.

- [ ] **Step 3: Implement dashboard_screen.dart**

Create `flutter_app/lib/features/dashboard/dashboard_screen.dart`:
```dart
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
        title: const Text('auto-pr'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => context.go('/config'),
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
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 8),
              Text('Failed to load PRs: $e'),
              TextButton(
                onPressed: () => ref.invalidate(prsProvider),
                child: const Text('Retry'),
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
        columns: const [
          DataColumn(label: Text('Repo')),
          DataColumn(label: Text('PR')),
          DataColumn(label: Text('Author')),
          DataColumn(label: Text('Severity')),
          DataColumn(label: Text('Status')),
          DataColumn(label: Text('Actions')),
        ],
        rows: prs.map((pr) => DataRow(
          cells: [
            DataCell(Text(pr.repo)),
            DataCell(
              TextButton(
                onPressed: () => context.go('/prs/${pr.id}'),
                child: Text('#${pr.number} ${pr.title}'),
              ),
            ),
            DataCell(Text(pr.author)),
            DataCell(pr.latestReview != null
                ? SeverityBadge(severity: pr.latestReview!.severity)
                : const Text('—')),
            DataCell(Text(pr.latestReview != null ? 'Reviewed' : 'Pending')),
            DataCell(
              ElevatedButton(
                onPressed: () async {
                  final api = ref.read(apiClientProvider);
                  await api.triggerReview(pr.id);
                  ref.invalidate(prsProvider);
                },
                child: const Text('Review Now'),
              ),
            ),
          ],
        )).toList(),
      ),
    );
  }
}
```

- [ ] **Step 4: Run dashboard tests**

```bash
cd flutter_app && flutter test test/features/dashboard_test.dart -v
```
Expected: all 2 tests PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/jamuriano/personal-workspace/auto-pr
git add flutter_app/lib/features/dashboard/ flutter_app/test/features/dashboard_test.dart
git commit -m "feat(dashboard): PR list with severity badges and review trigger"
```

---

### Task 8: PR Detail screen

**Files:**
- Create: `flutter_app/lib/features/pr_detail/pr_detail_screen.dart`
- Create: `flutter_app/test/features/pr_detail_test.dart`

- [ ] **Step 1: Write PR detail test**

Create `flutter_app/test/features/pr_detail_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:auto_pr/core/models/pr.dart';
import 'package:auto_pr/core/models/review.dart';
import 'package:auto_pr/features/dashboard/dashboard_providers.dart';
import 'package:auto_pr/features/pr_detail/pr_detail_providers.dart';
import 'package:auto_pr/features/pr_detail/pr_detail_screen.dart';

void main() {
  testWidgets('PRDetailScreen shows review summary', (tester) async {
    final pr = PR(id: 1, githubId: 101, repo: 'org/repo', number: 42,
      title: 'Fix bug', author: 'alice', url: 'https://github.com',
      state: 'open', updatedAt: DateTime.now());
    final review = Review(id: 1, prId: 1, cliUsed: 'claude',
      summary: 'Overall looks good', issues: [], suggestions: ['add tests'],
      severity: 'low', createdAt: DateTime.now());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prDetailProvider(1).overrideWith((_) => Future.value({'pr': pr, 'reviews': [review]})),
          sseStreamProvider.overrideWith((ref) => const Stream.empty()),
        ],
        child: MaterialApp.router(
          routerConfig: GoRouter(routes: [
            GoRoute(path: '/', builder: (_, __) => const SizedBox()),
            GoRoute(path: '/prs/:id', builder: (ctx, state) =>
                PRDetailScreen(prId: int.parse(state.pathParameters['id']!))),
          ], initialLocation: '/prs/1'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Fix bug'), findsOneWidget);
    expect(find.text('Overall looks good'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Implement pr_detail_screen.dart**

Create `flutter_app/lib/features/pr_detail/pr_detail_screen.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/models/pr.dart';
import '../../core/models/review.dart';
import '../../shared/widgets/severity_badge.dart';
import '../../shared/widgets/toast.dart';
import '../dashboard/dashboard_providers.dart';
import 'pr_detail_providers.dart';

class PRDetailScreen extends ConsumerWidget {
  final int prId;
  const PRDetailScreen({super.key, required this.prId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detailAsync = ref.watch(prDetailProvider(prId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('PR Review'),
        actions: [
          ElevatedButton.icon(
            icon: const Icon(Icons.refresh),
            label: const Text('Re-review'),
            onPressed: () async {
              final api = ref.read(apiClientProvider);
              try {
                await api.triggerReview(prId);
                ref.invalidate(prDetailProvider(prId));
                if (context.mounted) showToast(context, 'Review queued');
              } catch (e) {
                if (context.mounted) showToast(context, 'Error: $e', isError: true);
              }
            },
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: detailAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (data) {
          final pr = data['pr'] as PR;
          final reviews = data['reviews'] as List<Review>;
          return Row(
            children: [
              // Left panel: review details
              Expanded(
                flex: 2,
                child: _ReviewPanel(pr: pr, reviews: reviews),
              ),
              const VerticalDivider(width: 1),
              // Right panel: PR metadata
              Expanded(
                flex: 1,
                child: _PRMetaPanel(pr: pr),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ReviewPanel extends StatelessWidget {
  final PR pr;
  final List<Review> reviews;
  const _ReviewPanel({required this.pr, required this.reviews});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(pr.title, style: Theme.of(context).textTheme.headlineSmall),
          Text('${pr.repo} #${pr.number} by ${pr.author}',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 16),
          if (reviews.isEmpty)
            const Text('No reviews yet.')
          else
            ...reviews.map((rev) => _ReviewCard(review: rev)),
        ],
      ),
    );
  }
}

class _ReviewCard extends StatelessWidget {
  final Review review;
  const _ReviewCard({required this.review});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Reviewed by ${review.cliUsed}',
                    style: Theme.of(context).textTheme.labelSmall),
                const Spacer(),
                SeverityBadge(severity: review.severity),
              ],
            ),
            const SizedBox(height: 8),
            Text(review.summary),
            if (review.issues.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Issues', style: Theme.of(context).textTheme.labelMedium),
              ...review.issues.map((issue) => Padding(
                padding: const EdgeInsets.only(top: 4, left: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.warning_amber, size: 14),
                    const SizedBox(width: 4),
                    Expanded(child: Text('${issue.file}:${issue.line} — ${issue.description}')),
                  ],
                ),
              )),
            ],
            if (review.suggestions.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Suggestions', style: Theme.of(context).textTheme.labelMedium),
              ...review.suggestions.map((s) => Padding(
                padding: const EdgeInsets.only(top: 4, left: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.lightbulb_outline, size: 14),
                    const SizedBox(width: 4),
                    Expanded(child: Text(s)),
                  ],
                ),
              )),
            ],
          ],
        ),
      ),
    );
  }
}

class _PRMetaPanel extends StatelessWidget {
  final PR pr;
  const _PRMetaPanel({required this.pr});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Details', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          _row('Repo', pr.repo),
          _row('Number', '#${pr.number}'),
          _row('Author', pr.author),
          _row('State', pr.state),
          _row('Updated', pr.updatedAt.toLocal().toString().substring(0, 16)),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.open_in_browser),
            label: const Text('Open on GitHub'),
            onPressed: () {
              // Platform-specific URL launch would go here
              // For now just copies the URL
            },
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(width: 72, child: Text('$label:', style: const TextStyle(fontWeight: FontWeight.w600))),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
```

- [ ] **Step 3: Run PR detail test**

```bash
cd flutter_app && flutter test test/features/pr_detail_test.dart -v
```
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
cd /Users/jamuriano/personal-workspace/auto-pr
git add flutter_app/lib/features/pr_detail/ flutter_app/test/features/pr_detail_test.dart
git commit -m "feat(pr-detail): split-panel PR review screen"
```

---

### Task 9: Config screen

**Files:**
- Create: `flutter_app/lib/features/config/config_screen.dart`
- Create: `flutter_app/test/features/config_test.dart`

- [ ] **Step 1: Write config screen test**

Create `flutter_app/test/features/config_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:auto_pr/core/api/api_client.dart';
import 'package:auto_pr/core/models/config_model.dart';
import 'package:auto_pr/features/config/config_providers.dart';
import 'package:auto_pr/features/config/config_screen.dart';
import 'package:auto_pr/features/dashboard/dashboard_providers.dart';

class MockApiClient extends Mock implements ApiClient {}

void main() {
  testWidgets('ConfigScreen shows current poll interval', (tester) async {
    final config = AppConfig(pollInterval: '5m', aiPrimary: 'claude', repositories: ['org/repo']);

    // Mock ApiClient so configNotifierProvider.build() doesn't call real HTTP
    final mockApi = MockApiClient();
    when(() => mockApi.fetchConfig()).thenAnswer((_) async => config.toJson());
    when(() => mockApi.updateConfig(any())).thenAnswer((_) async {});

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(mockApi),
          configNotifierProvider.overrideWith(ConfigNotifier.new),
        ],
        child: MaterialApp.router(
          routerConfig: GoRouter(routes: [
            GoRoute(path: '/', builder: (_, __) => const ConfigScreen()),
          ]),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('5m'), findsAtLeastNWidgets(1));
    expect(find.text('claude'), findsAtLeastNWidgets(1));
  });
}
```

- [ ] **Step 2: Implement config_screen.dart**

Create `flutter_app/lib/features/config/config_screen.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/models/config_model.dart';
import '../../shared/widgets/toast.dart';
import 'config_providers.dart';

class ConfigScreen extends ConsumerStatefulWidget {
  const ConfigScreen({super.key});

  @override
  ConsumerState<ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends ConsumerState<ConfigScreen> {
  final _reposController = TextEditingController();
  String _pollInterval = '5m';
  String _aiPrimary = 'claude';
  String _aiFallback = '';
  int _retentionDays = 90;
  bool _initialized = false;

  @override
  void dispose() {
    _reposController.dispose();
    super.dispose();
  }

  void _initFrom(AppConfig config) {
    if (_initialized) return;
    _initialized = true;
    _reposController.text = config.repositories.join(', ');
    _pollInterval = config.pollInterval;
    _aiPrimary = config.aiPrimary;
    _aiFallback = config.aiFallback;
    _retentionDays = config.retentionDays;
  }

  @override
  Widget build(BuildContext context) {
    final configAsync = ref.watch(configNotifierProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Configuration')),
      body: configAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (config) {
          _initFrom(config);
          return SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _section('GitHub'),
                  TextFormField(
                    controller: _reposController,
                    decoration: const InputDecoration(
                      labelText: 'Repositories (comma-separated)',
                      hintText: 'org/repo1, org/repo2',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _section('Polling'),
                  DropdownButtonFormField<String>(
                    value: _pollInterval,
                    decoration: const InputDecoration(
                      labelText: 'Poll Interval',
                      border: OutlineInputBorder(),
                    ),
                    items: ['1m', '5m', '30m', '1h']
                        .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                        .toList(),
                    onChanged: (v) => setState(() => _pollInterval = v!),
                  ),
                  const SizedBox(height: 16),
                  _section('AI'),
                  DropdownButtonFormField<String>(
                    value: _aiPrimary,
                    decoration: const InputDecoration(
                      labelText: 'Primary AI',
                      border: OutlineInputBorder(),
                    ),
                    items: ['claude', 'gemini', 'codex']
                        .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                        .toList(),
                    onChanged: (v) => setState(() => _aiPrimary = v!),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: _aiFallback.isEmpty ? null : _aiFallback,
                    decoration: const InputDecoration(
                      labelText: 'Fallback AI (optional)',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('None')),
                      ...['claude', 'gemini', 'codex']
                          .map((v) => DropdownMenuItem(value: v, child: Text(v))),
                    ],
                    onChanged: (v) => setState(() => _aiFallback = v ?? ''),
                  ),
                  const SizedBox(height: 16),
                  _section('Retention'),
                  TextFormField(
                    initialValue: _retentionDays.toString(),
                    decoration: const InputDecoration(
                      labelText: 'Keep reviews for (days, 0 = forever)',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                    onChanged: (v) => _retentionDays = int.tryParse(v) ?? 90,
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () async {
                        final repos = _reposController.text
                            .split(',')
                            .map((s) => s.trim())
                            .where((s) => s.isNotEmpty)
                            .toList();
                        final updated = config.copyWith(
                          repositories: repos,
                          pollInterval: _pollInterval,
                          aiPrimary: _aiPrimary,
                          aiFallback: _aiFallback,
                          retentionDays: _retentionDays,
                        );
                        try {
                          await ref.read(configNotifierProvider.notifier).save(updated);
                          if (context.mounted) showToast(context, 'Configuration saved');
                        } catch (e) {
                          if (context.mounted) showToast(context, 'Save failed: $e', isError: true);
                        }
                      },
                      child: const Text('Save'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.only(bottom: 8, top: 8),
    child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
  );
}
```

- [ ] **Step 3: Run config test**

```bash
cd flutter_app && flutter test test/features/config_test.dart -v
```
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
cd /Users/jamuriano/personal-workspace/auto-pr
git add flutter_app/lib/features/config/ flutter_app/test/features/config_test.dart
git commit -m "feat(config): settings screen with poll interval, AI selection, retention"
```

---

### Task 10: main.dart + final wiring

**Files:**
- Modify: `flutter_app/lib/main.dart`

- [ ] **Step 1: Implement main.dart**

Replace `flutter_app/lib/main.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/daemon/daemon_lifecycle.dart';
import 'shared/router.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _ensureDaemonRunning();
  runApp(const ProviderScope(child: AutoPRApp()));
}

Future<void> _ensureDaemonRunning() async {
  try {
    final lifecycle = DaemonLifecycle(
      daemonBinaryPath: DaemonLifecycle.defaultBinaryPath(),
    );
    await lifecycle.ensureRunning();
  } catch (e) {
    // Log and continue — user will see error state in UI
    debugPrint('Daemon start failed: $e');
  }
}

class AutoPRApp extends StatelessWidget {
  const AutoPRApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'auto-pr',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0969DA)),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0969DA),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      routerConfig: appRouter,
    );
  }
}
```

- [ ] **Step 2: Run all Flutter tests**

```bash
cd flutter_app && flutter test
```
Expected: all widget and unit tests PASS.

- [ ] **Step 3: Build macOS app in debug mode**

```bash
cd flutter_app && flutter build macos --debug 2>&1 | tail -10
```
Expected: build succeeds, `.app` bundle created in `build/macos/Build/Products/Debug/`.

- [ ] **Step 4: Commit**

```bash
cd /Users/jamuriano/personal-workspace/auto-pr
git add flutter_app/lib/main.dart
git commit -m "feat(main): app entry point with daemon lifecycle and router"
```

---

### Task 11: Packaging

**Files:**
- Create: `Makefile` (root-level)

- [ ] **Step 1: Create root Makefile**

Create `/Users/jamuriano/personal-workspace/auto-pr/Makefile`:
```makefile
.PHONY: build-daemon build-app test package-macos install-service dev

build-daemon:
	cd daemon && make build

build-app:
	cd flutter_app && flutter build macos --release

test:
	cd daemon && make test
	cd flutter_app && flutter test

package-macos: build-daemon build-app
	# Copy daemon binary into the .app bundle
	cp daemon/bin/auto-pr-daemon \
	  "flutter_app/build/macos/Build/Products/Release/auto_pr.app/Contents/MacOS/auto-pr-daemon"
	# Create DMG (requires: brew install create-dmg)
	create-dmg \
	  --volname "auto-pr" \
	  --window-size 540 380 \
	  --icon-size 128 \
	  --app-drop-link 380 185 \
	  "dist/auto-pr.dmg" \
	  "flutter_app/build/macos/Build/Products/Release/auto_pr.app"

install-service: build-daemon
	./daemon/bin/auto-pr-daemon install

dev:
	cd daemon && make dev &
	cd flutter_app && flutter run -d macos
```

- [ ] **Step 2: Create dist directory**

```bash
mkdir -p /Users/jamuriano/personal-workspace/auto-pr/dist
echo "# Distribution artifacts" > /Users/jamuriano/personal-workspace/auto-pr/dist/.gitkeep
```

- [ ] **Step 3: Run full test suite**

```bash
cd /Users/jamuriano/personal-workspace/auto-pr && make test
```
Expected: all daemon Go tests + all Flutter widget/unit tests PASS.

- [ ] **Step 4: Final commit**

```bash
cd /Users/jamuriano/personal-workspace/auto-pr
git add Makefile dist/
git commit -m "chore: root Makefile for build, test, and macOS packaging"
```

---

**Flutter plan complete.**

To run the full system:
1. `make build-daemon` — compile the Go daemon
2. Create `~/.config/auto-pr/config.toml` with your repos and AI config
3. Set `GITHUB_TOKEN` or run `daemon/bin/auto-pr-daemon` which will prompt via Keychain
4. `make dev` — starts daemon + Flutter app in development mode
