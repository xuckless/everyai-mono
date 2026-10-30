import 'dart:async';
import 'dart:convert';

import 'package:every_ai/features/code/ultra/domain/ultra_engine.dart';
import 'package:every_ai/features/code/ultra/domain/ultra_journal.dart';
import 'package:every_ai/features/code/ultra/domain/ultra_plan.dart';
import 'package:every_ai/features/code/ultra/domain/ultra_prompts.dart';
import 'package:flutter_test/flutter_test.dart';

/// What a fake child answers: its final message and what it cost.
typedef Answer = ({String text, int cost, ChildEnd end});

Answer ok(String text, {int cost = 1000}) => (text: text, cost: cost, end: ChildEnd.completed);

final class FakeChild implements UltraChild {
  FakeChild(this.id, this.request, this.runner);

  @override
  final String id;
  final UltraChildRequest request;
  final FakeRunner runner;
  final _done = Completer<ChildResult>();
  bool stopped = false;

  @override
  int costMicros = 0;

  @override
  Future<ChildResult> get result => _done.future;

  void answer(Answer a) {
    costMicros += a.cost;
    if (!_done.isCompleted) _done.complete(ChildResult(a.end, a.text));
  }

  @override
  Future<ChildResult> followUp(String message) async {
    runner.followUps.add((id: id, message: message));
    final a = runner.onFollowUp!(request, message);
    costMicros += a.cost;
    return ChildResult(a.end, a.text);
  }

  @override
  Future<void> stop() async {
    stopped = true;
    if (!_done.isCompleted) _done.complete(const ChildResult(ChildEnd.stopped, 'stopped'));
  }
}

final class FakeRunner implements UltraChildRunner {
  FakeRunner(this.answers, {this.delay = const Duration(milliseconds: 2), this.manual = false});

  /// Answers by request; called when the child starts.
  final Answer Function(UltraChildRequest r) answers;
  Answer Function(UltraChildRequest r, String message)? onFollowUp;
  final Duration delay;

  /// Children wait for the test to answer them.
  final bool manual;
  final started = <FakeChild>[];
  final abandoned = <String>[];
  final followUps = <({String id, String message})>[];
  int running = 0;
  int peak = 0;

  @override
  Future<UltraChild> start(UltraChildRequest request) async {
    final child = FakeChild('child-${started.length + 1}', request, this);
    started.add(child);
    running++;
    if (running > peak) peak = running;
    unawaited(child.result.whenComplete(() => running--));
    if (!manual) {
      unawaited(Future<void>.delayed(delay, () => child.answer(answers(request))));
    }
    return child;
  }

  @override
  Future<void> abandon(String childId) async => abandoned.add(childId);

  List<UltraChildRequest> byRole(ChildRole role) => [
    for (final c in started)
      if (c.request.role == role) c.request,
  ];
}

final class FakeWallet implements UltraWallet {
  FakeWallet({this.planId = 'max', this.available = 100000000});
  String planId;
  int available;
  int reads = 0;

  @override
  Future<WalletReading> read() async {
    reads++;
    return WalletReading(planId: planId, availableMicros: available);
  }
}

final class FakeWorkspace implements UltraWorkspace {
  FakeWorkspace({this.isolates = true, this.conflicts = const {}});

  @override
  final bool isolates;
  final Set<String> conflicts;
  final created = <String>[];
  final merged = <String>[];

  @override
  Future<StepWorktree> create(String runId, String key) async {
    created.add(key);
    return StepWorktree(path: '/wt/$runId/$key', branch: 'everyai/ultra-$key');
  }

  @override
  Future<MergeOutcome> merge(StepWorktree w, String message) async {
    if (conflicts.any(w.branch.contains)) {
      return MergeOutcome(merged: false, branch: w.branch, detail: 'conflict in lib/a.dart');
    }
    merged.add(w.branch);
    return MergeOutcome(merged: true, branch: w.branch);
  }
}

final class MemoryStore implements UltraJournalStore {
  final saved = <String, String>{};
  int saves = 0;

  @override
  Future<void> save(UltraJournal journal) async {
    saves++;
    saved[journal.runId] = jsonEncode(journal.toJson());
  }

  @override
  Future<UltraJournal?> load(String runId) async =>
      saved[runId] == null ? null : UltraJournal.fromJson(jsonDecode(saved[runId]!) as Map<String, Object?>);
}

