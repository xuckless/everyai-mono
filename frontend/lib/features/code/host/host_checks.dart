// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import '../domain/agent_mode.dart';
import '../domain/goal.dart';
import '../domain/permissions.dart';
import '../domain/phases.dart' show bugCheckTool;
import '../domain/plan_batches.dart';
import '../drivers/briefing/session_skill.dart' show HostToolInfo;
import '../drivers/driver_policy.dart' show hostToolOf;
import '../git/git_service.dart';
import '../harness/events.dart';
import 'host.dart';
import 'host_checks_stub.dart' if (dart.library.io) 'host_checks_io.dart' as impl;
import 'host_script.dart';

export 'host_checks_stub.dart' if (dart.library.io) 'host_checks_io.dart' show readBugCheckState, writeBugCheckState;

// Checks for an outside agent that cost EveryAI nothing: no model call, only
// what the app can run or read itself. bug_check and check run a command in
// the app (outside the agent's sandbox), so each run passes [hostRunRefusal]
// first; diff_stats and goal_check only read.

const checkTool = 'check';
const diffStatsTool = 'diff_stats';
const goalCheckTool = 'goal_check';

/// What a workflow script reads of an agent's bug_check: `{available:
/// true, state, command, expect, files}` from its [saved] state (null:
/// nothing reproduced), state one of verified, reproduced, not_reproduced;
/// or `{available: false, why}` when the agent had no host ([hostless]).
Map<String, Object?> bugCheckRecord(Map<String, Object?>? saved, {String? hostless}) {
  if (hostless != null) return {'available': false, 'why': hostless};
  final command = saved?['command'] as String? ?? '';
  return {
    'available': true,
    'state': command.isEmpty
        ? 'not_reproduced'
        : saved?['verified'] == true
        ? 'verified'
        : 'reproduced',
    'command': command,
    'expect': saved?['expect'] as String? ?? '',
    'files': saved?['files'] is Map ? saved!['files'] : const <String, Object?>{},
  };
}

/// What a workflow script reads of a batch check ([runBatchCheck]'s verdict): `{passed: true}`, `{passed: false,
/// output}`, `{skipped: true, output}` when the session's mode would have asked before the command (the app can't ask
/// the user from a gate), or `{skipped: true, unverified: true, output}` when no test covers the batch's files. A
/// skipped check doesn't gate: the work merges unchecked, as it would with no check, and nothing is spent on fixing
/// a check that can't pass. The safety floor or a deny rule refusing the command is a failed check.
Map<String, Object?> batchCheckRecord(BatchVerdict v) => switch (v.outcome) {
  // A note (a test runner the agent may have written) still reaches the reader.
  BatchOutcome.passed => {'passed': true, if (v.output.isNotEmpty) 'note': v.output},
  BatchOutcome.failed => {'passed': false, 'output': v.output},
  BatchOutcome.skipped => {'skipped': true, 'output': v.output},
  BatchOutcome.unverified => {'skipped': true, 'unverified': true, 'output': v.output},
};

/// How a batch check ended (see [batchCheckRecord]).
enum BatchOutcome { passed, failed, skipped, unverified }

/// A batch check's outcome: [output] is the tail of what ran (or why it couldn't); when it passed, only its notes
/// ('' for none).
typedef BatchVerdict = ({BatchOutcome outcome, String output});

/// Why the app won't run a batch check's command: [skip] when only the mode stands in the way (it would ask), so
/// the check is skipped; otherwise (the safety floor, a deny rule) the check fails with [why].
typedef BatchRefusal = ({String why, bool skip});

