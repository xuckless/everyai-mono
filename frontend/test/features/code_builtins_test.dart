import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/git_commands.dart';
import 'package:every_ai/features/code/domain/goal.dart';
import 'package:every_ai/features/code/domain/morning.dart';
import 'package:every_ai/features/code/domain/review.dart';
import 'package:every_ai/features/code/domain/session_commands.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/git/git_models.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/fake_harness.dart';
import 'package:every_ai/features/code/morning_providers.dart';
import 'package:every_ai/features/code/ui/code_composer.dart';
import 'package:every_ai/features/code/ui/transcript/aside_card.dart';
import 'package:every_ai/features/code/ui/transcript/goal_card.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:every_ai/features/slash/skills/learn.dart';
import 'package:every_ai/features/slash/skills/learn_sources.dart';
import 'package:every_ai/features/slash/skills/skill_md.dart';
import 'package:every_ai/features/slash/slash_command.dart';
import 'package:every_ai/features/slash/slash_registry.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

class _FixedCatalog extends CatalogController {
  @override
  ModelCatalog build() => builtInCatalog;
}

Future<T> _until<T>(T Function() read, bool Function(T) cond, {Duration timeout = const Duration(seconds: 8)}) async {
  final end = DateTime.now().add(timeout);
  while (true) {
    final v = read();
    if (cond(v)) return v;
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met: $v');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Map<String, Object?> _says(String text) => {
  'kind': 'MessageEvent',
  'source': 'agent',
  'llm_message': {
    'role': 'assistant',
    'content': [
      {'type': 'text', 'text': text},
    ],
  },
};

FileDiff _file(String path, List<String> lines) => FileDiff(
  path: path,
  header: ['diff --git a/$path b/$path', '--- a/$path', '+++ b/$path'],
  hunks: [DiffHunk(header: '@@ -1,2 +1,2 @@', oldStart: 1, newStart: 1, lines: lines)],
);

CodeSessionInfo _session(String id, {DateTime? at, String? parent, SessionWorktree? worktree}) => CodeSessionInfo(
  id: id,
  projectId: 'p1',
  title: 'Session $id',
  conversationId: 'c-$id',
  model: 'm',
  mode: AgentMode.ask,
  workingDir: '/tmp/$id',
  createdAt: at ?? DateTime(2026, 10, 30, 8),
  branch: 'everyai/$id',
  parentId: parent,
  worktree: worktree,
);

Widget _themed(Widget child) => m.MaterialApp(
  home: m.Material(
    child: EveryThemeScope(theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light), child: child),
  ),
);

