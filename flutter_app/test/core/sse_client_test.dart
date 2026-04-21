import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:heimdallm/core/api/sse_client.dart';
import 'platform/fake_platform_services.dart';

void main() {
  // ── parser tests (existing) ─────────────────────────────────────────────
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

  // ── connection URL + header tests (new) ─────────────────────────────────
  group('SseClient connect', () {
    test('desktop uses absolute URL and sends X-Heimdallm-Token', () async {
      final platform = FakePlatformServices(
        apiBaseUrl: 'http://127.0.0.1:7842',
        token: 'tok-xyz',
      );
      http.BaseRequest? captured;
      final mockClient = MockClient.streaming((request, _) async {
        captured = request;
        final bytes = Stream<List<int>>.value(utf8.encode(': hello\n\n'));
        return http.StreamedResponse(bytes, 200,
            headers: {'content-type': 'text/event-stream'});
      });
      final client = SseClient(
        httpClient: mockClient,
        platform: platform,
        path: '/events',
      );
      final sub = client.connect().listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(captured, isNotNull);
      expect(captured!.url.toString(), 'http://127.0.0.1:7842/events');
      expect(captured!.headers['X-Heimdallm-Token'], 'tok-xyz');
      expect(captured!.headers['Accept'], 'text/event-stream');

      await sub.cancel();
    });

    test('web uses relative /api/<path> and omits the auth header', () async {
      final platform = FakePlatformServices(
        apiBaseUrl: '/api',
        token: null,
      );
      http.BaseRequest? captured;
      final mockClient = MockClient.streaming((request, _) async {
        captured = request;
        final bytes = Stream<List<int>>.value(utf8.encode(': hi\n\n'));
        return http.StreamedResponse(bytes, 200,
            headers: {'content-type': 'text/event-stream'});
      });
      final client = SseClient(
        httpClient: mockClient,
        platform: platform,
        path: '/logs/stream',
      );
      final sub = client.connect().listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(captured, isNotNull);
      expect(captured!.url.path.endsWith('/api/logs/stream'), isTrue,
          reason: 'expected path ending in /api/logs/stream, got ${captured!.url}');
      expect(captured!.headers.containsKey('X-Heimdallm-Token'), isFalse);

      await sub.cancel();
    });
  });
}
