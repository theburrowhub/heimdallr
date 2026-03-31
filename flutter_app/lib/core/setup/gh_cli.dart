import 'dart:io';

/// Utilities for the `gh` CLI.
///
/// Flutter macOS GUI apps do NOT inherit the user's shell PATH.
/// Homebrew installs to /opt/homebrew/bin (Apple Silicon) or /usr/local/bin (Intel).
/// We must find `gh` explicitly.
class GhCli {
  // Known installation paths for gh CLI
  static const _knownPaths = [
    '/opt/homebrew/bin/gh',  // Apple Silicon homebrew
    '/usr/local/bin/gh',      // Intel homebrew / manual install
    '/usr/bin/gh',
    '/usr/local/sbin/gh',
  ];

  /// Returns the full path to the `gh` binary, or null if not found.
  static Future<String?> findPath() async {
    // 1. Try a login shell — picks up the user's PATH from .zshrc / .bash_profile
    try {
      final r = await Process.run(
        '/bin/bash', ['-l', '-c', 'which gh'],
        runInShell: false,
      );
      if (r.exitCode == 0) {
        final p = (r.stdout as String).trim();
        if (p.isNotEmpty && File(p).existsSync()) return p;
      }
    } catch (_) {}

    // 2. Check hardcoded locations
    for (final path in _knownPaths) {
      if (File(path).existsSync()) return path;
    }

    return null;
  }

  /// Returns the GitHub token from `gh auth token`, or null.
  static Future<String?> authToken() async {
    final ghPath = await findPath();
    if (ghPath == null) return null;
    try {
      final result = await Process.run(ghPath, ['auth', 'token']);
      if (result.exitCode == 0) {
        final t = (result.stdout as String).trim();
        return t.isEmpty ? null : t;
      }
    } catch (_) {}
    return null;
  }

  /// Runs `gh search prs` with the given extra args.
  /// Returns stdout string, or null on failure.
  static Future<String?> searchPRs(List<String> extraArgs) async {
    final ghPath = await findPath();
    if (ghPath == null) return null;
    try {
      final result = await Process.run(ghPath, [
        'search', 'prs', ...extraArgs,
      ]);
      if (result.exitCode == 0) return result.stdout as String;
    } catch (_) {}
    return null;
  }
}