/// Why the app won't run [command] for a batch check now, or null. [own]: a command EveryAI built itself from the
/// project ([detectChecks]: the tests that cover the batch's files, or the whole suite); otherwise the plan's own
/// `check.command`, which a model wrote.
/// - The safety floor and the user's deny rules refuse in every mode, Bypass included. Bypass turns EveryAI's checks
///   off for the agent's own calls; a batch check is the app running a command itself, outside the agent's tools,
///   so the app's guardrails stay on for it.
/// - Plan mode runs no checks (skipped).
/// - The app's own test commands run in every other mode without asking (the user's decision: they are the
///   project's tests, chosen by the app, not by the model).
/// - A model-written command is treated like the agent's own command: the mode decides, and where it would ask the
///   check is skipped (nobody can approve it from a gate).
BatchRefusal? batchRunRefusal({
  required PermissionPolicy policy,
  required AgentMode mode,
  required String command,
  required bool own,
}) {
  if (floorReason(command) case final why?) return (why: 'Not run: $why. EveryAI never runs this.', skip: false);
  // Bypass skips the floor and the rules in the policy, so they are asked as in Full auto.
  final guard = _probe(policy, mode == AgentMode.bypass ? AgentMode.fullAuto : mode, checkTool, command);
  if (guard.source == DecisionSource.rule) return (why: _denial(guard), skip: false);
  if (mode == AgentMode.plan) return (why: 'Not run: Plan mode runs no checks.', skip: true);
  if (own || mode == AgentMode.bypass) return null;
  return switch (guard.verdict) {
    Verdict.allow => null,
    Verdict.deny => (why: _denial(guard), skip: false),
    Verdict.ask => (
      why:
          'Not run: the session asks before this command, and the app runs a batch check without asking. Allow '
          'the command with a rule, or use Full auto, to have it gate the merge.',
      skip: true,
    ),
  };
}

/// Runs [batch]'s check in [c]'s folder (the batch agent's worktree) and returns the verdict: the one entry point
/// for gating a batch's merge (workflow agents and Max forks). Each command passes
/// [HostCheckContext.batchRefusal] first (see [batchRunRefusal]). A batch without a check passes; one with no test
/// to run is unverified, not failed.
Future<BatchVerdict> runBatchCheck(HostCheckContext c, PlanBatch batch, Future<void> cancel) =>
    impl.runBatchCheck(c, batch, cancel);

/// The host's own bug_check: the deterministic steps of Bug fix mode's
/// (no triage, no review by another model), which a workflow sequences.
const hostBugCheckSpec = <String, Object?>{
  'name': bugCheckTool,
  'description':
      'Prove a bug and its fix with a check the app runs itself, not on your word. Actions:\n'
      '- reproduced: give the command that shows the bug (a failing test, a script under .everyai/scratch/). The app '
      'runs it in the project: it must fail (non-zero exit), or print `expect` when you give it. Pass `expect` when '
      'the command could also fail for another reason (a build error). The app remembers the command and the files '
      'it names.\n'
      '- verify: after the fix, the app runs the same command again. It passes when `expect` is gone from the output '
      '(or, without one, when it exits 0). It refuses when a file the command names changed since reproduced: the '
      'repro has to pass as it was, not edited into passing.\n'
      '- status: what is recorded so far.',
  'inputSchema': {
    'type': 'object',
    'properties': {
      'action': {
        'type': 'string',
        'enum': ['reproduced', 'verify', 'status'],
      },
      'command': {'type': 'string', 'description': 'reproduced: the command that shows the bug'},
      'expect': {'type': 'string', 'description': 'reproduced: optional text in the output that shows the bug'},
    },
    'required': ['action'],
    'additionalProperties': false,
  },
  // It runs the agent's command, so a client must not auto-allow it as harmless.
  'annotations': {'readOnlyHint': false, 'destructiveHint': true},
};

const checkSpec = <String, Object?>{
  'name': checkTool,
  'description':
      'Run the tests that cover the files you changed, and only those. The app finds each file\'s project '
      '(pubspec.yaml, package.json with jest or vitest, go.mod, Cargo.toml, pyproject.toml or pytest), maps source '
      'files to their tests and runs them there. Without files it takes what this session changed. Long output is '
      'saved to a file and you get a preview. Use it after a change, before you say it works.\n'
      'scope: changed (what this session changed), files (the files you name; the default when you name some), '
      'test (the tests whose name matches `test`, in the projects of the files or of the session folder) or full '
      '(the whole suite of those projects; use it once at the end, not after every change).',
  'inputSchema': {
    'type': 'object',
    'properties': {
      'scope': {
        'type': 'string',
        'enum': ['changed', 'files', 'test', 'full'],
        'description': 'What to run; default: files when you name some, else changed',
      },
      'files': {
        'type': 'array',
        'items': {'type': 'string'},
        'description': 'Paths relative to the session folder; tests or the source files they cover',
      },
      'test': {'type': 'string', 'description': 'scope test: the test name (or part of it) to run'},
    },
    'additionalProperties': false,
  },
  // It runs the project's tests, which are its own code.
  'annotations': {'readOnlyHint': false, 'destructiveHint': true},
};

