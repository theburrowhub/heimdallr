import 'dart:io';
import '../models/config_model.dart';

/// Handles first-run setup: writes config file to disk and stores
/// the GitHub token in macOS Keychain via the `security` CLI.
class FirstRunSetup {
  static const _keychainService = 'heimdallr';
  static const _keychainAccount = 'github-token';

  // ── Token ────────────────────────────────────────────────────────────────

  /// Tries to get a GitHub token in this priority order:
  ///   1. `gh auth token` (gh CLI, no user interaction needed)
  ///   2. Heimdallr Keychain entry
  ///   3. GITHUB_TOKEN env var
  ///   4. null (user must enter manually)
  static Future<String?> detectToken() async {
    // 1. gh CLI
    final ghToken = await _tokenFromGhCli();
    if (ghToken != null) return ghToken;

    // 2. Keychain
    final keychainToken = await getToken();
    if (keychainToken != null) return keychainToken;

    // 3. Env var
    final envToken = Platform.environment['GITHUB_TOKEN'];
    if (envToken != null && envToken.isNotEmpty) return envToken;

    return null;
  }

  static Future<String?> _tokenFromGhCli() async {
    try {
      final which = await Process.run('which', ['gh']);
      if (which.exitCode != 0) return null;
      final result = await Process.run('gh', ['auth', 'token']);
      if (result.exitCode == 0) {
        final t = (result.stdout as String).trim();
        return t.isEmpty ? null : t;
      }
    } catch (_) {}
    return null;
  }

  /// Stores the GitHub token in macOS Keychain.
  static Future<void> storeToken(String token) async {
    await Process.run('security', [
      'delete-generic-password', '-s', _keychainService, '-a', _keychainAccount,
    ]);
    final result = await Process.run('security', [
      'add-generic-password',
      '-s', _keychainService,
      '-a', _keychainAccount,
      '-w', token,
    ]);
    if (result.exitCode != 0) {
      throw Exception('Failed to store token in Keychain: ${result.stderr}');
    }
  }

  /// Retrieves the GitHub token from macOS Keychain. Returns null if not found.
  static Future<String?> getToken() async {
    final result = await Process.run('security', [
      'find-generic-password', '-s', _keychainService, '-a', _keychainAccount, '-w',
    ]);
    if (result.exitCode == 0) {
      final token = (result.stdout as String).trim();
      return token.isEmpty ? null : token;
    }
    return null;
  }

  // ── Config file ──────────────────────────────────────────────────────────

  /// Writes the daemon config file to ~/.config/heimdallr/config.toml
  static Future<void> writeConfig(AppConfig config) async {
    final home = Platform.environment['HOME'] ?? '';
    if (home.isEmpty) throw Exception('HOME environment variable not set');

    final dir = Directory('$home/.config/heimdallr');
    await dir.create(recursive: true);

    final content = _buildToml(config);
    await File('$home/.config/heimdallr/config.toml').writeAsString(content);
  }

  static String _buildToml(AppConfig config) {
    final buf = StringBuffer();

    buf.writeln('[server]');
    buf.writeln('port = ${config.serverPort}');
    buf.writeln();

    buf.writeln('[github]');
    buf.writeln('poll_interval = "${config.pollInterval}"');
    final repos = config.repositories.map((r) => '"$r"').join(', ');
    buf.writeln('repositories = [$repos]');
    buf.writeln();

    buf.writeln('[ai]');
    buf.writeln('primary = "${config.aiPrimary}"');
    if (config.aiFallback.isNotEmpty) {
      buf.writeln('fallback = "${config.aiFallback}"');
    }
    buf.writeln();

    // Per-repo AI overrides
    for (final entry in config.repoConfigs.entries) {
      final repo = entry.key;
      final rc = entry.value;
      if (rc.monitored && rc.hasAiOverride) {
        buf.writeln('[ai.repos."$repo"]');
        if (rc.aiPrimary != null) buf.writeln('primary = "${rc.aiPrimary}"');
        if (rc.aiPrimary != null && rc.aiFallback != null) {
          buf.writeln('fallback = "${rc.aiFallback}"');
        }
        buf.writeln();
      }
    }

    buf.writeln('[retention]');
    buf.writeln('max_days = ${config.retentionDays}');

    return buf.toString();
  }

  /// Returns true if a config file already exists.
  static Future<bool> configExists() async {
    final home = Platform.environment['HOME'] ?? '';
    return File('$home/.config/heimdallr/config.toml').exists();
  }
}
