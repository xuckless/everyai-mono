import 'dart:io';

import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/git/git_service.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/ultra/data/ultra_store.dart';
import 'package:every_ai/features/code/ultra/domain/ultra_engine.dart';
import 'package:every_ai/features/code/ultra/domain/ultra_journal.dart';
import 'package:every_ai/features/code/ultra/domain/ultra_plan.dart';
import 'package:every_ai/features/code/ultra/ultra_providers.dart';
import 'package:flutter_test/flutter_test.dart';

Future<String> _git(String dir, List<String> args) async {
  final r = await Process.run('git', ['-C', dir, ...args]);
  if (r.exitCode != 0) fail('git ${args.join(' ')}: ${r.stderr}');
  return '${r.stdout}'.trim();
}

void main() {
  late Directory tmp;
  late String repo;
  late SessionWorktree base;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('everyai-ultra');
    repo = '${tmp.path}/app';
    await Directory(repo).create(recursive: true);
    await _git(repo, ['init', '-q', '-b', 'main']);
    await _git(repo, ['config', 'user.name', 'Dev']);
    await _git(repo, ['config', 'user.email', 'dev@example.com']);
    File('$repo/a.txt').writeAsStringSync('one\n');
    await _git(repo, ['add', '-A']);
    await _git(repo, ['commit', '-q', '-m', 'Initial commit']);
    base = await GitService.createWorktree(
      repoRoot: repo,
      slug: 'session',
      worktreesDir: '${tmp.path}/worktrees/app',
      hooksDir: '${tmp.path}/git-hooks',
    );
  });
  tearDown(() => tmp.delete(recursive: true));

  test('step worktrees start from the session, merge back, and keep a conflicting branch', () async {
    // Unsaved work in the session is committed first, so steps see it.
    File('${base.path}/b.txt').writeAsStringSync('draft\n');
    expect(await ultraSaveBase(base), isTrue);
    final ws = ultraWorkspace(base: base, dataDir: tmp.path);
    expect(ws.isolates, isTrue);

    final one = await ws.create('0190-run-abcdef12', 'build.write[0]');
    expect(one.branch, 'everyai/ultra-abcdef12-build-write-0');
    expect(File('${one.path}/b.txt').existsSync(), isTrue);
    final two = await ws.create('0190-run-abcdef12', 'build.write[1]');
    final quiet = await ws.create('0190-run-abcdef12', 'build.look');

    File('${one.path}/a.txt').writeAsStringSync('ONE\n');
    File('${two.path}/a.txt').writeAsStringSync('uno\n');
    final first = await ws.merge(one, 'Ultra: write 0');
    expect(first.merged, isTrue);
    expect(File('${base.path}/a.txt').readAsStringSync(), 'ONE\n');
    expect(Directory(one.path).existsSync(), isFalse);

    final second = await ws.merge(two, 'Ultra: write 1');
    expect(second.merged, isFalse);
    expect(second.detail, contains('a.txt'));
    // The session is clean again and the branch is left for the user.
    expect(await _git(base.path, ['status', '--porcelain']), isEmpty);
    expect(await _git(repo, ['branch', '--list', two.branch]), contains(two.branch));
    expect(Directory(two.path).existsSync(), isFalse);

    final none = await ws.merge(quiet, 'Ultra: look');
    expect(none.merged, isTrue);
    expect(none.detail, 'no changes');
  });

  test('without git there is nothing to isolate', () {
    expect(ultraWorkspace(base: null, dataDir: tmp.path).isolates, isFalse);
  });

  test('journals are saved whole and read back', () async {
    final store = ultraJournalStore(tmp.path);
    final plan = parseUltraPlan({
      'goal': 'g',
      'phases': [
        {
          'id': 'a',
          'steps': [
            {'id': 's', 'prompt': 'x'},
          ],
        },
      ],
    }).plan!;
    final j = UltraJournal(
      runId: 'run-1',
      sessionId: 's',
      plan: plan,
      limits: const UltraLimits(maxConcurrent: 4),
      createdAt: DateTime.utc(2026, 10, 30),
    )..budgetMicros = 5;
    await store.save(j);
    j.agentsStarted = 3;
    await store.save(j);
    final back = (await store.load('run-1'))!;
    expect(back.agentsStarted, 3);
    expect(back.limits.maxConcurrent, 4);
    expect(back.createdAt, DateTime.utc(2026, 10, 30));
    expect(await ultraRunIds(tmp.path), ['run-1']);
    expect(await store.load('missing'), isNull);
  });

  test('Ultra children read unless they write or check a worktree', () {
    UltraChildRequest req(ChildRole role, {bool writes = false, String? dir}) => UltraChildRequest(
      key: 'k',
      title: 't',
      brief: 'b',
      role: role,
      fallbackModel: 'm/x',
      writes: writes,
      workingDir: dir,
    );
    expect(ultraChildMode(req(ChildRole.step)), AgentMode.plan);
    expect(ultraChildMode(req(ChildRole.step, writes: true, dir: '/w')), AgentMode.fullAuto);
    expect(ultraChildMode(req(ChildRole.verify, dir: '/w')), AgentMode.fullAuto);
    expect(ultraChildMode(req(ChildRole.verify)), AgentMode.plan);
    expect(ultraChildMode(req(ChildRole.critic)), AgentMode.plan);
  });

  test('ultra_plan is a client tool the permission check lets through', () {
    const call = ActionCall(id: 'a1', raw: {}, toolName: ultraPlanTool, toolCallId: 't1', action: {});
    expect(isClientTool(call), isTrue);
    expect(AgentMode.plan.rejects(call), isFalse);
  });
}
