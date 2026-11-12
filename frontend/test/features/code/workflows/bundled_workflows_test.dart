import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/code/domain/plan_batches.dart';
import 'package:every_ai/features/code/harness/everyai/script_io.dart' show findDeno;
import 'package:every_ai/features/code/workflows/workflow_bridge.dart';
import 'package:every_ai/features/code/workflows/workflow_engine.dart';
import 'package:every_ai/features/code/workflows/workflow_journal.dart';
import 'package:every_ai/features/code/workflows/workflow_meta.dart';
import 'package:every_ai/features/code/workflows/workflow_prelude.dart' show workflowCtxKey;
import 'package:flutter_test/flutter_test.dart';

// The bundled workflow files in a real Deno, against a launcher whose
// agents answer by label. Skipped without Deno (set DENO_BIN, or
// tool/fetch_deno.sh).

/// Agents that answer with [answers] by label prefix, as a fenced json block.
final class _Agents implements AgentLauncher {
  _Agents(this.answers, {this.bugChecks = const {}, this.batchChecks = const {}});
  final Map<String, Object? Function(WorkflowAgentCall call)> answers;

  /// The app's bug_check record by label prefix; verified when none matches.
  final Map<String, Map<String, Object?>> bugChecks;

  /// The batch check's verdict by label prefix; passed when none matches.
  final Map<String, Map<String, Object?>> batchChecks;
  final calls = <WorkflowAgentCall>[];
  final _byChild = <String, WorkflowAgentCall>{};

  WorkflowAgentCall byLabel(String label) => calls.firstWhere((c) => c.label == label);
  List<String> get labels => [for (final c in calls) c.label];

  @override
  Future<WorkflowChild> start(WorkflowAgentCall call) async {
    calls.add(call);
    final id = 'c${calls.length}';
    _byChild[id] = call;
    return (childId: id, harness: call.harness ?? 'lead', model: call.model ?? 'lead-model', note: null);
  }

  @override
  Future<WorkflowAgentResult> watch(String childId, {bool reattached = false}) async {
    final call = _byChild[childId]!;
    final answer = answers.entries.where((e) => call.label.startsWith(e.key)).firstOrNull?.value;
    if (answer == null) return (text: '', error: 'no answer for ${call.label}', spentMicros: null);
    final v = answer(call);
    // null: this agent fails.
    if (v == null) return (text: '', error: '${call.label} failed', spentMicros: null);
    return (text: v is String ? v : 'Done.\n```json\n${jsonEncode(v)}\n```', error: null, spentMicros: null);
  }

  @override
  Future<WorkflowAgentResult> followUp(String childId, String text) => watch(childId);

  @override
  Future<String?> finish(String childId, {required bool ok}) async =>
      ok ? null : 'Not merged into your folder; its work is kept at refs/everyai/forks/$childId.';

  @override
  Future<Map<String, Object?>> batchCheckOf(String childId, PlanBatch batch) async {
    final label = _byChild[childId]!.label;
    return batchChecks.entries.where((e) => label.startsWith(e.key)).firstOrNull?.value ?? {'passed': true};
  }

  @override
  Future<Map<String, Object?>> bugCheckOf(String childId) async {
    final label = _byChild[childId]!.label;
    return bugChecks.entries.where((e) => label.startsWith(e.key)).firstOrNull?.value ??
        {'available': true, 'state': 'verified', 'command': 'dart test test/repro_test.dart'};
  }

  @override
  void stop(String childId) {}

  @override
  Future<void> release(String childId) async {}

  @override
  Future<void> pause(String childId) async {}

  @override
  Future<void> resume(String childId) async {}
  @override
  DateTime? lastActivity(String childId) => null;
  @override
  Future<void> restart(String childId, String note) async {}
  @override
  Future<bool> message(String childId, String text) async => true;
}

String _source(String id) => File('assets/workflows/$id.js').readAsStringSync();

Map<String, Object?> _review(String verdict, [List<Map<String, Object?>> findings = const []]) => {
  'findings': findings,
  'verdict': verdict,
};

const _finding = {
  'severity': 'major',
  'file': 'lib/a.dart',
  'summary': 'drops the last item',
  'failure_scenario': 'a list of one',
  'suggested_fix': 'use <=',
};