const diffStatsSpec = <String, Object?>{
  'name': diffStatsTool,
  'description':
      'The files this session changed since it started, with lines added and removed per file and in total, '
      'untracked files included. Cheaper than reading the whole diff when you only need its size or the file list.',
  'inputSchema': {'type': 'object', 'properties': <String, Object?>{}, 'additionalProperties': false},
  'annotations': {'readOnlyHint': true, 'destructiveHint': false},
};

const goalCheckSpec = <String, Object?>{
  'name': goalCheckTool,
  'description':
      'The goal the user set for this session (/goal), with the rules for judging whether it is met. Call it '
      'before you say the goal is done, and have the judgement made as the result says.',
  'inputSchema': {'type': 'object', 'properties': <String, Object?>{}, 'additionalProperties': false},
  'annotations': {'readOnlyHint': true, 'destructiveHint': false},
};

/// What the briefing tells an outside agent about these tools, in
/// `hostToolSpecs` order (run_script is left out where it isn't listed).
const checkToolInfos = <HostToolInfo>[
  (
    name: bugCheckTool,
    when:
        'you fix a bug: record the command that shows it (reproduced), then prove the fix with the same command '
        '(verify). The app runs both itself.',
  ),
  (name: checkTool, when: 'you changed code: it runs only the tests that cover the changed files.'),
  (name: diffStatsTool, when: 'you need what this session changed so far, file by file, without the whole diff.'),
  (
    name: goalCheckTool,
    when:
        'the user set a goal: before you say it is met. Have it judged by a sub-agent on another model if you can '
        'start one.',
  ),
  (
    name: runScriptTool,
    when:
        'you would read or grep more than about five files just to filter them: a TypeScript program does it and '
        'prints only what you need.',
  ),
];

/// Runs [command] in the session folder until it ends or [cancel]
/// completes; tests pass a fake.
typedef HostRun = Future<({int exit, String out})> Function(String command, Future<void> cancel);

/// What the check tools see of a session.
final class HostCheckContext {
  const HostCheckContext({
    required this.sessionId,
    required this.workingDir,
    required this.stateDir,
    required this.refusal,
    this.batchRefusal,
    this.worktree,
    this.goal,
    this.run,
    this.timed,
  });

  final String sessionId;
  final String workingDir;

  /// The session's own folder outside the project (bug_check's state, script runs).
  final String stateDir;

  /// The session's own worktree and base commit; null when it works in the project folder.
  final SessionWorktree? worktree;
  final Goal? goal;

  /// Why the app won't run a command for this call now, or null (see [hostRunRefusal]).
  final String? Function(String command) refusal;

  /// Why the app won't run a batch check's command (see [batchRunRefusal]); null: [refusal] decides, and any refusal
  /// fails the check.
  final BatchRefusal? Function(String command, {required bool own})? batchRefusal;

  /// The command runner; null runs in the user's login shell.
  final HostRun? run;

  /// Told how long each check or bug_check command ran (not one that timed out or was cancelled); the run's
  /// result waits for it.
  final Future<void> Function(String command, Duration took)? timed;
}

/// Answers a check tool call ([checkToolNames]).
Future<HostResult> hostCheckTool(HostCall call, HostCheckContext c) async {
  switch (call.name) {
    case diffStatsTool:
      final w = c.worktree;
      // No worktree of its own: the uncommitted changes in the folder it works in.
      if (w == null) return impl.hostDiffStatsHere(c, call.ended);
      return hostDiffStats(w, await GitService.changes(w));
    case goalCheckTool:
      return hostGoalCheck(c.goal);
    case runScriptTool:
      return hostRunScript(c.workingDir, c.stateDir, call.args, cancel: call.ended);
    case checkTool:
      // Outside agents often pass absolute paths; the detector works on relative ones.
      final root = '${c.workingDir}/';
      final named = [
        for (final f in (call.args['files'] as List<Object?>? ?? const []).whereType<String>())
          f.startsWith(root) ? f.substring(root.length) : f,
      ];
      final scope = call.args['scope'] is String
          ? call.args['scope']! as String
          : (named.isEmpty ? 'changed' : 'files');
      final test = call.args['test'] is String ? (call.args['test']! as String).trim() : '';
      if (!const {'changed', 'files', 'test', 'full'}.contains(scope)) {
        return (text: 'Error: scope must be changed, files, test or full.', isError: true);
      }
      if (scope == 'test' && test.isEmpty) {
        return (text: 'Error: scope test needs the test\'s name in `test`.', isError: true);
      }
      if (scope == 'files' && named.isEmpty) {
        return (text: 'Error: name the files to check (paths relative to the session folder).', isError: true);
      }
      var files = scope == 'changed' ? const <String>[] : named;
      final w = c.worktree;
      if (files.isEmpty && scope != 'files' && w != null) files = [for (final f in await GitService.changes(w)) f.path];
      // A name or the whole suite needs only the projects: the session folder's own when nothing narrows it.
      if (files.isEmpty && (scope == 'test' || scope == 'full')) files = const ['.'];
      if (files.isEmpty) {
        return (
          text:
              'Error: this session changed nothing the app can see; name the files to check (paths relative to the '
              'session folder).',
          isError: true,
        );
      }
      return impl.hostCheck(c, files, call.ended, full: scope == 'full', testName: scope == 'test' ? test : null);
    case bugCheckTool:
      return impl.hostBugCheck(c, call.args, call.ended);
    default:
      return (text: 'Error: there is no EveryAI check called ${call.name}.', isError: true);
  }
}

