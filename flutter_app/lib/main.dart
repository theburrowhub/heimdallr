import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/api/api_client.dart';
import 'core/daemon/daemon_lifecycle.dart';
import 'shared/router.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Intenta arrancar el daemon si no está corriendo.
  // Los errores se capturan — si el daemon no puede arrancar
  // (sin config aún), la app abrirá en la pantalla de configuración.
  await _tryStartDaemon();

  // Elige la pantalla inicial:
  //   - Daemon sano    → Dashboard (/)
  //   - Daemon no corre → Configuración (/config)
  final healthy = await ApiClient().checkHealth();
  final initialLocation = healthy ? '/' : '/config';

  runApp(ProviderScope(
    child: HeimdallrApp(initialLocation: initialLocation),
  ));
}

Future<void> _tryStartDaemon() async {
  try {
    final lifecycle = DaemonLifecycle(
      daemonBinaryPath: DaemonLifecycle.defaultBinaryPath(),
    );
    await lifecycle.ensureRunning();
  } catch (_) {
    // Sin config todavía — la app mostrará el setup
  }
}

class HeimdallrApp extends StatelessWidget {
  final String initialLocation;

  const HeimdallrApp({super.key, this.initialLocation = '/'});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Heimdallr',
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