void main() {
  final deno = findDeno();
  final skip = deno == null ? 'no deno (set DENO_BIN)' : false;
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('bundled-workflows'));
  tearDown(() => dir.delete(recursive: true));

  Future<WorkflowRun> run(String id, Map<String, Object?> args, _Agents agents, {Map<String, Object?>? ctx}) async {
    final bridge = await startWorkflowBridge(
      dir: '${dir.path}/s/run',
      source: _source(id),
      args: {...args, workflowCtxKey: ?ctx},
    );
    return WorkflowEngine(
      runId: 'r',
      name: id,
      bridge: bridge,
      launcher: agents,
      journal: WorkflowJournal.fresh((_) async {}),
    ).run();
  }

  test('each bundled file has a readable meta with its id, title, phases and args', () {
    for (final (id, title) in [('ultra', 'Ultra'), ('bugfix', 'Bug fix'), ('security_review', 'Security review')]) {
      final meta = parseWorkflowMeta(_source(id))!;
      expect(meta.id, id);
      expect(meta.name, title);
      expect(meta.description, isNotEmpty);
      expect(meta.whenToUse, isNotEmpty);
      expect(meta.args, startsWith('{'));
      expect(meta.phases, isNotEmpty);
    }
  });

  group('ultra', () {
    Map<String, Object? Function(WorkflowAgentCall)> answers({String verdict = 'fix-then-ship'}) => {
      'research:': (c) => {
        'note_path': '.everyai/workflows/runs/x/${c.label.split(':').last}.md',
        'plan': 'step 1',
        'simplicity': 'fine',
        'risks': <String>[],
        'tests': ['a_test'],
        'scope_change': '',
      },
      'impl:': (c) => {
        'commits': ['abc ${c.label}'],
        'summary': 'did it',
        'tests': 'pass',
        'deviations': '',
        'status': 'done',
      },
      'review:a:correctness': (_) => _review(verdict, verdict == 'ship' ? const [] : const [_finding]),
      'review:': (_) => _review('ship'),
      'refix:': (_) => {
        'fixed': ['drops the last item'],
        'rejected': <Object>[],
        'commits': ['def refix'],
        'tests': 'pass',
      },
      'fix-check:': (_) => {
        'fixed': ['the failing test'],
        'rejected': <Object>[],
        'commits': ['fed fix-check'],
        'tests': 'pass',
      },
      'integrate': (_) => 'All 12 tests pass.',
    };

    test('research, implement in worktrees, two reviews, refix, then one integration', () async {
      final agents = _Agents(answers());
      final end = await run(
        'ultra',
        {
          'items': [
            {'id': 'a', 'title': 'A', 'spec': 'Build A'},
            {'id': 'b', 'title': 'B', 'spec': 'Build B'},
          ],
        },
        agents,
        ctx: {
          'runId': 'run-1',
          'review': {'harness': 'everyai', 'model': 'openai/gpt-6.1'},
        },
      );
      expect(end.error, isNull);
      expect(end.status, WorkflowStatus.done);
      // Review and Refix come from the agents' own phases.
      expect(end.phases, ['Research', 'Implement', 'Review', 'Refix', 'Integrate']);
      expect(agents.labels.where((l) => l.startsWith('research:')), ['research:a', 'research:b']);
      expect(agents.labels.last, 'integrate');
      expect(agents.labels, containsAll(['review:a:correctness', 'review:a:cost-simplicity', 'refix:a']));
      expect(agents.labels, isNot(contains('refix:b')));
      // Research and review are read-only and stay in the session's folder; writers get worktrees.
      for (final c in agents.calls) {
        expect(c.worktree, c.label.startsWith('impl:') || c.label.startsWith('refix:'), reason: c.label);
      }
      expect(agents.byLabel('research:a').prompt, contains('read-only'));
      expect(agents.byLabel('research:a').prompt, contains('.everyai/workflows/runs/run-1/a.md'));
      expect(agents.byLabel('review:a:correctness').prompt, contains('read-only'));
      // Reviews run on the review model the app picked.
      expect(agents.byLabel('review:b:correctness').model, 'openai/gpt-6.1');
      expect(agents.byLabel('review:b:correctness').harness, 'everyai');
      expect(agents.byLabel('impl:a').model, isNull);
      final result = end.result! as Map;
      final items = (result['items'] as List).cast<Map<String, Object?>>();
      expect([for (final i in items) i['id']], ['a', 'b']);
      expect(items.first['commits'], ['abc impl:a', 'def refix']);
      expect(items.last['refix'], isNull);
      expect(result['integration'], 'All 12 tests pass.');
      expect(result['reviewed_on'], 'openai/gpt-6.1');
    }, skip: skip);

    test('an item with a check is one batch: a failed gate refixes from the kept ref, then reviews', () async {
      final agents = _Agents(
        answers(),
        batchChecks: {
          'impl:a': {'passed': false, 'output': 'Expected: 2 Actual: 1'},
        },
      );
      final end = await run('ultra', {
        'items': [
          {
            'id': 'a',
            'title': 'A',
            'spec': 'Build A',
            'files': ['lib/a.dart'],
            'check': {
              'files': ['test/a_test.dart'],
            },
          },
          {'id': 'b', 'spec': 'Build B'},
        ],
      }, agents);
      expect(end.error, isNull);
      final impl = agents.byLabel('impl:a');
      expect(impl.batch!.toJson(), {
        'id': 'a',
        'intent': 'A',
        'files': ['lib/a.dart'],
        'check': {
          'files': ['test/a_test.dart'],
        },
      });
      expect(agents.byLabel('impl:b').batch, isNull);
      // Nothing merged, so the check's fix comes before the reviews.
      final fix = agents.byLabel('fix-check:a');
      expect(agents.labels.indexOf('fix-check:a'), lessThan(agents.labels.indexOf('review:a:correctness')));
      expect(fix.prompt, contains('Expected: 2 Actual: 1'));
      final implChild = 'c${agents.calls.indexOf(impl) + 1}';
      expect(fix.prompt, contains('git merge refs/everyai/forks/$implChild'));
      expect(fix.batch!.id, 'a');
      expect(fix.worktree, isTrue);
      // Once it merged, the item is reviewed on all of its commits, and the review's refix is gated too.
      expect(agents.byLabel('review:a:correctness').prompt, contains('abc impl:a; fed fix-check'));
      expect(agents.byLabel('refix:a').batch!.id, 'a');
      final items = ((end.result! as Map)['items'] as List).cast<Map<String, Object?>>();
      expect(items.first['status'], 'done');
      expect(items.first['commits'], ['abc impl:a', 'fed fix-check', 'def refix']);
      expect(items.first['findings'], hasLength(1));
      expect((items.first['check_fix'] as Map)['fixed'], ['the failing test']);
    }, skip: skip);

    test('a plan_ref reaches only the agents in the session folder; others read only this run\'s notes', () async {
      const plan = '.everyai/plans/2026-11-05-x.md';
      // saved_plans lists bare names and savePlan returns absolute paths: each means the same file.
      for (final given in [plan, '2026-11-05-x.md', '/Users/x/proj/.everyai/plans/2026-11-05-x.md']) {
        final agents = _Agents({
          ...answers(),
          'split': (_) => {
            'items': [
              {'id': 'a', 'title': 'A', 'spec': 'Build A'},
            ],
          },
        });
        final end = await run('ultra', {'task': 'Build A', 'plan_ref': given}, agents, ctx: {'runId': 'run-1'});
        expect(end.status, WorkflowStatus.done, reason: given);
        for (final c in agents.calls) {
          final inFolder = c.label == 'split' || c.label.startsWith('research:');
          expect(
            c.prompt.contains('The plan the user picked for this work: $plan '),
            inFolder,
            reason: '$given ${c.label}',
          );
          expect(c.prompt, contains('Read no saved plan in .everyai/plans/'), reason: c.label);
          expect(c.prompt, contains('.everyai/workflows/runs/run-1'), reason: c.label);
        }
        expect(agents.byLabel('research:a').prompt, contains('Copy into the note what this item needs from the plan'));
      }
    }, skip: skip);

    test('missing items fail with a readable error', () async {
      final end = await run('ultra', {}, _Agents({}));
      expect(end.status, WorkflowStatus.failed);
      expect(end.error, contains('ultra needs args {items'));
      expect(end.error, contains('{task}'));
    }, skip: skip);
  });

  group('bugfix', () {
    Map<String, Object?> fix(String label) => {
      'repro_command': 'dart test test/a_test.dart',
      'cause': 'off by one',
      'fix_summary': 'uses <=',
      'verified': true,
      'files': ['lib/a.dart'],
      'commits': ['f00 $label'],
    };

    test('the fixer proves with bug_check, the review reruns its repro, a refix starts from its record', () async {
      const record = {
        'available': true,
        'state': 'verified',
        'command': 'dart test test/repro_test.dart',
        'expect': '',
        'files': {'test/repro_test.dart': 'abc'},
      };
      final agents = _Agents(
        {
          'fix': (c) => fix(c.label),
          'review': (_) => _review('fix-then-ship', const [_finding]),
          'refix': (c) => fix(c.label),
        },
        bugChecks: {'fix': record},
      );
      final end = await run(
        'bugfix',
        {'bug': 'The last item is missing'},
        agents,
        ctx: {
          'review': {'harness': 'everyai', 'model': 'google/gemini-3.5-pro'},
        },
      );
      expect(end.error, isNull);
      expect(agents.labels, ['fix', 'review', 'refix']);
      expect(end.phases, ['Fix', 'Review', 'Refix']);
      final fixer = agents.byLabel('fix');
      expect(fixer.worktree, isTrue);
      expect(fixer.bugCheck, isEmpty);
      expect(fixer.prompt, contains('The last item is missing'));
      for (final step in ['bug_check', '"reproduced"', '"verify"', 'grep', 'glob', 'Never guess a path', 'check']) {
        expect(fixer.prompt, contains(step));
      }
      // The review and refix rerun the repro in other checkouts, which have no git-ignored scratch files.
      expect(fixer.prompt, contains('not depend on files git ignores'));
      final review = agents.byLabel('review');
      expect(review.worktree, isFalse);
      expect(review.bugCheck, isNull);
      expect(review.prompt, contains('read-only'));
      expect(review.model, 'google/gemini-3.5-pro');
      // The app's record of the repro, not the agent's own repro_command.
      expect(review.prompt, contains('dart test test/repro_test.dart'));
      final refix = agents.byLabel('refix');
      expect(refix.worktree, isTrue);
      expect(refix.bugCheck, record);
      expect(refix.prompt, contains('bug_check'));
      final result = end.result! as Map;
      expect(result['verified'], isTrue);
      expect(result['commits'], ['f00 fix', 'f00 refix']);
      expect((result['review'] as Map)['verdict'], 'fix-then-ship');
      expect(result['proof'], 'bug_check');
      expect(result['bug_check'], {'state': 'verified', 'command': 'dart test test/repro_test.dart'});
      expect(result['repro_command'], 'dart test test/repro_test.dart');
    }, skip: skip);
  });

  group('security_review', () {
    Map<String, Object?> finding(String category, String summary) => {
      'severity': 'high',
      'file': 'lib/net.dart',
      'category': category,
      'summary': summary,
      'exploit': 'send a crafted URL',
      'fix': 'check the host',
    };

    test('a threat model, four read-only lenses, then only the verified findings come back', () async {
      final agents = _Agents({
        'threat-model': (_) => {
          'summary': 'adds a fetch tool',
          'entry_points': ['the url argument'],
          'boundaries': ['model to network'],
          'assets': <String>[],
          'files': ['lib/net.dart'],
        },
        'lens:data': (_) => {
          'findings': [finding('ssrf', 'fetches loopback addresses'), finding('dos', 'no size limit')],
        },
        'lens:': (_) => {'findings': <Object>[]},
        'verify': (_) => {
          'findings': [finding('ssrf', 'fetches loopback addresses')],
          'dropped': [
            {'summary': 'no size limit', 'reason': 'the client caps responses at 4 MB'},
          ],
        },
      });
      final end = await run('security_review', {'base': 'main'}, agents);
      expect(end.error, isNull);
      expect(end.phases, ['Threat model', 'Lenses', 'Verify']);
      expect(agents.labels.first, 'threat-model');
      expect(agents.labels.sublist(1, 5).toSet(), {'lens:secrets', 'lens:injection', 'lens:access', 'lens:data'});
      expect(agents.labels.last, 'verify');
      for (final c in agents.calls) {
        expect(c.worktree, isFalse, reason: c.label);
        expect(c.readOnly, isTrue, reason: c.label);
        expect(c.prompt, contains('You are read-only'), reason: c.label);
        expect(c.prompt, contains('git diff main...HEAD'), reason: c.label);
      }
      expect(agents.byLabel('lens:access').prompt, contains('adds a fetch tool'));
      expect(agents.byLabel('verify').prompt, contains('no size limit'));
      final result = end.result! as Map;
      expect([for (final f in result['findings'] as List) (f as Map)['summary']], ['fetches loopback addresses']);
      expect((result['dropped'] as List).single, containsPair('summary', 'no size limit'));
      expect(result['verified'], isTrue);
    }, skip: skip);

    test('the same finding from two lenses reaches the verifier once, naming both', () async {
      final agents = _Agents({
        'threat-model': (_) => {
          'summary': 's',
          'entry_points': <String>[],
          'boundaries': <String>[],
          'assets': <String>[],
          'files': ['lib/net.dart'],
        },
        'lens:data': (_) => {
          'findings': [finding('ssrf', 'fetches loopback addresses')],
        },
        'lens:injection': (_) => {
          'findings': [finding('ssrf', 'fetches the loopback addresses')],
        },
        'lens:': (_) => {'findings': <Object>[]},
        'verify': (_) => {'findings': <Object>[], 'dropped': <Object>[]},
      });
      final end = await run('security_review', {'base': 'main'}, agents);
      expect(end.error, isNull);
      final prompt = agents.byLabel('verify').prompt;
      expect('"exploit"'.allMatches(prompt), hasLength(1));
      expect(prompt, contains('"injection"'));
      expect(prompt, contains('"data"'));
    }, skip: skip);
  });
}
