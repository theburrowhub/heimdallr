import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/api/api_client.dart';
import 'core/daemon/daemon_lifecycle.dart';
import 'core/setup/first_run_setup.dart';
import 'core/setup/repo_discovery.dart';
import 'core/models/config_model.dart';
import 'shared/router.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: _BootstrapApp()));
}

/// Shows a splash screen while the async startup runs,
/// then replaces itself with the real app pointing to the right route.
class _BootstrapApp extends StatefulWidget {
  const _BootstrapApp();

  @override
  State<_BootstrapApp> createState() => _BootstrapAppState();
}

class _BootstrapAppState extends State<_BootstrapApp> {
  String? _initialLocation;
  String _status = 'Starting…';

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    final api = ApiClient();

    // 1. Daemon ya corriendo → dashboard directamente
    if (await api.checkHealth()) {
      _go('/');
      return;
    }

    // 2. ¿Hay config en disco? → intenta arrancar con ella
    if (await FirstRunSetup.configExists()) {
      _setStatus('Starting Heimdallr…');
      if (await _startDaemon()) {
        _go('/');
        return;
      }
      // Config existe pero daemon no arrancó → config screen para depurar
      _go('/config');
      return;
    }

    // 3. ¿Hay token disponible? → auto-setup completo
    _setStatus('Detecting credentials…');
    final token = await FirstRunSetup.detectToken();
    if (token != null) {
      _setStatus('Discovering repositories…');
      final repos = await RepoDiscovery.discoverFromPRs(token);

      _setStatus('Saving configuration…');
      final config = AppConfig(
        repoConfigs: {
          for (final r in repos) r: const RepoConfig(monitored: true),
        },
      );
      await FirstRunSetup.storeToken(token);
      await FirstRunSetup.writeConfig(config);

      _setStatus('Starting Heimdallr…');
      if (await _startDaemon()) {
        _go('/');
        return;
      }
    }

    // 4. Sin token o daemon no arrancó → configuración manual
    _go('/config');
  }

  Future<bool> _startDaemon() async {
    try {
      final binaryPath = DaemonLifecycle.defaultBinaryPath();
      if (!File(binaryPath).existsSync()) return false;

      await Process.start(binaryPath, []);

      final api = ApiClient();
      for (var i = 0; i < 80; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
        if (await api.checkHealth()) return true;
      }
    } catch (_) {}
    return false;
  }

  void _setStatus(String s) {
    if (mounted) setState(() => _status = s);
  }

  void _go(String location) {
    if (mounted) setState(() => _initialLocation = location);
  }

  @override
  Widget build(BuildContext context) {
    if (_initialLocation != null) {
      return HeimdallrApp(initialLocation: _initialLocation!);
    }

    // Splash mientras arranca
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
              const Text('Heimdallr',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
              const SizedBox(height: 24),
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(_status, style: const TextStyle(color: Colors.grey)),
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