void main() {
  group('goal', () {
    test('arguments: the objective and a turn budget', () {
      expect(parseGoalArgs('make the tests pass --turns 5'), (objective: 'make the tests pass', budget: 5));
      expect(parseGoalArgs('turns=3 fix the build'), (objective: 'fix the build', budget: 3));
      expect(parseGoalArgs('ship it'), (objective: 'ship it', budget: defaultGoalTurns));
      expect(parseGoalArgs('ship it --turns 500')!.budget, maxGoalTurns);
      expect(parseGoalArgs('--turns 4'), isNull);
      expect(parseGoalArgs('  '), isNull);
    });

    test('when to judge', () {
      expect(goalMoment(const Transcript(status: ExecutionStatus.finished)), GoalMoment.judge);
      expect(goalMoment(const Transcript(status: ExecutionStatus.idle)), GoalMoment.judge);
      expect(goalMoment(const Transcript(status: ExecutionStatus.running)), GoalMoment.later);
      expect(goalMoment(const Transcript(status: ExecutionStatus.finished), queued: true), GoalMoment.later);
      expect(goalMoment(const Transcript(status: ExecutionStatus.error)), GoalMoment.failed);
      const call = ActionCall(id: 'a', raw: {}, toolName: 'terminal', toolCallId: 't', action: {});
      expect(
        goalMoment(const Transcript(status: ExecutionStatus.waitingForConfirmation, pending: [call])),
        GoalMoment.user,
      );
    });

    test('verdicts are read from JSON, or a plain yes/no; anything else is null', () {
      final v = parseGoalVerdict('Sure:\n{"met": false, "reason": "2 tests fail", "next": "Fix parse()"}')!;
      expect(v.met, isFalse);
      expect(v.reason, '2 tests fail');
      expect(v.next, 'Fix parse()');
      expect(parseGoalVerdict('{"met": true, "reason": "all green"}')!.met, isTrue);
      expect(parseGoalVerdict('Met. Everything passes.')!.met, isTrue);
      expect(parseGoalVerdict('No, the build fails')!.met, isFalse);
      expect(parseGoalVerdict('I am not sure'), isNull);
      expect(parseGoalVerdict('{"done": true}'), isNull);
    });

    test('the judge gets the record and the goal; the follow-up says what is next', () {
      final req = goalJudgeRequest(record: 'User: add a flag', objective: 'flag works');
      expect(req.first['role'], 'system');
      expect(req.last['content'], contains('<session-record>\nUser: add a flag'));
      expect(req.last['content'], endsWith('<goal>\nflag works\n</goal>'));

      const goal = Goal(objective: 'flag works', budget: 2);
      final msg = goalContinueMessage(goal, const GoalVerdict(met: false, reason: 'no test', next: 'Add a test'));
      expect(msg, contains('Goal: flag works'));
      expect(msg, contains('Next: Add a test'));
      expect(msg, contains('follow-up 1 of 2.'));
      expect(goalContinueMessage(goal.copyWith(used: 1), const GoalVerdict(met: false)), contains('last one'));
    });
  });

  group('review and git drafts', () {
    test('the review brief carries the diff, the base and the focus', () {
      final files = [
        _file('lib/a.dart', [' keep', '-old', '+new']),
      ];
      final brief = reviewBrief(files: files, baseCommit: 'abc123', focus: 'error handling');
      expect(brief, contains('focus on: error handling'));
      expect(brief, contains('git diff abc123'));
      expect(brief, contains('1 file, +1 −1'));
      expect(brief, contains('+new'));
      expect(brief, contains('Do not edit any file'));
      expect(reviewBrief(files: const []), contains('no session branch'));
      final cut = renderDiff([
        for (var i = 0; i < 50; i++) _file('f$i.dart', ['+${'x' * 100}']),
      ], maxChars: 1000);
      expect(cut.cut, isTrue);
      expect(cut.text.length, lessThanOrEqualTo(1000));
      expect(reviewFollowUp('- high: bug'), contains('<review>\n- high: bug\n</review>'));
    });

    test('commit messages lose fences, quotes and credit lines', () {
      expect(cleanCommitMessage('```\nAdd a flag\n\nCo-Authored-By: Claude <x@y>\n```'), 'Add a flag');
      expect(cleanCommitMessage('"Fix the parser"'), 'Fix the parser');
      expect(cleanCommitMessage('Commit message: Fix it'), 'Fix it');
      final req = commitMessageRequest(
        files: [
          _file('a', const ['+x']),
        ],
        title: 'Flags',
        hint: 'mention the CLI',
      );
      expect(req.last['content'], contains('The developer adds: mention the CLI'));
    });

    test('pull request drafts and the by-hand route', () {
      final d = parsePrDraft('Title: Add flags\n\nAdds a --verbose flag.\n\n## Changes\n- cli');
      expect(d.title, 'Add flags');
      expect(d.body, startsWith('Adds a --verbose flag.'));
      expect(parsePrDraft('# Add flags\nBody').title, 'Add flags');
      expect(parsePrDraft('', fallbackTitle: 'Session').title, 'Session');

      expect(
        githubCompareUrl('git@github.com:acme/app.git', base: 'main', branch: 'everyai/x'),
        'https://github.com/acme/app/compare/main...everyai/x?expand=1',
      );
      expect(githubCompareUrl('https://github.com/acme/app', base: 'main', branch: 'b'), contains('acme/app/compare'));
      expect(githubCompareUrl('https://gitlab.com/acme/app.git', base: 'main', branch: 'b'), isNull);
      final how = prInstructions(branch: 'everyai/x', base: 'main', remoteUrl: 'https://github.com/acme/app.git');
      expect(how, contains('git push -u origin everyai/x'));
      expect(how, contains('compare/main...everyai/x'));
      expect(how, contains('gh auth login'));
    });
  });

  test('the morning brief sorts sessions by what they need', () {
    final now = DateTime(2026, 10, 30, 9);
    final brief = morningBrief([
      MorningEntry(session: _session('ask'), status: SessionStatus.needsInput, project: 'Counter'),
      MorningEntry(session: _session('run'), status: SessionStatus.running),
      MorningEntry(session: _session('merge'), status: SessionStatus.done, files: 2, added: 10, removed: 1, ahead: 1),
      MorningEntry(session: _session('quiet'), status: SessionStatus.done),
      MorningEntry(
        session: _session('old', at: DateTime(2026, 9)),
        status: SessionStatus.failed,
      ),
      MorningEntry(
        session: _session('child', parent: 'run'),
        status: SessionStatus.needsInput,
      ),
    ], now: now);
    expect(brief, startsWith('**Good morning.**'));
    expect(brief, contains('1 waiting on you, 1 working, 1 with changes to merge.'));
    expect(brief, contains('**Waiting on you**\n- Session ask · Counter'));
    expect(brief, contains('- Session merge — 2 files changed (+10 −1), 1 commit on `everyai/merge`'));
    expect(brief, contains('**Finished recently**\n- Session quiet'));
    expect(brief, isNot(contains('Session old')));
    expect(brief, isNot(contains('Session child')));
    expect(morningBrief(const [], now: now), contains('No coding sessions yet'));
  });

  group('learn', () {
    test('arguments name a URL, a folder or the conversation', () {
      bool folder(String p) => p == '~/notes' || p == '/My Docs';
      expect(parseLearnArgs('https://example.com/guide deploys', isFolder: folder), isA<LearnFromUrl>());
      final url = parseLearnArgs('https://example.com/guide deploys', isFolder: folder) as LearnFromUrl;
      expect((url.url, url.hint), ('https://example.com/guide', 'deploys'));
      final dir = parseLearnArgs('~/notes release steps', isFolder: folder) as LearnFromFolder;
      expect((dir.path, dir.hint), ('~/notes', 'release steps'));
      expect((parseLearnArgs('"/My Docs"', isFolder: folder) as LearnFromFolder).path, '/My Docs');
      expect(() => parseLearnArgs('/missing thing', isFolder: folder), throwsFormatException);
      // Relative paths start from the session's folder, never the app's.
      bool proj(String p) => p == '/work/app/docs' || p == '/work/shared';
      final docs = parseLearnArgs('./docs deployment steps', isFolder: proj, base: '/work/app') as LearnFromFolder;
      expect((docs.path, docs.hint), ('/work/app/docs', 'deployment steps'));
      expect((parseLearnArgs('../shared', isFolder: proj, base: '/work/app') as LearnFromFolder).path, '/work/shared');
      expect(() => parseLearnArgs('./nope x', isFolder: proj, base: '/work/app'), throwsFormatException);
      expect(() => parseLearnArgs('./docs x', isFolder: proj), throwsFormatException);
      expect(joinPath('/a/b/', './c/../d'), '/a/b/d');
      expect((parseLearnArgs('how we test', isFolder: folder) as LearnFromConversation).hint, 'how we test');
      expect(parseLearnArgs('', isFolder: folder), isA<LearnFromConversation>());
    });

    test('a folder is read docs first, skipping dependencies and binaries', () async {
      final dir = await Directory.systemTemp.createTemp('learn');
      addTearDown(() => dir.delete(recursive: true));
      File('${dir.path}/src/main.py')
        ..createSync(recursive: true)
        ..writeAsStringSync('print(1)');
      File('${dir.path}/README.md').writeAsStringSync('# Tool\nRun it.');
      File('${dir.path}/node_modules/x/index.js')
        ..createSync(recursive: true)
        ..writeAsStringSync('junk');
      File('${dir.path}/logo.png').writeAsBytesSync([0x89, 0, 1, 2]);
      File('${dir.path}/.env.md').writeAsStringSync('SECRET=1');
      final docs = await readLearnFolder(dir.path);
      expect([for (final d in docs) d.path], ['README.md', 'src/main.py']);
      expect(isFolder(dir.path), isTrue);
      expect(await holdsSkills(dir.path), isFalse);
      File('${dir.path}/deploy/SKILL.md')
        ..createSync(recursive: true)
        ..writeAsStringSync('---\nname: deploy\ndescription: Deploys.\n---\nSteps');
      expect(await holdsSkills(dir.path), isTrue);
    });

    test('a drafted skill goes through the import check', () async {
      final ok = await skillCandidate(
        const SkillMd(name: 'release-notes', description: 'Writes release notes from merged changes.', body: '# Notes'),
      );
      expect(ok.ok, isTrue);
      expect(ok.dirName, 'release-notes');
    });
  });

  group('controller', () {
    late AppDatabase db;
    late ProviderContainer container;
    late FakeHarness harness;
    final verdicts = <String>[];
    final judged = <List<Map<String, Object?>>>[];

    Future<void> setUpWith(FakeHarness h) async {
      db = AppDatabase(NativeDatabase.memory());
      final prefs = await Preferences.load(db);
      prefs['code.projects'] = jsonEncode([
        const CodeProject(id: 'p1', name: 'Counter', path: '${demoScheme}counter-app').toJson(),
      ]);
      harness = h;
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(prefs),
          harnessProvider.overrideWithValue(harness),
          modelCatalogProvider.overrideWith(_FixedCatalog.new),
          codeSideModelProvider.overrideWithValue((messages) async {
            judged.add(messages);
            return verdicts.isEmpty ? '{"met": false}' : verdicts.removeAt(0);
          }),
        ],
      );
    }

    tearDown(() async {
      container.dispose();
      await db.close();
      verdicts.clear();
      judged.clear();
    });

    Future<String> start() async {
      final info = await container
          .read(codeSessionsProvider.notifier)
          .start(
            project: container.read(codeProjectsProvider).single,
            prompt: 'Add a flag',
            model: 'anthropic/claude-haiku-5.5',
            mode: AgentMode.ask,
          );
      container.listen(codeSessionProvider(info.id), (_, _) {});
      await _until(() => container.read(codeSessionProvider(info.id)).status, (s) => s == SessionStatus.done);
      return info.id;
    }

    List<String> userTurns(String id) => [
      for (final t in container.read(codeSessionProvider(id)).transcript.items.whereType<UserTurn>()) t.text,
    ];

    test('/goal sends the agent back until the judge finds it met', () async {
      await setUpWith(
        FakeHarness(
          step: Duration.zero,
          turns: [
            [_says('Started.')],
            [_says('Added the flag.')],
            [_says('Added a test; it passes.')],
            [_says('Nothing left.')],
          ],
        ),
      );
      final id = await start();
      verdicts.addAll(['{"met": false, "reason": "no test", "next": "Add a test"}', '{"met": true, "reason": "ok"}']);
      await container.read(codeSessionProvider(id).notifier).setGoal('The flag works and is tested', budget: 3);
      final goal = await _until(() => container.read(codeSessionProvider(id)).goal!, (g) => g.status == GoalStatus.met);
      expect(goal.used, 1);
      expect(goal.note, 'ok');
      expect(judged, hasLength(2));
      expect(judged.last.last['content'], contains('Added a test; it passes.'));
      final turns = userTurns(id);
      expect(turns.where((t) => t.contains('Goal: The flag works and is tested')), hasLength(2));
      expect(turns.last, contains('Next: Add a test'));
    });

    test('/goal stops when its turns run out, and Stop pauses it', () async {
      await setUpWith(
        FakeHarness(
          step: Duration.zero,
          turns: [
            for (var i = 0; i < 6; i++) [_says('Turn $i.')],
          ],
        ),
      );
      final id = await start();
      final controller = container.read(codeSessionProvider(id).notifier);
      await controller.setGoal('Never done', budget: 1);
      final goal = await _until(
        () => container.read(codeSessionProvider(id)).goal!,
        (g) => g.status == GoalStatus.outOfTurns,
      );
      expect(goal.used, 1);

      await controller.setGoal('Again', budget: 5);
      await controller.stop();
      expect(container.read(codeSessionProvider(id)).goal!.status, GoalStatus.paused);
      controller.clearGoal();
      expect(container.read(codeSessionProvider(id)).goal, isNull);
    });

    test('/review runs a read-only reviewer and shows its report', () async {
      await setUpWith(
        FakeHarness(
          step: Duration.zero,
          turns: [
            [_says('Done.')],
            [_says('Fixing it.')],
          ],
          subagentTurns: [
            [_says('- high: lib/a.dart:3 drops the error. Verdict: fix first.')],
          ],
        ),
      );
      final id = await start();
      final controller = container.read(codeSessionProvider(id).notifier);
      await controller.review('error handling');
      final aside = await _until(() => container.read(codeSessionProvider(id)).asides.single, (a) => !a.busy);
      expect(aside.kind, AsideKind.review);
      expect(aside.ready, isTrue);
      expect(aside.answer, contains('lib/a.dart:3'));
      final child = container.read(codeSessionsProvider.notifier).byId(aside.childId!)!;
      expect(child.parentId, id);
      expect(child.mode, AgentMode.plan);
      expect(child.title, 'Review: error handling');

      await controller.sendReview(aside.id);
      expect(container.read(codeSessionProvider(id)).asides, isEmpty);
      await _until(() => userTurns(id), (t) => t.last.contains('<review>'));
    });

    test('/commit and /pr need a worktree', () async {
      await setUpWith(FakeHarness(step: Duration.zero, turns: const []));
      final id = await start();
      final controller = container.read(codeSessionProvider(id).notifier);
      await controller.draftCommit('');
      await controller.draftPr('');
      final asides = container.read(codeSessionProvider(id)).asides;
      expect(asides.map((a) => a.kind), [AsideKind.commit, AsideKind.pr]);
      expect(asides.every((a) => a.error!.contains('worktree')), isTrue);
    });

    test('/morning briefs every session without a model call', () async {
      await setUpWith(FakeHarness(step: Duration.zero, turns: const []));
      await start();
      await container.read(morningBriefProvider.notifier).refresh(now: DateTime.now());
      final brief = container.read(morningBriefProvider)!;
      expect(brief.kind, AsideKind.morning);
      expect(brief.answer, contains('Add a flag'));
      expect(judged, isEmpty);
      container.read(morningBriefProvider.notifier).dismiss();
      expect(container.read(morningBriefProvider), isNull);
    });
  });

  testWidgets('the new commands reach the session from the composer', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [slashCommandsProvider.overrideWithValue(builtInSlashCommands)],
        child: _themed(
          Align(
            alignment: Alignment.bottomCenter,
            child: CodeComposer(
              busy: false,
              mode: AgentMode.ask,
              onModeChanged: (_) {},
              onSend: (text, _) => calls.add('send|$text'),
              slashHost: CodeSlashHost(
                setMode: (_) {},
                review: (a) => calls.add('review|$a'),
                goal: (a) => calls.add('goal|$a'),
                commit: (a) => calls.add('commit|$a'),
                pr: (a) => calls.add('pr|$a'),
                learn: (a) => calls.add('learn|$a'),
                morning: () => calls.add('morning'),
              ),
            ),
          ),
        ),
      ),
    );
    for (final line in [
      '/review security',
      '/goal tests pass --turns 3',
      '/commit',
      '/pr',
      '/learn https://example.com',
      '/morning',
    ]) {
      await tester.enterText(find.byType(EditableText), line);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
    }
    expect(calls, [
      'review|security',
      'goal|tests pass --turns 3',
      'commit|',
      'pr|',
      'learn|https://example.com',
      'morning',
    ]);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('a commit card commits the edited message; a goal card shows where it is', (tester) async {
    String? committed;
    const draft = Aside(id: 1, kind: AsideKind.commit);
    await tester.pumpWidget(
      _themed(
        AsideCard(
          aside: draft.done('Add a flag', ready: true),
          onDismiss: () {},
          onCommit: (message) async => committed = message,
        ),
      ),
    );
    await tester.enterText(find.byType(EditableText), 'Add a --verbose flag');
    await tester.tap(find.text('Commit all changes'));
    await tester.pump();
    expect(committed, 'Add a --verbose flag');

    var cleared = 0;
    await tester.pumpWidget(
      _themed(
        GoalCard(
          goal: const Goal(objective: 'Tests pass', budget: 3, used: 1, note: 'one test fails'),
          onClear: () => cleared++,
        ),
      ),
    );
    expect(find.text('Goal · Working on it · turn 2 of 4'), findsOneWidget);
    expect(find.text('one test fails'), findsOneWidget);
    await tester.tap(find.byTooltip('Stop the goal'));
    expect(cleared, 1);
  });
}
