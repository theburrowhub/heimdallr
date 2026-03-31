import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

/// Discovers GitHub repos the user has access to.
///
/// Priority:
///   1. `gh repo list` (uses gh CLI auth — no token needed)
///   2. GitHub API with the provided token
class RepoDiscovery {
  /// Returns repos as "org/repo" strings, sorted alphabetically.
  static Future<List<String>> discover({String? token}) async {
    final ghPath = await _which('gh');
    if (ghPath != null) {
      final repos = await _viaGhCli(ghPath);
      if (repos.isNotEmpty) return repos;
    }

    if (token != null && token.isNotEmpty) {
      return _viaApi(token);
    }

    return [];
  }

  static Future<List<String>> _viaGhCli(String ghPath) async {
    try {
      final result = await Process.run(ghPath, [
        'repo', 'list',
        '--limit', '300',
        '--json', 'nameWithOwner',
      ]);
      if (result.exitCode != 0) return [];
      final list = jsonDecode(result.stdout as String) as List<dynamic>;
      return (list.map((r) => r['nameWithOwner'] as String).toList()..sort());
    } catch (_) {
      return [];
    }
  }

  static Future<List<String>> _viaApi(String token) async {
    final repos = <String>[];
    var page = 1;
    final client = http.Client();
    try {
      while (true) {
        final uri = Uri.parse(
          'https://api.github.com/user/repos?type=all&per_page=100&page=$page',
        );
        final resp = await client.get(uri, headers: {
          'Authorization': 'Bearer $token',
          'Accept': 'application/vnd.github+json',
          'X-GitHub-Api-Version': '2022-11-28',
        });
        if (resp.statusCode != 200) break;
        final list = jsonDecode(resp.body) as List<dynamic>;
        if (list.isEmpty) break;
        repos.addAll(list.map((r) => r['full_name'] as String));
        if (list.length < 100) break;
        page++;
      }
    } finally {
      client.close();
    }
    return repos..sort();
  }

  static Future<String?> _which(String cmd) async {
    try {
      final r = await Process.run('which', [cmd]);
      if (r.exitCode == 0) return (r.stdout as String).trim();
    } catch (_) {}
    return null;
  }

  /// Returns true if the `gh` CLI is installed and authenticated.
  static Future<bool> ghCliAvailable() async {
    final path = await _which('gh');
    if (path == null) return false;
    final r = await Process.run(path, ['auth', 'status']);
    return r.exitCode == 0;
  }
}