/// The tools [hostCheckTool] answers.
const checkToolNames = {bugCheckTool, checkTool, diffStatsTool, goalCheckTool, runScriptTool};

/// diff_stats' answer for [changes] since [w]'s base commit.
HostResult hostDiffStats(SessionWorktree? w, List<FileChange>? changes) {
  if (w == null || changes == null) {
    return (
      text:
          'This session works in the project folder itself, not in a worktree of its own, so the app has no base to '
          'count from. Use git diff --stat.',
      isError: false,
    );
  }
  final base = w.baseCommit.length > 7 ? w.baseCommit.substring(0, 7) : w.baseCommit;
  if (changes.isEmpty) return (text: 'No changes since the session started (base $base).', isError: false);
  final added = changes.fold(0, (n, c) => n + c.added), removed = changes.fold(0, (n, c) => n + c.removed);
  return (
    text: [
      '${changes.length} file${changes.length == 1 ? '' : 's'} changed, +$added -$removed since the session started '
          '(base $base):',
      for (final f in changes) '${f.kind.letter} ${f.path} +${f.added} -${f.removed}',
    ].join('\n'),
    isError: false,
  );
}

/// goal_check's answer: the goal and how to judge it. No model is asked; the
/// lead judges, ideally through a sub-agent on another model.
HostResult hostGoalCheck(Goal? goal) {
  if (goal == null) return (text: 'No goal is set for this session. The user sets one with /goal.', isError: false);
  return (
    text:
        'Goal: ${goal.objective.trim()}\n\n'
        'To judge it, start a sub-agent (on another model if your harness can pick one) with the prompt below, '
        'plus the diff (diff_stats) and the test results. If you can\'t start one, check it yourself against the '
        'same rules before you say the goal is met; if it isn\'t, keep working on what is missing.\n\n'
        '${goalSelfCheck(goal.objective)}',
    isError: false,
  );
}

/// Why the app won't run [command] for host tool [tool] (called with
/// [args]), or null. The host token is in the agent's environment, so any
/// process it starts could call the host; the app runs the command outside
/// the agent's sandbox, so the call needs the session's own permission:
/// - the safety floor and the user's deny rules always refuse;
/// - an allow (a rule, Full auto) runs it;
/// - an ask runs only for a call the session approved: one of [approved]
///   (the agent's own rows of this tool that the user or the session's
///   rules allowed) with the same arguments. That one is used up, so one
///   approval runs one call.
String? hostRunRefusal({
  required PermissionPolicy policy,
  required AgentMode mode,
  required String tool,
  required Map<String, Object?> args,
  required String command,
  required List<ActionCall> approved,
}) {
  final d = _probe(policy, mode, tool, command);
  switch (d.verdict) {
    case Verdict.allow:
      return null;
    case Verdict.deny:
      return _denial(d);
    case Verdict.ask:
      final i = approved.indexWhere(
        (c) => hostToolOf(c) == tool && args.entries.every((e) => jsonEncode(c.action[e.key]) == jsonEncode(e.value)),
      );
      if (i >= 0) {
        approved.removeAt(i);
        return null;
      }
      return 'Not run: this command needs the user\'s approval, and no approved $tool call of yours with these '
          'arguments is in the session. Call $tool through your MCP client so the user can approve it.';
  }
}

/// Why the session's permissions refuse [command] for host tool [tool]
/// outright (the safety floor, a deny rule, Plan mode), or null when they
/// allow it or would ask (the caller's own card is the approval then).
String? hostRunDenial({
  required PermissionPolicy policy,
  required AgentMode mode,
  required String tool,
  required String command,
}) {
  final d = _probe(policy, mode, tool, command);
  return d.verdict == Verdict.deny ? _denial(d) : null;
}