const _criticDone = '```json\n{"complete": true, "notes": "all there", "gaps": []}\n```';

Answer _default(UltraChildRequest r) => switch (r.role) {
  ChildRole.critic => ok(_criticDone),
  ChildRole.verify => ok('```json\n{"pass": true, "issues": []}\n```'),
  ChildRole.step => ok('did ${r.key}'),
};

UltraPlan _plan(Map<String, Object?> json, {bool allowWrites = true}) {
  final p = parseUltraPlan(json, allowWrites: allowWrites);
  expect(p.errors, isEmpty);
  return p.plan!;
}

UltraJournal _journal(UltraPlan plan, {UltraLimits limits = const UltraLimits()}) =>
    UltraJournal(runId: 'run1', sessionId: 's1', plan: plan, limits: limits, createdAt: DateTime(2026, 10, 30));

UltraEngine _engine(
  UltraJournal j,
  FakeRunner runner, {
  FakeWallet? wallet,
  FakeWorkspace? workspace,
  MemoryStore? store,
  DateTime Function()? clock,
  bool allowWrites = true,
}) => UltraEngine(
  journal: j,
  runner: runner,
  wallet: wallet ?? FakeWallet(),
  workspace: workspace ?? FakeWorkspace(),
  store: store ?? MemoryStore(),
  clock: clock,
  allowWrites: allowWrites,
  checkEvery: const Duration(milliseconds: 1),
);

