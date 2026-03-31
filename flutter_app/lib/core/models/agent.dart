class Agent {
  final String id;
  final String name;
  final String cli; // claude | gemini | codex
  final String prompt;
  final bool isDefault;

  const Agent({
    required this.id,
    required this.name,
    this.cli = 'claude',
    required this.prompt,
    this.isDefault = false,
  });

  Agent copyWith({
    String? id,
    String? name,
    String? cli,
    String? prompt,
    bool? isDefault,
  }) => Agent(
    id: id ?? this.id,
    name: name ?? this.name,
    cli: cli ?? this.cli,
    prompt: prompt ?? this.prompt,
    isDefault: isDefault ?? this.isDefault,
  );

  factory Agent.fromJson(Map<String, dynamic> json) => Agent(
    id: json['id'] as String,
    name: json['name'] as String,
    cli: (json['cli'] as String?) ?? 'claude',
    prompt: (json['prompt'] as String?) ?? '',
    isDefault: (json['is_default'] as bool?) ?? false,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'cli': cli,
    'prompt': prompt,
    'is_default': isDefault,
  };

  static const defaultPrompt = '''You are a senior software engineer performing a pull request code review.

PR: {title} (#{number})
Repo: {repo}
Author: {author}
Link: {link}

Diff:
{diff}

Review the diff and respond with ONLY valid JSON (no markdown, no explanation):
{
  "summary": "brief overall assessment",
  "issues": [
    {"file": "filename", "line": 0, "description": "issue description", "severity": "low|medium|high"}
  ],
  "suggestions": ["suggestion 1"],
  "severity": "low|medium|high"
}''';

  /// Available placeholders for prompt templates.
  static const placeholders = [
    '{title}', '{number}', '{repo}', '{author}', '{link}', '{diff}',
  ];
}
