import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/api/api_client.dart';
import 'core/setup/first_run_setup.dart';
import 'core/setup/repo_discovery.dart';
import 'core/models/config_model.dart';
import 'shared/router.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: _BootstrapApp()));
}

class _BootstrapApp extends StatefulWidget {
  const _BootstrapApp();
  @override
  State<_BootstrapApp> createState() => _BootstrapAppState();
}

class _BootstrapAppState extends State<_BootstrapApp> {
  String? _destination; // null = still booting
  String _status = 'Starting…';

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    final api = ApiClient();

    // ── 1. Daemon already healthy? ───────────────────────────────────────
    if (await api.checkHealth()) {
      _go('/');
      return;
    }

    // ── 2. Get token ─────────────────────────────────────────────────────
    _setStatus('Detecting credentials…');
    final token = await FirstRunSetup.detectToken();

    if (token == null) {
      // No token anywhere → user must configure manually
      _go('/config');
      return;
    }

    // ── 3. Write config if it doesn't exist yet ──────────────────────────
    if (!await FirstRunSetup.configExists()) {
      _setStatus('Discovering repositories…');
      final repos = await RepoDiscovery.discoverFromPRs(token);

      _setStatus('Setting up…');
      final config = AppConfig(
        repoConfigs: {
          for (final r in repos) r: const RepoConfig(monitored: true),
        },
      );
      await FirstRunSetup.storeToken(token);
      await FirstRunSetup.writeConfig(config);
    }

    // ── 4. Start daemon if binary exists ─────────────────────────────────
    final binaryPath = _daemonBinaryPath();
    if (binaryPath != null && File(binaryPath).existsSync()) {
      _setStatus('Starting Heimdallr…');
      try {
        await Process.start(binaryPath, []);
      } catch (_) {}
    }

    // ── 5. Wait indefinitely for daemon to be healthy ────────────────────
    //      The daemon may take a moment to bind to the port.
    //      Show the splash with the icon until it responds.
    _setStatus('Waiting for Heimdallr…');
    for (var attempt = 0; ; attempt++) {
      await Future.delayed(const Duration(milliseconds: 400));
      if (await api.checkHealth()) {
        _go('/');
        return;
      }
      // Every 10 seconds try re-launching (in case it crashed at start)
      if (attempt > 0 && attempt % 25 == 0 && binaryPath != null) {
        try { await Process.start(binaryPath, []); } catch (_) {}
      }
    }
  }

  /// Returns the daemon binary path, or null if not determinable.
  String? _daemonBinaryPath() {
    final env = Platform.environment['HEIMDALLR_DAEMON_PATH'];
    if (env != null && env.isNotEmpty) return env;
    final dir = File(Platform.resolvedExecutable).parent.path;
    final candidate = '$dir/heimdallr';
    return File(candidate).existsSync() ? candidate : null;
  }

  void _setStatus(String s) {
    if (mounted) setState(() => _status = s);
  }

  void _go(String location) {
    if (mounted) setState(() => _destination = location);
  }

  @override
  Widget build(BuildContext context) {
    if (_destination != null) {
      return HeimdallrApp(initialLocation: _destination!);
    }

    return _SplashApp(status: _status);
  }
}

class _SplashApp extends StatelessWidget {
  final String status;
  const _SplashApp({required this.status});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
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
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset('assets/icon.png', width: 96, height: 96,
                  errorBuilder: (_, __, ___) => const Icon(Icons.shield, size: 96)),
              const SizedBox(height: 24),
              const Text('Heimdallr',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),
              const SizedBox(
                width: 24, height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              const SizedBox(height: 12),
              Text(status, style: const TextStyle(color: Colors.grey)),
            ],
          ),
        ),
      ),
    );
  }
}

class HeimdallrApp extends StatelessWidget {
  final String initialLocation;
  const HeimdallrApp({super.key, this.initialLocation = '/'});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Heimdallr',
      debugShowCheckedModeBanner: false,
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
      routerConfig: createRouter(initialLocation: initialLocation),
    );
  }
}
