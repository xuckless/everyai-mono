// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

// Plan batches: a plan's change batches, each one agent's work with the check
// that gates its merge. A plan lists them in a ```json batches block; a
// workflow passes one as agent()'s `batch` option, and the app runs its check
// in the agent's worktree before merging it (see `runBatchCheck`). The
// prelude's `batchOf` (workflow_prelude.dart) holds the same rules in JS.

/// How a batch proves itself before it merges.
sealed class BatchCheck {
  const BatchCheck();

  Object toJson();
}

/// The tests that cover [files] (empty: the batch's own files).
final class FilesCheck extends BatchCheck {
  const FilesCheck(this.files);
  final List<String> files;

  @override
  Object toJson() => {'files': files};
}

/// One shell command; it passes on exit 0.
final class CommandCheck extends BatchCheck {
  const CommandCheck(this.command);
  final String command;

  @override
  Object toJson() => {'command': command};
}

/// The whole suite of each project the batch's files are in.
final class FullCheck extends BatchCheck {
  const FullCheck();

  @override
  Object toJson() => 'full';
}

/// One change batch. Without a [check] it isn't gated.
final class PlanBatch {
  const PlanBatch({required this.id, required this.intent, this.files = const [], this.check});
  final String id;
  final String intent;
  final List<String> files;
  final BatchCheck? check;

  Map<String, Object?> toJson() => {'id': id, 'intent': intent, 'files': files, 'check': ?check?.toJson()};
}

final _id = RegExp(r'^[a-z0-9][a-z0-9-]{0,31}$');

/// Why [p] isn't a path relative to the project, or null.
/// Takes [p] trimmed, the form it is kept in.
String? _pathProblem(String p) {
  if (p.isEmpty) return 'a path must be a non-empty string';
  if (p.startsWith('/') || p.startsWith('~') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(p)) {
    return '$p: paths are relative to the project';
  }
  if (p.split(RegExp(r'[\\/]')).contains('..')) return '$p: a path may not contain ..';
  return null;
}

List<String> _paths(Object? json, String where, List<String> problems) {
  if (json == null) return const [];
  if (json is! List) {
    problems.add('$where must be a list of paths');
    return const [];
  }
  final out = <String>[];
  for (final p in json) {
    final path = p is String ? p.trim() : '';
    if (_pathProblem(path) case final why?) {
      problems.add('$where: $why');
    } else {
      out.add(path);
    }
  }
  return out;
}

BatchCheck? _checkOf(Object? json, List<String> problems) {
  switch (json) {
    case null:
      return null;
    case 'full':
      return const FullCheck();
    case {'files': final files} when (json as Map).length == 1:
      return FilesCheck(_paths(files, 'check.files', problems));
    case {'command': final command} when (json as Map).length == 1:
      if (command is! String || command.trim().isEmpty) {
        problems.add('check.command must be a non-empty string');
        return null;
      }
      if (command.contains('\n')) {
        problems.add('check.command must be one line');
        return null;
      }
      return CommandCheck(command.trim());
    default:
      problems.add('check must be {"files": [...]}, {"command": "..."} or "full"');
      return null;
  }
}

/// [json] as a batch, or the problems that stop it (readable, one per fault).
({PlanBatch? batch, List<String> problems}) parseBatch(Object? json) {
  if (json is! Map) return (batch: null, problems: const ['a batch must be an object {id, intent, files, check}']);
  final problems = <String>[];
  final id = json['id'];
  if (id is! String || !_id.hasMatch(id)) {
    problems.add('id must be a short slug (lowercase letters, digits and dashes, at most 32)');
  }
  final intent = json['intent'];
  if (intent is! String || intent.trim().isEmpty) problems.add('intent must say what the batch changes');
  final files = _paths(json['files'], 'files', problems);
  final check = _checkOf(json['check'], problems);
  // These find their tests from the batch's files: with none, the check could never pass.
  if (files.isEmpty && (check is FullCheck || (check is FilesCheck && check.files.isEmpty))) {
    problems.add('a "full" check, or {"files": []}, needs the batch\'s files');
  }
  if (problems.isNotEmpty) return (batch: null, problems: problems);
  return (
    batch: PlanBatch(id: id! as String, intent: (intent! as String).trim(), files: files, check: check),
    problems: const [],
  );
}

/// [json] (a list) as a plan's batches; ids must be unique. Any problem drops the list.
({List<PlanBatch> batches, List<String> problems}) parseBatches(Object? json) {
  if (json is! List) return (batches: const [], problems: const ['batches must be a list']);
  final batches = <PlanBatch>[];
  final problems = <String>[];
  final seen = <String>{};
  for (final (i, b) in json.indexed) {
    final r = parseBatch(b);
    problems.addAll(r.problems.map((p) => 'batch ${i + 1}: $p'));
    if (r.batch case final batch?) {
      if (!seen.add(batch.id)) problems.add('batch ${i + 1}: the id ${batch.id} is used twice');
      batches.add(batch);
    }
  }
  return problems.isEmpty ? (batches: batches, problems: const []) : (batches: const [], problems: problems);
}

/// [batches] as the fenced block a plan carries.
String batchesFence(List<PlanBatch> batches) =>
    '```json batches\n${const JsonEncoder.withIndent('  ').convert([for (final b in batches) b.toJson()])}\n```';

final _fence = RegExp(r'^```json batches[ \t]*\n([\s\S]*?)\n```', multiLine: true);

/// The batches in [markdown]'s ```json batches block; null without a valid one.
List<PlanBatch>? batchesInMarkdown(String markdown) {
  final m = _fence.firstMatch(markdown);
  if (m == null) return null;
  try {
    final r = parseBatches(jsonDecode(m[1]!));
    return r.problems.isEmpty ? r.batches : null;
  } on FormatException {
    return null;
  }
}
