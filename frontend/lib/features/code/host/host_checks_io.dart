// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../domain/plan_batches.dart';
import '../harness/everyai/repro_paths_io.dart';
import '../git/git_service_io.dart' show runGit;
import '../git/git_service.dart' show GitService;
import '../harness/everyai/lsp_io.dart';
import '../harness/everyai/shell_io.dart';
import 'host.dart';
import 'host_checks.dart';

/// The longest a check's command may run.
const _runLimit = Duration(minutes: 10);

/// Exit codes of a run stopped at a limit rather than finished.
const _killedExits = {124, 137, 143};

/// Runs [command]; [timed] tells [HostCheckContext.timed] how long it took.
Future<({int exit, String out})> _run(
  HostCheckContext c,
  String command,
  Future<void> cancel, {
  bool timed = true,
}) async {
  final clock = Stopwatch()..start();
  if (c.run case final run?) {
    var cancelled = false;
    unawaited(cancel.then((_) => cancelled = true, onError: (Object _) => cancelled = true));
    final r = await run(command, cancel);
    // Like the shell's: not a run that was stopped or killed at a limit (timeout's 124, SIGKILL, SIGTERM).
    if (timed && !cancelled && !_killedExits.contains(r.exit)) await c.timed?.call(command, clock.elapsed);
    return r;
  }
  final shell = SessionShell(root: c.workingDir, sessionTag: c.sessionId, scratchDir: '${c.stateDir}/shell');
  final r = await shell.run(command, timeout: _runLimit, cancel: cancel);
  if (timed && !r.timedOut && !r.cancelled) await c.timed?.call(command, clock.elapsed);
  final note = r.timedOut ? '\n[Stopped after ${_runLimit.inMinutes} minutes.]' : '';
  return (exit: r.exitCode, out: '${r.output}$note');
}

/// diff_stats for a session with no worktree of its own: what isn't committed yet in its folder (`git diff --stat
/// HEAD`, plus new files), since there is no session base to count from.
Future<HostResult> hostDiffStatsHere(HostCheckContext c, Future<void> cancel) async {
  const command = 'git diff --stat HEAD && git ls-files --others --exclude-standard';
  if (c.refusal(command) case final why?) return (text: '$why\n(command: $command)', isError: true);
  final r = c.run == null ? await _statsHere(c.workingDir) : await _run(c, command, cancel, timed: false);
  if (r.exit != 0) {
    return (
      text: 'This folder is not a git repository with a commit, so there is nothing to count from.',
      isError: false,
    );
  }
  final lines = r.out.trimRight().split('\n').where((l) => l.trim().isNotEmpty).toList();
  final stat = [
    for (final l in lines)
      if (l.contains('|') || l.contains('changed')) l,
  ];
  final added = [
    for (final l in lines)
      if (!l.contains('|') && !l.contains('changed')) l.trim(),
  ];
  if (stat.isEmpty && added.isEmpty) return (text: 'No uncommitted changes in the project folder.', isError: false);
  return (
    text: [
      'This session works in the project folder itself (no worktree of its own), so these are the changes not '
          'committed yet, against HEAD. They may include the user\'s own edits.',
      ...stat,
      if (added.isNotEmpty) 'New files: ${added.join(', ')}',
    ].join('\n'),
    isError: false,
  );
}

/// [hostDiffStatsHere]'s command as EveryAI's own git calls (nothing the repository defines runs).
Future<({int exit, String out})> _statsHere(String dir) async {
  try {
    final stat = await runGit(dir, ['diff', '--stat', 'HEAD']);
    if (stat.exitCode != 0) return (exit: stat.exitCode, out: '${stat.stderr}');
    final added = await runGit(dir, ['ls-files', '--others', '--exclude-standard']);
    return (exit: added.exitCode, out: '${stat.stdout}${added.stdout}');
  } on Object catch (e) {
    return (exit: 1, out: '$e');
  }
}

