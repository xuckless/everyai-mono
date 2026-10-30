import 'package:flutter/foundation.dart';

import '../git/git_models.dart';

import 'agent_mode.dart';

/// A folder the agent works in.
@immutable
final class CodeProject {
  const CodeProject({required this.id, required this.name, required this.path});

  final String id;
  final String name;
  final String path;

  factory CodeProject.fromJson(Map<String, Object?> json) =>
      CodeProject(id: json['id']! as String, name: json['name']! as String, path: json['path']! as String);

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'path': path};
}

enum SessionStatus {
  starting('Starting'),
  running('Working'),
  needsInput('Needs input'),
  idle('Idle'),
  done('Done'),
  failed('Failed');

  const SessionStatus(this.label);
  final String label;
}

@immutable
final class CodeSessionInfo {
  const CodeSessionInfo({
    required this.id,
    required this.projectId,
    required this.title,
    required this.conversationId,
    required this.model,
    required this.mode,
    required this.workingDir,
    required this.createdAt,
    this.branch = '',
    this.worktree,
    this.effort = '',
    this.holdClientTools = false,
    this.compactedFrom = const [],
  });

  final String id;
  final String projectId;
  final String title;

  /// The agent server's conversation id.
  final String conversationId;
  final String model;
  final AgentMode mode;

  /// Where the agent works: the session's worktree, or the project folder
  /// when it isn't a git repository.
  final String workingDir;
  final String branch;

  /// The session's own checkout and branch; null for folders without git.
  final SessionWorktree? worktree;

  /// The model's reasoning effort ('' for the server default).
  final String effort;

  /// Question cards and plans are answered inside the held tool call (see
  /// `SessionSpec.holdClientTools`). Off for sessions started before it.
  final bool holdClientTools;

  /// Conversations this session ran in before it was compacted, oldest first.
  final List<String> compactedFrom;
  final DateTime createdAt;

  CodeSessionInfo copyWith({
    String? title,
    AgentMode? mode,
    String? branch,
    String? conversationId,
    List<String>? compactedFrom,
  }) => CodeSessionInfo(
    id: id,
    projectId: projectId,
    title: title ?? this.title,
    conversationId: conversationId ?? this.conversationId,
    model: model,
    mode: mode ?? this.mode,
    workingDir: workingDir,
    createdAt: createdAt,
    branch: branch ?? this.branch,
    worktree: worktree,
    effort: effort,
    holdClientTools: holdClientTools,
    compactedFrom: compactedFrom ?? this.compactedFrom,
  );

  factory CodeSessionInfo.fromJson(Map<String, Object?> json) => CodeSessionInfo(
    id: json['id']! as String,
    projectId: json['project_id']! as String,
    title: json['title'] as String? ?? 'Session',
    conversationId: json['conversation_id']! as String,
    model: json['model'] as String? ?? '',
    mode: AgentMode.values.asNameMap()[json['mode']] ?? AgentMode.ask,
    workingDir: json['working_dir'] as String? ?? '',
    branch: json['branch'] as String? ?? '',
    effort: json['effort'] as String? ?? '',
    holdClientTools: json['hold_client_tools'] == true,
    compactedFrom: [
      for (final id in json['compacted_from'] as List<Object?>? ?? const [])
        if (id is String) id,
    ],
    worktree: json['worktree'] is Map<String, Object?>
        ? SessionWorktree.fromJson(json['worktree']! as Map<String, Object?>)
        : null,
    createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ?? DateTime.now(),
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'project_id': projectId,
    'title': title,
    'conversation_id': conversationId,
    'model': model,
    'mode': mode.name,
    'working_dir': workingDir,
    'branch': branch,
    'worktree': ?worktree?.toJson(),
    'effort': effort,
    if (holdClientTools) 'hold_client_tools': true,
    if (compactedFrom.isNotEmpty) 'compacted_from': compactedFrom,
    'created_at': createdAt.toIso8601String(),
  };
}
