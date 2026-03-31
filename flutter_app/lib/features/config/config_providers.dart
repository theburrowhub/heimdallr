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