Future<HostResult> hostCheck(
  HostCheckContext c,
  List<String> files,
  Future<void> cancel, {
  bool full = false,
  String? testName,
}) async {
  final r = await _checks(
    c,
    files,
    cancel,
    full: full,
    testName: testName,
    refuse: (command) {
      final why = c.refusal(command);
      return why == null ? null : (why: why, skip: false);
    },
  );
  return (text: r.text, isError: r.outcome != BatchOutcome.passed);
}

/// The tests that cover [files] ([full]: their projects' whole suites; [testName]: the tests of that name), run in
/// [c]'s folder; each command passes [refuse] first. Unverified when no test was found to run at all.
Future<({String text, String notes, BatchOutcome outcome})> _checks(
  HostCheckContext c,
  List<String> files,
  Future<void> cancel, {
  required BatchRefusal? Function(String command) refuse,
  bool full = false,
  String? testName,
}) async {
  ({List<CheckRun> runs, List<String> unmatched}) detect({bool Function(String dir)? tracked}) => detectChecks(
    files,
    full: full,
    testName: testName,
    nodeModulesTracked: tracked,
    exists: (p) => FileSystemEntity.typeSync('${c.workingDir}/$p') != FileSystemEntityType.notFound,
    read: (p) {
      try {
        return File('${c.workingDir}/$p').readAsStringSync();
      } on Object {
        return null;
      }
    },
  );
  var found = detect();
  // Like the after-edit checks: a project whose node_modules git tracks runs none of its binaries.
  final nodeDirs = {
    for (final r in found.runs)
      if (r.command.startsWith('$checkNpx ')) r.dir,
  };
  final notes = <String>[];
  if (nodeDirs.isNotEmpty) {
    final tracked = <String>{};
    for (final d in nodeDirs) {
      final at = d.isEmpty ? c.workingDir : '${c.workingDir}/$d';
      switch (await _nodeModules(at)) {
        case null:
          tracked.add(d);
        case final untracked when untracked.isNotEmpty:
          // Not in git and not ignored: likely written in this session. Run, but named for the reader.
          final shown = [for (final p in untracked.take(8)) d.isEmpty ? p : '$d/$p'];
          notes.add(
            'Note: ${shown.join(', ')}${untracked.length > 8 ? ' and ${untracked.length - 8} more' : ''} '
            'under node_modules/.bin ${untracked.length == 1 ? 'is' : 'are'} not in git and not ignored, so '
            '${untracked.length == 1 ? 'it was' : 'they were'} probably written in this session; the test runner '
            'ran from there.',
          );
        default:
      }
    }
    if (tracked.isNotEmpty) found = detect(tracked: tracked.contains);
  }
  final missed = found.unmatched.isEmpty ? '' : 'No test found for: ${found.unmatched.join(', ')}.';
  if (found.runs.isEmpty) {
    return (
      text:
          '$missed Pass the test files themselves (they run as given), or run the right tests yourself. The app knows '
          'Dart/Flutter, jest, vitest, Go, Cargo and pytest projects.',
      notes: '',
      outcome: BatchOutcome.unverified,
    );
  }
  final out = <String>[];
  var failed = false;
  for (final run in found.runs) {
    final command = checkCommand(run);
    if (refuse(command) case final no?) {
      return (
        text: '${no.why}\n(command: $command)',
        notes: '',
        outcome: no.skip ? BatchOutcome.skipped : BatchOutcome.failed,
      );
    }
    final r = await _run(c, command, cancel);
    failed |= r.exit != 0;
    out.add('\$ $command\n[exit ${r.exit}]\n${r.out.trimRight()}');
  }
  return (
    text: [
      failed ? 'Some tests failed.' : 'The tests passed.',
      if (missed.isNotEmpty) missed,
      ...notes,
      ...out,
    ].join('\n\n'),
    notes: notes.join('\n'),
    outcome: failed ? BatchOutcome.failed : BatchOutcome.passed,
  );
}

