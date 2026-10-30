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
    this.baseline,
    this.harness = 'openHands',
    this.mainAgent = '',
    this.effort = '',
    this.holdClientTools = false,
    this.compactedFrom = const [],
    this.parentId,
    this.parentCallId = '',
    this.ownTag = false,
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

  /// The session's own checkout and branch, for isolated sessions (forks,
  /// subagents, Ultra steps, or when asked for); null when it works in place.
  final SessionWorktree? worktree;

  /// For a session working in place in a git repository: where it started,
  /// so Changes can show what it did.
  final GitBaseline? baseline;

  /// The harness it runs on (`CodeHarnessKind` name); sessions from before
  /// there was a choice ran on OpenHands.
  final String harness;

  /// The library agent running the session ('' for the EveryAI agent).
  final String mainAgent;

  /// The snapshot Changes diffs against: the worktree, or the in-place
  /// baseline's read-only view.
  SessionWorktree? get diffTarget => worktree ?? baseline?.diffView;

  /// The model's reasoning effort ('' for the server default).
  final String effort;

  /// Question cards and plans are answered inside the held tool call (see
  /// `SessionSpec.holdClientTools`). Off for sessions started before it.
  final bool holdClientTools;

  /// Conversations this session ran in before it was compacted, oldest first.
  final List<String> compactedFrom;
  final DateTime createdAt;

  /// For a subagent: the session that started it, and the id of its `run_subagent`
  /// call there. Subagents are left out of session lists.
  final String? parentId;
  final String parentCallId;

  /// A child billed under its own id rather than its parent's (an Ultra
  /// step or orchestrator), so its cost can be read alone.
  final bool ownTag;

  bool get isSubagent => parentId != null;

  /// The id its model calls are billed under (`X-EveryAI-Session`), and
  /// the tag its processes carry: its own, or its parent's for a subagent.
  String get billingTag => ownTag ? id : parentId ?? id;

  CodeSessionInfo copyWith({
    String? title,
    AgentMode? mode,
    String? branch,
    String? conversationId,
    List<String>? compactedFrom,
    String? model,
    String? effort,
  }) => CodeSessionInfo(
    id: id,
    projectId: projectId,
    title: title ?? this.title,
    conversationId: conversationId ?? this.conversationId,
    model: model ?? this.model,
    mode: mode ?? this.mode,
    workingDir: workingDir,
    createdAt: createdAt,
    branch: branch ?? this.branch,
    worktree: worktree,
    baseline: baseline,
    harness: harness,
    mainAgent: mainAgent,
    effort: effort ?? this.effort,
    holdClientTools: holdClientTools,
    compactedFrom: compactedFrom ?? this.compactedFrom,
    parentId: parentId,
    parentCallId: parentCallId,
    ownTag: ownTag,
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
    harness: json['harness'] as String? ?? 'openHands',
    mainAgent: json['main_agent'] as String? ?? '',
    baseline: json['baseline'] is Map<String, Object?>
        ? GitBaseline.fromJson(json['baseline']! as Map<String, Object?>)
        : null,
    createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ?? DateTime.now(),
    parentId: json['parent_id'] as String?,
    parentCallId: json['parent_call_id'] as String? ?? '',
    // Ultra children saved before the flag was kept billed under their own id too.
    ownTag: json['own_tag'] == true || (json['parent_call_id'] as String? ?? '').startsWith('ultra-'),
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
    'baseline': ?baseline?.toJson(),
    'harness': harness,
    if (mainAgent.isNotEmpty) 'main_agent': mainAgent,
    'effort': effort,
    if (holdClientTools) 'hold_client_tools': true,
    if (compactedFrom.isNotEmpty) 'compacted_from': compactedFrom,
    'created_at': createdAt.toIso8601String(),
    'parent_id': ?parentId,
    if (parentCallId.isNotEmpty) 'parent_call_id': parentCallId,
    if (ownTag) 'own_tag': true,
  };
}
