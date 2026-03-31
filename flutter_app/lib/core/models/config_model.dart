/// Per-repo AI override. null fields mean "use global default".
class RepoConfig {
  final bool monitored;
  final String? aiPrimary;  // null = use global
  final String? aiFallback; // null = use global

  const RepoConfig({
    this.monitored = true,
    this.aiPrimary,
    this.aiFallback,
  });

  bool get hasAiOverride => aiPrimary != null || aiFallback != null;

  RepoConfig copyWith({
    bool? monitored,
    Object? aiPrimary = _sentinel, // use sentinel to distinguish null from "not provided"
    Object? aiFallback = _sentinel,
  }) {
    return RepoConfig(
      monitored: monitored ?? this.monitored,
      aiPrimary: aiPrimary == _sentinel ? this.aiPrimary : aiPrimary as String?,
      aiFallback: aiFallback == _sentinel ? this.aiFallback : aiFallback as String?,
    );
  }
}

const _sentinel = Object();

class AppConfig {
  final int serverPort;
  final String pollInterval;
  final String aiPrimary;
  final String aiFallback;
  final int retentionDays;

  /// All known repos and their per-repo settings.
  /// Key: "org/repo". Monitored repos are sent to the daemon.
  final Map<String, RepoConfig> repoConfigs;

  const AppConfig({
    this.serverPort = 7842,
    this.pollInterval = '5m',
    this.aiPrimary = 'claude',
    this.aiFallback = '',
    this.retentionDays = 90,
    this.repoConfigs = const {},
  });

  /// Computed list of monitored repos — this is what the daemon uses.
  List<String> get repositories => (repoConfigs.entries
      .where((e) => e.value.monitored)
      .map((e) => e.key)
      .toList()
    ..sort());

  AppConfig copyWith({
    int? serverPort,
    String? pollInterval,
    String? aiPrimary,
    String? aiFallback,
    int? retentionDays,
    Map<String, RepoConfig>? repoConfigs,
  }) {
    return AppConfig(
      serverPort: serverPort ?? this.serverPort,
      pollInterval: pollInterval ?? this.pollInterval,
      aiPrimary: aiPrimary ?? this.aiPrimary,
      aiFallback: aiFallback ?? this.aiFallback,
      retentionDays: retentionDays ?? this.retentionDays,
      repoConfigs: repoConfigs ?? this.repoConfigs,
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

  factory AppConfig.fromJson(Map<String, dynamic> json) {
    final repos = (json['repositories'] as List<dynamic>?)?.cast<String>() ?? [];
    // Start with all monitored repos (no override)
    final configs = <String, RepoConfig>{
      for (final r in repos) r: const RepoConfig(monitored: true),
    };
    // Apply per-repo AI overrides from repo_overrides field
    final overrides = json['repo_overrides'] as Map<String, dynamic>?;
    if (overrides != null) {
      for (final entry in overrides.entries) {
        final ov = entry.value as Map<String, dynamic>;
        configs[entry.key] = RepoConfig(
          monitored: configs.containsKey(entry.key),
          aiPrimary: ov['primary'] as String?,
          aiFallback: ov['fallback'] as String?,
        );
      }
    }
    return AppConfig(
      serverPort: (json['server_port'] as int?) ?? 7842,
      pollInterval: (json['poll_interval'] as String?) ?? '5m',
      aiPrimary: (json['ai_primary'] as String?) ?? 'claude',
      aiFallback: (json['ai_fallback'] as String?) ?? '',
      retentionDays: (json['retention_days'] as int?) ?? 90,
      repoConfigs: configs,
    );
  }
}
