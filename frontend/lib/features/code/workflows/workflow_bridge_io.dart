// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../core/process/supervisor.dart';
import '../drivers/short_run.dart' show stopChecked;
import '../harness/everyai/script_io.dart' show findDeno;
import 'workflow_bridge.dart';
import 'workflow_prelude.dart';

// The Deno process and its line protocol, as ScriptRunner.run runs them
// (same flags, no permissions, an empty environment, one shared cache). TODO: make ScriptRunner use this bridge once run_script's own
// changes have landed, so there is one copy.

/// One printed line's most characters (a log row, not a file).
const _maxLine = 4000;

Future<WorkflowBridge> startWorkflowBridge({
  required String dir,
  required String source,
  required Map<String, Object?> args,
  String? sessionId,
}) async {
  final deno = findDeno() ?? (throw StateError('Workflows need Deno, which this install of the app is missing.'));
  final runDir = Directory(dir)..createSync(recursive: true);
  File('${runDir.path}/main.js').writeAsStringSync(workflowModule(source));
  File('${runDir.path}/prelude.js').writeAsStringSync(workflowPrelude(args));
  final process = await ProcessSupervisor.instance.spawn(
    SpawnSpec(
      // Its session's: Stop all and the session's delete end it (a plain Stop leaves it, by its label).
      owner: sessionId == null || sessionId.isEmpty ? const AppOwner() : SessionOwner(sessionId),
      kind: ProcessKind.script,
      exe: deno,
      args: const [
        'run',
        '--no-prompt',
        '--no-config',
        '--no-lock',
        '--no-remote',
        '--no-npm',
        '--quiet',
        'prelude.js',
      ],
      cwd: runDir.path,
      includeParentEnvironment: false,
      // `workflows/cache`, next to the session folders.
      env: {'DENO_DIR': '${runDir.parent.parent.path}/cache', 'DENO_NO_UPDATE_CHECK': '1', 'NO_COLOR': '1'},
      label: workflowScriptLabel,
      detail: runDir.path,
    ),
  );
  return _DenoBridge(process, runDir);
}

/// The owner of a workflow script run in [runDir]: the session the folder names (`…/workflows/<session>/<run>`), or
/// the app when the folder isn't laid out that way.
ProcessOwner workflowOwnerOf(String runDir) {
  final parts = runDir.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty).toList();
  return parts.length >= 3 && parts[parts.length - 3] == 'workflows'
      ? SessionOwner(parts[parts.length - 2])
      : const AppOwner();
}

final class _DenoBridge implements WorkflowBridge {
  _DenoBridge(this._process, Directory runDir) {
    // Writes after the script ended fail; nothing waits on them.
    unawaited(_process.stdin.done.catchError((_) {}));
    String clip(String l) => l.length > _maxLine ? '${l.substring(0, _maxLine)}…' : l;
    final out = _process.stdout.transform(utf8.decoder).transform(const LineSplitter()).forEach((line) {
      if (line.startsWith('\x1e')) {
        try {
          if (jsonDecode(line.substring(1)) case final Map<String, Object?> req) return _requests.add(req);
        } on FormatException {
          // Printed output after all.
        }
      }
      _output.add(clip(line));
    });
    final err = _process.stderr.transform(utf8.decoder).transform(const LineSplitter()).forEach((l) {
      _output.add(clip(l));
    });
    exit = _process.exitCode.then((code) async {
      await Future.wait([out, err]);
      unawaited(_process.stdin.close().catchError((_) {}));
      await _requests.close();
      await _output.close();
      // Its files were only for this run; the journal is kept apart.
      await runDir.delete(recursive: true).catchError((Object _) => runDir);
      return code;
    });
  }

  final SupervisedProcess _process;
  final _requests = StreamController<Map<String, Object?>>();
  final _output = StreamController<String>();

  /// The stop, once asked ([kill]).
  Future<KillOutcome>? _stopping;

  /// Replies may still go to it: not stopped, and its process hasn't been seen to end.
  bool get _open => _stopping == null && _process.state.live;

  @override
  Stream<Map<String, Object?>> get requests => _requests.stream;
  @override
  Stream<String> get output => _output.stream;
  @override
  late final Future<int> exit;

  @override
  void reply(Object? id, {Object? result, String? error}) {
    if (!_open) return;
    try {
      _process.stdin.writeln(jsonEncode({'id': id, if (error != null) 'error': error else 'result': result}));
    } on Object {
      // The script already ended.
    }
  }

  /// Stops the script and what it started (the supervisor's verified stop; the outcome is in the log when it isn't
  /// proven, and in [stop]).
  @override
  void kill() => unawaited(stop());

  @override
  Future<KillOutcome> stop() => _stopping ??= stopChecked(_process.spec.label, _process.stop);
}

Future<String> readJournalFile(String path) async {
  final f = File(path);
  return await f.exists() ? f.readAsString() : '';
}

Future<void> appendJournalFile(String path, String line) async {
  final f = File(path);
  await f.parent.create(recursive: true);
  await f.writeAsString('$line\n', mode: FileMode.append, flush: true);
}

Future<List<String>> listJournalFiles(String dir) async {
  final d = Directory(dir);
  if (!await d.exists()) return const [];
  final files = await d
      .list()
      .where((e) => e is File && e.path.endsWith('.jsonl') && !e.path.endsWith('.done.jsonl'))
      .map((e) => e.path)
      .toList();
  return files..sort();
}

Future<void> retireJournalFile(String path) async {
  final f = File(path);
  if (await f.exists()) await f.rename(path.replaceFirst(RegExp(r'\.jsonl$'), '.done.jsonl'));
}