/// The files under [dir]'s `node_modules/.bin` that git shows as untracked (not ignored); null when git tracks
/// node_modules there, or can't tell in a repository. Outside a repository nothing is tracked.
Future<List<String>?> _nodeModules(String dir) async {
  try {
    // Guarded: the repository's own programs (core.fsmonitor) don't run.
    final t = await runGit(dir, ['ls-files', '-z', '--', 'node_modules']);
    if (t.exitCode != 0) return '${t.stderr}'.contains('not a git repository') ? const [] : null;
    if ('${t.stdout}'.isNotEmpty) return null;
    final u = await runGit(dir, ['ls-files', '-z', '--others', '--exclude-standard', '--', 'node_modules/.bin']);
    return [
      for (final p in '${u.stdout}'.split('\x00'))
        if (p.isNotEmpty) p,
    ];
  } on Object {
    return null;
  }
}

Future<BatchVerdict> runBatchCheck(HostCheckContext c, PlanBatch batch, Future<void> cancel) async {
  BatchRefusal? refuse(String command, {required bool own}) {
    if (c.batchRefusal case final gate?) return gate(command, own: own);
    final why = c.refusal(command);
    return why == null ? null : (why: why, skip: false);
  }

  Future<({String text, String notes, BatchOutcome outcome})> own(List<String> files, {bool full = false}) =>
      _checks(c, files, cancel, full: full, refuse: (command) => refuse(command, own: true));
  final r = switch (batch.check) {
    null => (text: '', notes: '', outcome: BatchOutcome.passed),
    FilesCheck(:final files) => await own(files.isEmpty ? batch.files : files),
    FullCheck() => await own(batch.files, full: true),
    CommandCheck(:final command) => switch (refuse(command, own: false)) {
      final no? => (
        text: '${no.why}\n(command: $command)',
        notes: '',
        outcome: no.skip ? BatchOutcome.skipped : BatchOutcome.failed,
      ),
      null => await _run(c, command, cancel).then(
        (r) => (
          text: '\$ $command\n[exit ${r.exit}]\n${r.out.trimRight()}',
          notes: '',
          outcome: r.exit == 0 ? BatchOutcome.passed : BatchOutcome.failed,
        ),
      ),
    },
  };
  return (outcome: r.outcome, output: r.outcome == BatchOutcome.passed ? r.notes : _tail(r.text));
}

String _tail(String out) => out.length > 3000 ? '…${out.substring(out.length - 3000)}' : out;

/// [paths] under [dir] with their digests (a gone file has none).
Map<String, String> _digests(String dir, Iterable<String> paths) => {
  for (final p in paths)
    if (File('$dir/$p').existsSync()) p: '${sha256.convert(File('$dir/$p').readAsBytesSync())}',
};

/// The bug_check state in [stateDir], or null when there is none (nothing reproduced yet).
Future<Map<String, Object?>?> readBugCheckState(String stateDir) async {
  try {
    return jsonDecode(await File('$stateDir/bug_check.json').readAsString()) as Map<String, Object?>;
  } on Object {
    return null;
  }
}

/// Starts [stateDir]'s bug_check from an earlier agent's [record] (see [bugCheckRecord]): the same repro, not
/// verified yet. Only the repro files [workingDir] has count: a git-excluded one (a `.everyai/scratch/` script)
/// stayed in the checkout it was written in, and its absence there isn't a change.
Future<void> writeBugCheckState(String stateDir, Map<String, Object?> record, {required String workingDir}) async {
  final file = File('$stateDir/bug_check.json');
  await file.parent.create(recursive: true);
  final files = record['files'] is Map ? (record['files']! as Map).cast<String, Object?>() : const <String, Object?>{};
  await file.writeAsString(
    jsonEncode({
      'command': record['command'] ?? '',
      'expect': record['expect'] ?? '',
      'files': {
        for (final e in files.entries)
          if (File('$workingDir/${e.key}').existsSync()) e.key: e.value,
      },
      'verified': false,
    }),
  );
}

