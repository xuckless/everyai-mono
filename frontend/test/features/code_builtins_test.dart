import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/git_commands.dart';
import 'package:every_ai/features/code/domain/goal.dart';
import 'package:every_ai/features/code/domain/session_commands.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/git/git_models.dart';
import 'package:every_ai/features/code/harness/fake_harness.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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

void main() {
  group('goal', () {
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
  });

  group('review and git drafts', () {
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
  });
}
