import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/session_commands.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
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

void main() {
  group('arguments', () {});

  group('btw request', () {});

  group('controller', () {
    late AppDatabase db;
    late ProviderContainer container;
    late FakeHarness harness;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      final prefs = await Preferences.load(db);
      prefs['code.projects'] = jsonEncode([
        const CodeProject(id: 'p1', name: 'Counter', path: '${demoScheme}counter-app').toJson(),
      ]);
      harness = FakeHarness(step: Duration.zero);
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(prefs),
          harnessProvider.overrideWithValue(harness),
          modelCatalogProvider.overrideWith(_FixedCatalog.new),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    Future<String> startDemo() async {
      final info = await container
          .read(codeSessionsProvider.notifier)
          .start(
            project: container.read(codeProjectsProvider).single,
            prompt: 'Add decrement',
            model: 'anthropic/claude-haiku-5.5',
            mode: AgentMode.ask,
          );
      container.listen(codeSessionProvider(info.id), (_, _) {});
      await _until(() => container.read(codeSessionProvider(info.id)).transcript.openQuestion, (q) => q != null);
      return info.id;
    }

    test('/btw answers beside the session without sending the agent anything', () async {
      final id = await startDemo();
      final controller = container.read(codeSessionProvider(id).notifier);
      final turnsBefore = container.read(codeSessionProvider(id)).transcript.items.whereType<UserTurn>().length;
      List<Map<String, Object?>>? asked;
      final answer = Completer<String>();
      final pending = controller.askAside(
        'What is it asking me?',
        summarizer: (messages) {
          asked = messages;
          return answer.future;
        },
      );
      var asides = container.read(codeSessionProvider(id)).asides;
      expect(asides.single.busy, isTrue);
      expect(asides.single.question, 'What is it asking me?');
      answer.complete('  It wants to know where the button goes.  ');
      await pending;

      asides = container.read(codeSessionProvider(id)).asides;
      expect(asides.single.busy, isFalse);
      expect(asides.single.answer, 'It wants to know where the button goes.');
      expect(asked!.last['content'], contains('Add decrement'));
      expect(asked!.last['content'], endsWith('Side question: What is it asking me?'));
      // The agent's conversation is untouched and its question is still open.
      final t = container.read(codeSessionProvider(id)).transcript;
      expect(t.items.whereType<UserTurn>().length, turnsBefore);
      expect(t.openQuestion, isNotNull);

      controller.dismissAside(asides.single.id);
      expect(container.read(codeSessionProvider(id)).asides, isEmpty);
    });

    test('/cost adds one usage card', () async {
      final id = await startDemo();
      final controller = container.read(codeSessionProvider(id).notifier);
      await controller.showCost();
      await controller.showCost();
      final asides = container.read(codeSessionProvider(id)).asides;
      expect(asides.single.kind, AsideKind.cost);
    });

    test('/model and /effort switch the live conversation and the saved session', () async {
      final id = await startDemo();
      final controller = container.read(codeSessionProvider(id).notifier);
      CodeSessionInfo info() => container.read(codeSessionsProvider.notifier).byId(id)!;

      expect(await controller.switchModel(model: 'anthropic/claude-opus-5.5', effort: 'high'), startsWith('Now using'));
      expect(info().model, 'anthropic/claude-opus-5.5');
      expect(info().effort, 'high');
      expect(await controller.switchModel(effort: ''), startsWith('Now using'));
      expect(info().effort, '');
      expect(info().model, 'anthropic/claude-opus-5.5');
      expect(await controller.switchModel(effort: ''), 'Already using that.');
      expect(harness.switched, ['anthropic/claude-opus-5.5@high', 'anthropic/claude-opus-5.5@']);
    });
  });

  group('CodeComposer commands', () {});
}