/// [policy]'s decision on [command] as if the agent ran it in a shell.
Decision _probe(PermissionPolicy policy, AgentMode mode, String tool, String command) => policy.decide(
  ActionCall(
    id: 'host-$tool',
    raw: const {},
    toolName: 'bash',
    toolCallId: '',
    action: {'kind': 'TerminalAction', 'command': command},
  ),
  mode,
);

String _denial(Decision d) => switch (d.source) {
  DecisionSource.floor => 'Not run: ${d.why}. EveryAI never runs this for an agent.',
  DecisionSource.rule => 'Not run: the user\'s rule ${d.rule} refuses it.',
  DecisionSource.plan => 'Not run: Plan mode runs no commands that may change things.',
  _ => 'Not run: the session\'s permissions refuse it.',
};

/// A test command and the project folder (relative, '' for the session
/// folder) it runs in.
typedef CheckRun = ({String dir, String command});

/// The test commands that cover [files] (relative to the session folder),
/// one per project they are in, and the files no test was found for.
/// [exists] and [read] see paths relative to the session folder. [full]:
/// each project's whole suite instead (the bare test command). [testName]:
/// the tests whose name matches it, in each project (its runner's filter).
/// File arguments come after `--` where the runner takes it, and a path that
/// starts with `-` gets `./`, so no file name reads as an option; a very long
/// list is split over several runs. jest and vitest run through `npx --no-install` (the project's own install,
/// nothing downloaded); a project whose node_modules git tracks ([nodeModulesTracked]) gets none: its binaries are
/// repository code, not installed tools.
({List<CheckRun> runs, List<String> unmatched}) detectChecks(
  List<String> files, {
  required bool Function(String path) exists,
  required String? Function(String path) read,
  bool full = false,
  String? testName,
  bool Function(String dir)? nodeModulesTracked,
}) {
  const markers = ['pubspec.yaml', 'package.json', 'go.mod', 'Cargo.toml', 'pyproject.toml', 'pytest.ini', 'setup.py'];
  String join(String dir, String name) => dir.isEmpty ? name : '$dir/$name';
  final groups = <(String, String), List<String>>{};
  final unmatched = <String>[];
  for (final raw in files) {
    final file = raw == '.' ? '' : (raw.startsWith('./') ? raw.substring(2) : raw);
    (String, String)? hit;
    for (var dir = _parent(file); hit == null; dir = _parent(dir)) {
      for (final m in markers) {
        if (exists(join(dir, m))) {
          hit = (dir, m);
          break;
        }
      }
      if (dir.isEmpty) break;
    }
    if (hit == null) {
      unmatched.add('$raw (no project file such as pubspec.yaml, package.json or go.mod in its folder or above)');
    } else {
      (groups[hit] ??= []).add(hit.$1.isEmpty ? file : file.substring(hit.$1.length + 1));
    }
  }
  final runs = <CheckRun>[];
  for (final MapEntry(key: (dir, marker), value: inside) in groups.entries) {
    final dart = RegExp(r'sdk:\s*flutter').hasMatch(read(join(dir, marker)) ?? '') ? 'flutter test' : 'dart test';
    final js = marker == 'package.json'
        ? switch (read(join(dir, marker)) ?? '') {
            final p when p.contains('"vitest"') => 'vitest',
            final p when p.contains('"jest"') => 'jest',
            _ => null,
          }
        : null;
    // The project's runner is unknown (a package.json with neither jest nor vitest): no test can be run there.
    if (marker == 'package.json' && js == null) {
      unmatched.addAll([for (final f in inside) '${join(dir, f)} (its package.json names neither jest nor vitest)']);
      continue;
    }
    if (marker == 'package.json' && (nodeModulesTracked?.call(dir) ?? false)) {
      unmatched.addAll([
        for (final f in inside) '${join(dir, f)} (node_modules is in git, so EveryAI does not run its binaries)',
      ]);
      continue;
    }
    if (testName != null) {
      final q = _quote(testName);
      runs.add((
        dir: dir,
        command: switch (marker) {
          'pubspec.yaml' => '$dart --plain-name=$q',
          'package.json' =>
            js == 'vitest' ? '$checkNpx vitest run --testNamePattern=$q' : '$checkNpx jest --testNamePattern=$q',
          'go.mod' => 'go test -run=$q ./...',
          'Cargo.toml' => 'cargo test -- $q',
          _ => 'python -m pytest -k $q',
        },
      ));
      continue;
    }
    if (full) {
      runs.add((
        dir: dir,
        command: switch (marker) {
          'pubspec.yaml' => dart,
          'package.json' => js == 'vitest' ? '$checkNpx vitest run' : '$checkNpx jest',
          'go.mod' => 'go test ./...',
          'Cargo.toml' => 'cargo test',
          _ => 'python -m pytest',
        },
      ));
      continue;
    }
    final tests = <String>{};
    for (final f in inside) {
      final found = switch (marker) {
        'pubspec.yaml' when f.endsWith('_test.dart') => f,
        'pubspec.yaml' when f.startsWith('lib/') && f.endsWith('.dart') => _ifExists(
          'test/${f.substring(4, f.length - 5)}_test.dart',
          dir,
          exists,
        ),
        'package.json' when RegExp(r'\.[cm]?[jt]sx?$').hasMatch(f) => f,
        'go.mod' when f.endsWith('.go') => _parent(f).isEmpty ? '.' : './${_parent(f)}',
        'Cargo.toml' when f.endsWith('.rs') => '',
        _ when f.endsWith('.py') && RegExp(r'(^|/)test_[^/]*\.py$|_test\.py$').hasMatch(f) => f,
        _ when f.endsWith('.py') =>
          _ifExists(join(_parent(f), 'test_${_base(f)}'), dir, exists) ??
              _ifExists('tests/test_${_base(f)}', dir, exists),
        _ => null,
      };
      if (found == null) {
        // Say where the test was looked for, so the agent can pass the right file.
        final looked = switch (marker) {
          'pubspec.yaml' when f.startsWith('lib/') && f.endsWith('.dart') =>
            ' (looked for ${join(dir, 'test/${f.substring(4, f.length - 5)}_test.dart')})',
          _ when f.endsWith('.py') =>
            ' (looked for ${join(dir, join(_parent(f), 'test_${_base(f)}'))} and ${join(dir, 'tests/test_${_base(f)}')})',
          'pubspec.yaml' => ' (only lib/ files map to tests under test/)',
          _ => '',
        };
        unmatched.add('${join(dir, f)}$looked');
      } else {
        tests.add(found);
      }
    }
    if (tests.isEmpty) continue;
    final (tool, dashes) = switch (marker) {
      'pubspec.yaml' => (dart, true),
      'package.json' =>
        js == 'vitest' ? ('$checkNpx vitest related --run', false) : ('$checkNpx jest --findRelatedTests', false),
      'go.mod' => ('go test', false),
      'Cargo.toml' => ('cargo test', false),
      _ => ('python -m pytest', true),
    };
    final args = [
      for (final t in tests)
        if (t.isNotEmpty) _quote(t.startsWith('-') ? './$t' : t),
    ];
    if (args.isEmpty) {
      runs.add((dir: dir, command: tool));
      continue;
    }
    // Under the shell's argument limit (ARG_MAX is 256 KiB on macOS, less with a big environment).
    var chunk = <String>[];
    var size = 0;
    void flush() {
      if (chunk.isEmpty) return;
      runs.add((dir: dir, command: '$tool${dashes ? ' --' : ''} ${chunk.join(' ')}'));
      chunk = [];
      size = 0;
    }

    for (final a in args) {
      if (size + a.length + 1 > _argLimit) flush();
      chunk.add(a);
      size += a.length + 1;
    }
    flush();
  }
  return (runs: runs, unmatched: unmatched);
}

/// How a check runs the project's jest or vitest: from its node_modules only, never downloaded.
const checkNpx = 'npx --no-install';

/// The most characters of file arguments one check command carries.
const _argLimit = 32 * 1024;

String? _ifExists(String path, String dir, bool Function(String) exists) =>
    exists(dir.isEmpty ? path : '$dir/$path') ? path : null;

String _parent(String path) => path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';

String _base(String path) => path.substring(path.lastIndexOf('/') + 1);

String _quote(String s) => RegExp(r'^[\w./@+-]+$').hasMatch(s) ? s : "'${s.replaceAll("'", r"'\''")}'";

/// [run] as one shell command from the session folder.
String checkCommand(CheckRun run) => run.dir.isEmpty ? run.command : 'cd ${_quote(run.dir)} && ${run.command}';