Future<HostResult> hostBugCheck(HostCheckContext c, Map<String, Object?> args, Future<void> cancel) async {
  final file = File('${c.stateDir}/bug_check.json');
  Map<String, Object?> state;
  try {
    state = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  } on Object {
    state = {};
  }
  void save() {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(state));
  }

  final recorded = state['command'] as String? ?? '';
  final marker = state['expect'] as String? ?? '';
  switch (args['action']) {
    case 'reproduced':
      final command = (args['command'] as String? ?? '').trim();
      final expect = (args['expect'] as String? ?? '').trim();
      if (command.isEmpty) return (text: 'Error: give the command that shows the bug.', isError: true);
      if (c.refusal(command) case final why?) return (text: why, isError: true);
      final r = await _run(c, command, cancel);
      final shown = expect.isNotEmpty ? r.out.contains(expect) : r.exit != 0;
      if (!shown) {
        return (
          text:
              'Not reproduced: the app ran it and ${expect.isNotEmpty ? 'the output lacks "$expect"' : 'it exited 0'}. '
              'Find a command that really shows the bug, or ask the user how to reproduce it.\n${_tail(r.out)}',
          isError: true,
        );
      }
      final snapshot = await reproPaths(c.workingDir, command, output: r.out);
      state = {'command': command, 'expect': expect, 'files': _digests(c.workingDir, snapshot), 'verified': false};
      save();
      return (
        text:
            'Reproduced: the app ran it and saw the bug${expect.isEmpty ? ' (it failed; make sure it fails on this '
                      'bug, not on a build or setup error)' : ''}. Fix it, then call bug_check verify.\n'
            '${_tail(r.out)}',
        isError: false,
      );
    case 'verify':
      if (recorded.isEmpty) {
        return (text: 'Error: call bug_check reproduced first, with the command that shows the bug.', isError: true);
      }
      final before = (state['files'] as Map<String, Object?>? ?? const {}).cast<String, Object?>();
      final now = _digests(c.workingDir, before.keys);
      final changed = [
        for (final p in before.keys)
          if (now[p] != before[p]) p,
      ];
      if (changed.isNotEmpty) {
        return (
          text:
              'Not verified: the fix changed what reproduces the bug (${changed.take(8).join(', ')}). The original '
              'repro has to pass unchanged. Restore those files; if the test itself was wrong, ask the user, then '
              'call bug_check reproduced again with the corrected command.',
          isError: true,
        );
      }
      if (c.refusal(recorded) case final why?) return (text: why, isError: true);
      final r = await _run(c, recorded, cancel);
      final gone = marker.isNotEmpty ? !r.out.contains(marker) : r.exit == 0;
      if (!gone) {
        return (
          text:
              'Not verified: ${marker.isNotEmpty ? 'the output still shows "$marker"' : 'the command still fails '
                        '(exit ${r.exit})'}. If it now fails on something else, say what and why.\n${_tail(r.out)}',
          isError: true,
        );
      }
      state['verified'] = true;
      save();
      return (text: 'Verified: the app ran the repro again and the bug is gone.\n${_tail(r.out)}', isError: false);
    case 'status':
      if (recorded.isEmpty) return (text: 'Nothing recorded yet: start with bug_check reproduced.', isError: false);
      return (
        text: [
          'Repro command: $recorded',
          if (marker.isNotEmpty) 'Shows the bug when the output has: $marker',
          state['verified'] == true ? 'Verified: the fix passed.' : 'Not verified yet.',
        ].join('\n'),
        isError: false,
      );
    default:
      return (text: 'Error: action must be reproduced, verify or status.', isError: true);
  }
}

/// One language-server hub per session folder for outside leads' diagnostics calls; each stops after 10 minutes
/// without a call.
final _hubs = <String, ({LspHub hub, Timer idle})>{};

Future<HostResult> hostDiagnostics(HostCheckContext c, String path) async {
  final root = c.workingDir;
  final was = _hubs.remove(root);
  was?.idle.cancel();
  final hub =
      was?.hub ??
      LspHub(
        root: root,
        toolsDir: '${await GitService.dataDir()}/tools',
        environment: () async => (await ShellEnv.load()).env,
      );
  _hubs[root] = (
    hub: hub,
    idle: Timer(const Duration(minutes: 10), () {
      if (_hubs.remove(root) case final h?) unawaited(h.hub.close());
    }),
  );
  final a = await diagnosticsAnswer(hub, root, path);
  return (text: a.text, isError: a.isError);
}