void main() {
  group('parseUltraPlan', () {
    test('reads a plan, resolves model aliases and accepts a JSON string', () {
      final p = parseUltraPlan(
        jsonEncode({
          'plan': {
            'goal': 'Ship it',
            'phases': [
              {
                'id': 'explore',
                'for_each': ['a', 'b'],
                'steps': [
                  {'id': 'look', 'title': 'Look', 'prompt': 'Look at {{item}}', 'model': 'haiku'},
                ],
              },
              {
                'id': 'build',
                'mode': 'pipeline',
                'steps': [
                  {
                    'id': 'write',
                    'prompt': 'Write',
                    'writes': true,
                    'inputs': ['explore'],
                  },
                  {
                    'id': 'test',
                    'prompt': 'Test',
                    'inputs': ['build.write', 'explore.look'],
                    'verify': 'Tests pass',
                  },
                ],
              },
            ],
          },
        }),
      );
      expect(p.errors, isEmpty);
      final plan = p.plan!;
      expect(plan.phases.first.steps.single.model, 'anthropic/claude-haiku-5.5');
      expect(plan.phases.last.fanOut, FanOut.pipeline);
      expect(plan.phases.last.steps.last.verify!.prompt, 'Tests pass');
      // 2 looks, write, test + its verifier.
      expect(plan.minimumAgents, 5);
      expect(plan.writes, isTrue);
    });

    test('says what is wrong', () {
      final p = parseUltraPlan({
        'goal': '',
        'phases': [
          {
            'id': 'Bad Id',
            'steps': [
              {
                'id': 'x',
                'prompt': '',
                'writes': true,
                'inputs': ['later'],
                'effort': 'huge',
                'model': 'gpt 5',
              },
              {'id': 'x', 'prompt': 'p'},
            ],
          },
        ],
      }, allowWrites: false);
      expect(p.plan, isNull);
      final all = p.errors.join('\n');
      for (final bit in ['goal', 'phases[0].id', 'prompt', 'Plan mode', '"later"', 'effort', 'model', 'used twice']) {
        expect(all, contains(bit));
      }
    });

    test('refuses a plan past the agent cap', () {
      final p = parseUltraPlan({
        'goal': 'g',
        'phases': [
          {
            'id': 'p',
            'for_each': [for (var i = 0; i < 10; i++) '$i'],
            'steps': [
              {'id': 's', 'prompt': 'p', 'verify': 'ok'},
            ],
          },
        ],
      }, limits: const UltraLimits(maxAgents: 15));
      expect(p.errors.single, contains('at least 21 agents'));
    });

    test('a pipeline step may read an earlier stage of its own phase only', () {
      final bad = parseUltraPlan({
        'goal': 'g',
        'phases': [
          {
            'id': 'p',
            'steps': [
              {'id': 'a', 'prompt': 'x'},
              {
                'id': 'b',
                'prompt': 'x',
                'inputs': ['p.a'],
              },
            ],
          },
        ],
      });
      expect(bad.errors.single, contains('"p.a"'));
    });
  });

  group('results', () {
    test('structuredResult takes the last json block, or the whole message', () {
      expect(structuredResult('a\n```json\n{"x":1}\n```\nb\n```json\n{"x":2}\n```').value, {'x': 2});
      expect(structuredResult('{"y": true}').value, {'y': true});
      expect(structuredResult('no json').found, isFalse);
    });

    test('checkSchema checks types, required keys, enums and items', () {
      const schema = {
        'type': 'object',
        'required': ['a', 'b'],
        'properties': {
          'a': {'type': 'integer'},
          'b': {
            'type': 'array',
            'items': {
              'type': 'string',
              'enum': ['x', 'y'],
            },
          },
        },
      };
      expect(
        checkSchema({
          'a': 1,
          'b': ['x'],
        }, schema),
        isEmpty,
      );
      expect(
        checkSchema({
          'a': 'no',
          'b': ['z'],
        }, schema),
        hasLength(2),
      );
      expect(checkSchema({'a': 1}, schema).single, contains(r'$.b: missing'));
      expect(checkSchema([], schema).single, contains('expected object'));
    });
  });

  group('UltraEngine', () {
    test('runs phases in order under the concurrency cap and hands results on', () async {
      final runner = FakeRunner(_default);
      final store = MemoryStore();
      final plan = _plan({
        'goal': 'Survey',
        'phases': [
          {
            'id': 'scan',
            'for_each': [for (var i = 0; i < 7; i++) 'dir$i'],
            'steps': [
              {'id': 'read', 'prompt': 'Read {{item}}'},
            ],
          },
          {
            'id': 'sum',
            'steps': [
              {
                'id': 'all',
                'prompt': 'Summarize',
                'inputs': ['scan'],
              },
            ],
          },
        ],
      });
      final j = await _engine(_journal(plan, limits: const UltraLimits(maxConcurrent: 3)), runner, store: store).run();
      expect(j.status, UltraRunStatus.done);
      expect(runner.peak, lessThanOrEqualTo(3));
      expect(runner.byRole(ChildRole.step), hasLength(8));
      expect(runner.byRole(ChildRole.critic), hasLength(1));
      expect(j.agentsStarted, 9);
      expect(runner.started.first.request.brief, contains('Read dir0'));
      final summary = runner.byRole(ChildRole.step).last.brief;
      for (var i = 0; i < 7; i++) {
        expect(summary, contains('did scan.read[$i]'));
      }
      expect(j.complete, isTrue);
      expect(j.spentMicros, 9000);
      final report = ultraReport(j);
      expect(report, contains('finished'));
      expect(report, contains('did sum.all'));
      // The journal on disk reads back the same.
      final back = (await store.load('run1'))!;
      expect(back.status, UltraRunStatus.done);
      expect(back.steps['scan.read[3]']!.output, 'did scan.read[3]');
    });

    test('a pipeline passes each stage on, per item, and stops an item at a failure', () async {
      final runner = FakeRunner(
        (r) => r.key == 'p.b[1]' ? (text: 'boom', cost: 10, end: ChildEnd.failed) : _default(r),
      );
      final plan = _plan({
        'goal': 'g',
        'phases': [
          {
            'id': 'p',
            'mode': 'pipeline',
            'for_each': ['x', 'y'],
            'steps': [
              {'id': 'a', 'prompt': 'A {{item}}'},
              {'id': 'b', 'prompt': 'B'},
              {'id': 'c', 'prompt': 'C'},
            ],
          },
        ],
      });
      final j = await _engine(_journal(plan), runner).run();
      final briefs = {for (final r in runner.byRole(ChildRole.step)) r.key: r.brief};
      expect(briefs['p.b[0]'], contains('did p.a[0]'));
      expect(briefs['p.b[0]'], isNot(contains('did p.a[1]')));
      expect(briefs['p.c[0]'], contains('did p.b[0]'));
      expect(j.steps['p.b[1]']!.status, StepStatus.failed);
      expect(j.steps['p.c[1]']!.status, StepStatus.skipped);
      expect(briefs.containsKey('p.c[1]'), isFalse);
      expect(j.steps['p.c[0]']!.status, StepStatus.done);
    });

    test('writing steps get worktrees that are merged back, or left as branches', () async {
      final runner = FakeRunner(_default);
      final ws = FakeWorkspace(conflicts: {'p.two'});
      final plan = _plan({
        'goal': 'g',
        'phases': [
          {
            'id': 'p',
            'steps': [
              {'id': 'one', 'prompt': 'x', 'writes': true},
              {'id': 'two', 'prompt': 'x', 'writes': true},
              {'id': 'look', 'prompt': 'x'},
            ],
          },
        ],
      });
      final j = await _engine(_journal(plan), runner, workspace: ws).run();
      expect(ws.created, unorderedEquals(['p.one', 'p.two']));
      expect(ws.merged, ['everyai/ultra-p.one']);
      final byKey = {for (final r in runner.byRole(ChildRole.step)) r.key: r};
      expect(byKey['p.one']!.workingDir, '/wt/run1/p.one');
      expect(byKey['p.one']!.writes, isTrue);
      expect(byKey['p.look']!.workingDir, isNull);
      expect(byKey['p.look']!.writes, isFalse);
      expect(j.steps['p.two']!.merge!.merged, isFalse);
      expect(ultraReport(j), contains('Branches left for the user: everyai/ultra-p.two'));
    });

    test('without git, writers take turns in the session folder', () async {
      final runner = FakeRunner(_default);
      final plan = _plan({
        'goal': 'g',
        'phases': [
          {
            'id': 'p',
            'steps': [
              for (final id in ['a', 'b', 'c']) {'id': id, 'prompt': 'x', 'writes': true},
            ],
          },
        ],
      });
      await _engine(_journal(plan), runner, workspace: FakeWorkspace(isolates: false)).run();
      expect(runner.peak, 1);
      expect(runner.byRole(ChildRole.step).every((r) => r.workingDir == null && r.writes), isTrue);
    });

    test('a failed check reruns the step once with the issues', () async {
      var checks = 0;
      final runner = FakeRunner(
        (r) => r.role == ChildRole.verify && checks++ == 0
            ? ok('```json\n{"pass": false, "issues": ["lib/a.dart:3 off by one"]}\n```')
            : _default(r),
      );
      final plan = _plan({
        'goal': 'g',
        'phases': [
          {
            'id': 'p',
            'steps': [
              {'id': 's', 'prompt': 'x', 'writes': true, 'verify': 'tests pass'},
            ],
          },
        ],
      });
      final j = await _engine(_journal(plan), runner).run();
      final steps = runner.byRole(ChildRole.step);
      expect(steps, hasLength(2));
      expect(steps.last.brief, contains('off by one'));
      // The rerun builds on the same worktree; the check runs there too.
      expect(steps.last.workingDir, steps.first.workingDir);
      expect(runner.byRole(ChildRole.verify).first.workingDir, steps.first.workingDir);
      expect(j.steps['p.s']!.verified, isTrue);
      expect(j.steps['p.s']!.childIds, hasLength(4));
    });

    test('asks once more for a result that misses its schema', () async {
      final runner = FakeRunner((r) => r.role == ChildRole.step ? ok('here you go') : _default(r))
        ..onFollowUp = (r, m) => ok('```json\n{"files": ["a"]}\n```', cost: 5);
      final plan = _plan({
        'goal': 'g',
        'phases': [
          {
            'id': 'p',
            'steps': [
              {
                'id': 's',
                'prompt': 'x',
                'result_schema': {
                  'type': 'object',
                  'required': ['files'],
                },
              },
            ],
          },
        ],
      });
      final j = await _engine(_journal(plan), runner).run();
      expect(runner.followUps.single.message, contains('no ```json block'));
      expect(j.steps['p.s']!.structured, {
        'files': ['a'],
      });
      expect(j.steps['p.s']!.result, contains('"files"'));
      expect(j.steps['p.s']!.costMicros, 1005);
    });

    test('stops at the dollar cap and skips what is left', () async {
      final runner = FakeRunner((r) => r.role == ChildRole.step ? ok('x', cost: 4000000) : _default(r));
      final plan = _plan({
        'goal': 'g',
        'phases': [
          for (final p in ['a', 'b', 'c', 'd'])
            {
              'id': p,
              'steps': [
                {'id': 's', 'prompt': 'x'},
              ],
            },
        ],
      });
      final j = await _engine(_journal(plan, limits: const UltraLimits(budgetMicros: 10000000)), runner).run();
      expect(j.status, UltraRunStatus.capped);
      expect(j.steps['a.s']!.status, StepStatus.done);
      expect(j.steps['b.s']!.status, StepStatus.done);
      // The third would not fit an average child.
      expect(runner.byRole(ChildRole.step), hasLength(2));
      expect(j.steps['c.s']!.status, StepStatus.skipped);
      expect(runner.byRole(ChildRole.critic), isEmpty);
    });

    test('the wallet lowers the budget at the start', () async {
      final runner = FakeRunner(_default);
      final plan = _plan({
        'goal': 'g',
        'phases': [
          {
            'id': 'a',
            'steps': [
              {'id': 's', 'prompt': 'x'},
            ],
          },
        ],
      });
      final j = await _engine(_journal(plan), runner, wallet: FakeWallet(available: 3000000)).run();
      expect(j.budgetMicros, 3000000);
    });

    test('a running child over the cap is stopped', () async {
      final runner = FakeRunner(_default, manual: true);
      final plan = _plan({
        'goal': 'g',
        'phases': [
          {
            'id': 'a',
            'steps': [
              {'id': 's', 'prompt': 'x'},
              {'id': 't', 'prompt': 'x'},
            ],
          },
        ],
      });
      final done = _engine(_journal(plan, limits: const UltraLimits(budgetMicros: 1000)), runner).run();
      await pumpUntil(() => runner.started.length == 2);
      runner.started.first.costMicros = 2000;
      final j = await done;
      expect(j.status, UltraRunStatus.capped);
      expect(runner.started.every((c) => c.stopped), isTrue);
      expect(j.steps['a.s']!.status, StepStatus.stopped);
      expect(j.spentMicros, 2000);
    });

    test('stops at the agent cap', () async {
      final runner = FakeRunner(_default);
      final plan = _plan({
        'goal': 'g',
        'phases': [
          {
            'id': 'a',
            'for_each': ['1', '2'],
            'steps': [
              {'id': 's', 'prompt': 'x'},
            ],
          },
          {
            'id': 'b',
            'for_each': ['1', '2'],
            'steps': [
              {'id': 's', 'prompt': 'x'},
            ],
          },
        ],
      });
      final j = await _engine(_journal(plan, limits: const UltraLimits(maxAgents: 3, maxConcurrent: 1)), runner).run();
      expect(j.agentsStarted, 3);
      expect(j.status, UltraRunStatus.capped);
      expect(j.note, contains('3-agent cap'));
      expect(j.steps['b.s[1]']!.status, StepStatus.skipped);
      expect(j.steps[criticKey]!.status, StepStatus.skipped);
    });

    test('stops at the wall-time limit', () async {
      var now = DateTime(2026);
      final runner = FakeRunner(_default, manual: true);
      final plan = _plan({
        'goal': 'g',
        'phases': [
          {
            'id': 'a',
            'steps': [
              {'id': 's', 'prompt': 'x'},
            ],
          },
        ],
      });
      final done = _engine(_journal(plan), runner, clock: () => now).run();
      await pumpUntil(() => runner.started.isNotEmpty);
      now = now.add(const Duration(hours: 3));
      final j = await done;
      expect(j.status, UltraRunStatus.capped);
      expect(j.note, contains('120-minute'));
    });

    test('only runs on the Max plan, and not on an empty wallet', () async {
      final plan = _plan({
        'goal': 'g',
        'phases': [
          {
            'id': 'a',
            'steps': [
              {'id': 's', 'prompt': 'x'},
            ],
          },
        ],
      });
      final runner = FakeRunner(_default);
      final pro = await _engine(_journal(plan), runner, wallet: FakeWallet(planId: 'pro')).run();
      expect(pro.status, UltraRunStatus.failed);
      expect(pro.note, contains('Max plan'));
      final empty = await _engine(_journal(plan), runner, wallet: FakeWallet(available: 0)).run();
      expect(empty.status, UltraRunStatus.failed);
      expect(runner.started, isEmpty);
      expect(ultraAllowedOn('max'), isTrue);
    });

    test('the critic’s gaps run as one more phase', () async {
      final runner = FakeRunner(
        (r) => r.role == ChildRole.critic
            ? ok(
                '```json\n{"complete": false, "notes": "docs missing", "gaps": '
                '[{"title": "Write docs", "prompt": "Document the API", "writes": true}]}\n```',
              )
            : _default(r),
      );
      final plan = _plan({
        'goal': 'g',
        'phases': [
          {
            'id': 'a',
            'steps': [
              {'id': 's', 'prompt': 'x'},
            ],
          },
        ],
      });
      final j = await _engine(_journal(plan), runner).run();
      expect(j.complete, isFalse);
      expect(j.gaps!.id, 'critic-gaps');
      final gap = j.steps['critic-gaps.gap-1']!;
      expect(gap.status, StepStatus.done);
      expect(gap.merge!.merged, isTrue);
      expect(runner.byRole(ChildRole.step).last.brief, contains('did a.s'));
      expect(runner.byRole(ChildRole.critic), hasLength(1));
      expect(ultraReport(j), contains('docs missing'));
      // The extra phase survives a reload.
      final back = UltraJournal.fromJson(jsonDecode(jsonEncode(j.toJson())) as Map<String, Object?>)!;
      expect(back.gaps!.steps.single.writes, isTrue);
    });

    test('the user can stop a run', () async {
      final runner = FakeRunner(_default, manual: true);
      final plan = _plan({
        'goal': 'g',
        'phases': [
          {
            'id': 'a',
            'steps': [
              {'id': 's', 'prompt': 'x'},
            ],
          },
          {
            'id': 'b',
            'steps': [
              {'id': 's', 'prompt': 'x'},
            ],
          },
        ],
      });
      final engine = _engine(_journal(plan), runner);
      final done = engine.run();
      await pumpUntil(() => runner.started.isNotEmpty);
      engine.stop();
      final j = await done;
      expect(j.status, UltraRunStatus.stopped);
      expect(j.steps['a.s']!.status, StepStatus.stopped);
      expect(j.steps.containsKey('b.s'), isFalse);
    });

    test('resumes from the journal: finished steps stay, cut-off ones run again', () async {
      final plan = _plan({
        'goal': 'g',
        'phases': [
          {
            'id': 'a',
            'steps': [
              {'id': 's', 'prompt': 'x'},
              {'id': 't', 'prompt': 'x'},
            ],
          },
        ],
      });
      final old = _journal(plan)
        ..budgetMicros = 25000000
        ..agentsStarted = 2
        ..elapsed = const Duration(minutes: 30)
        ..steps['a.s'] = StepRecord(
          key: 'a.s',
          phaseId: 'a',
          stepId: 's',
          title: 's',
          status: StepStatus.done,
          output: 'old result',
          costMicros: 700,
          childIds: ['old-1'],
        )
        ..steps['a.t'] = StepRecord(
          key: 'a.t',
          phaseId: 'a',
          stepId: 't',
          title: 't',
          status: StepStatus.running,
          childIds: ['old-2'],
        );
      final reloaded = UltraJournal.fromJson(jsonDecode(jsonEncode(old.toJson())) as Map<String, Object?>)!;
      final runner = FakeRunner(_default);
      final j = await _engine(reloaded, runner).run();
      expect(runner.abandoned, ['old-2']);
      expect(runner.byRole(ChildRole.step).map((r) => r.key), ['a.t']);
      expect(j.steps['a.s']!.output, 'old result');
      expect(j.steps['a.t']!.childIds, ['old-2', 'child-1']);
      expect(j.agentsStarted, 4);
      expect(j.elapsed, greaterThanOrEqualTo(const Duration(minutes: 30)));
      expect(j.status, UltraRunStatus.done);
      expect(ultraReport(j), contains('old result'));
    });
  });

  test('the orchestrator rules state the caps', () {
    final rules = ultraOrchestratorRules(const UltraLimits());
    expect(rules, contains('16 agents at once'));
    expect(rules, contains(r'$25'));
    expect(rules, contains('120'));
    expect(ultraPlanRejected(['x']), contains('- x'));
  });
}

Future<void> pumpUntil(bool Function() ready) async {
  for (var i = 0; i < 500 && !ready(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(ready(), isTrue);
}
