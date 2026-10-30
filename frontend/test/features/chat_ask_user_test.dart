import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/net/api_error.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/chat/chat_providers.dart';
import 'package:every_ai/features/chat/data/chat_transport.dart';
import 'package:every_ai/features/chat/domain/ask_user.dart';
import 'package:every_ai/features/chat/domain/chat_session.dart';
import 'package:every_ai/features/chat/domain/message.dart';
import 'package:every_ai/features/chat/ui/ask_user_card.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:every_ai/features/questions/domain/questions.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

class _Transport implements ChatTransport {
  final requests = <ChatRequest>[];
  final turns = <StreamController<ChatEvent>>[];

  @override
  Stream<ChatEvent> send(ChatRequest request, {Future<void>? cancel}) {
    requests.add(request);
    final turn = StreamController<ChatEvent>();
    turns.add(turn);
    cancel?.then((_) {
      if (!turn.isClosed) {
        turn.addError(const CancelledError());
        turn.close();
      }
    });
    return turn.stream;
  }
}

class _Results implements ToolResults {
  final answers = <(String, Object?, bool)>[];

  @override
  Future<bool> resolve(String callId, Object? result, {bool isError = false}) async {
    answers.add((callId, result, isError));
    return true;
  }
}

class _Catalog extends CatalogController {
  @override
  ModelCatalog build() => builtInCatalog;
}

final _args = jsonEncode({
  'questions': [
    {
      'question': 'Which tone?',
      'header': 'Tone',
      'options': [
        {'label': 'Formal', 'description': 'For a cover letter'},
        {'label': 'Casual'},
      ],
    },
  ],
});

void main() {
  late AppDatabase db;
  late _Transport transport;
  late _Results results;
  late ProviderContainer container;
  const id = 'conv-ask';

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    transport = _Transport();
    results = _Results();
    final prefs = await Preferences.load(db);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(prefs),
        chatTransportProvider.overrideWithValue(transport),
        toolResultsProvider.overrideWithValue(results),
        modelCatalogProvider.overrideWith(_Catalog.new),
      ],
    );
    container.listen(chatSessionProvider(id), (_, _) {});
  });

  tearDown(() async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    container.dispose();
    await db.close();
  });

  ChatSessionState state() => container.read(chatSessionProvider(id));
  ChatController ctl() => container.read(chatSessionProvider(id).notifier);
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

  Future<void> askOnce() async {
    await settle();
    await ctl().send('Write me a short bio');
    transport.turns.single.add(ToolWait(id: 'ask_1', name: askUserTool, argumentsJson: _args));
    await settle();
  }

  Future<Message> finishTurn() async {
    transport.turns.single
      ..add(const ToolProgress(id: 'ask_1', name: askUserTool, status: ToolRunStatus.done))
      ..add(const TextDelta('Here it is.'))
      ..add(const TurnDone());
    unawaited(transport.turns.single.close());
    await settle();
    return state().messages.last;
  }

  test('ask_user is declared as a client tool', () async {
    await askOnce();
    expect(transport.requests.single.clientTools, contains(askUserTool));
    expect(state().pendingTools.single.name, askUserTool);
  });

  test('card answers go back to the model and stay on the saved part', () async {
    await askOnce();
    final outcome = AskUserOutcome.answered(const [
      QuestionAnswer(selected: {1}),
    ]);
    expect(await ctl().answerQuestions('ask_1', outcome), isTrue);

    final (callId, result, isError) = results.answers.single;
    expect(callId, 'ask_1');
    expect(isError, isFalse);
    expect(result, contains('Which tone? → Casual'));
    expect(state().pendingTools, isEmpty);
    final live = state().liveParts.whereType<ToolCallPart>().single;
    expect(AskUserOutcome.fromJson(live.resultJson)!.answers.single.selected, {1});

    final saved = await finishTurn();
    // The settled wait is not shown as a server-tool step.
    expect(state().liveTools, isEmpty);
    final part = saved.parts.whereType<ToolCallPart>().single;
    expect(AskUserOutcome.fromJson(part.resultJson)!.answers.single.selected, {1});

    // A later turn tells the model what it asked and what came back.
    final note = toolOutputsByMessage([saved])[saved.id]!;
    expect(note, contains('Which tone? → Casual'));
  });

  test('typing in the composer while the card waits replies to it', () async {
    await askOnce();
    await ctl().send('Make it funny, for a conference badge');
    expect(transport.requests, hasLength(1), reason: 'no new turn starts');
    final (_, result, _) = results.answers.single;
    expect(result, contains('Make it funny, for a conference badge'));
    final part = state().liveParts.whereType<ToolCallPart>().single;
    expect(AskUserOutcome.fromJson(part.resultJson)!.reply, 'Make it funny, for a conference badge');
    // Once answered, more typing while busy goes nowhere.
    await ctl().send('again');
    expect(results.answers, hasLength(1));
  });

  test('outcomes round-trip and unanswered calls get a note', () {
    const reply = AskUserOutcome.replied('my own words');
    expect(AskUserOutcome.fromJson(reply.toJson())!.reply, 'my own words');
    expect(AskUserOutcome.fromJson('not json'), isNull);
    expect(AskUserOutcome.fromJson(null), isNull);
    final part = ToolCallPart(toolName: askUserTool, argumentsJson: _args, callId: 'x');
    expect(askUserQuestions(part).single.options.map((o) => o.label), ['Formal', 'Casual']);
    expect(askUserNote(part), contains('(no answer)'));
  });

  group('AskUserCard', () {
    Widget host(ToolCallPart part) => UncontrolledProviderScope(
      container: container,
      child: m.MaterialApp(
        home: m.Material(
          child: EveryThemeScope(
            theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
            child: SingleChildScrollView(
              child: AskUserCard(part: part, conversationId: id),
            ),
          ),
        ),
      ),
    );

    testWidgets('a waiting card submits the picked option', (tester) async {
      await tester.runAsync(askOnce);
      final part = state().liveParts.whereType<ToolCallPart>().single;
      await tester.pumpWidget(host(part));

      expect(find.text('Which tone?'), findsOneWidget);
      await tester.tap(find.text('Formal'));
      await tester.pump();
      await tester.tap(find.text('Submit answer'));
      await tester.runAsync(settle);
      await tester.pump();

      expect(results.answers.single.$2, contains('Which tone? → Formal'));
      // The answered part renders as a summary.
      await tester.pumpWidget(host(state().liveParts.whereType<ToolCallPart>().single));
      expect(find.text('Submit answer'), findsNothing);
      expect(find.text('Formal'), findsOneWidget);
    });

    testWidgets('a card nobody waits on is closed', (tester) async {
      await tester.runAsync(settle);
      await tester.pumpWidget(host(ToolCallPart(toolName: askUserTool, argumentsJson: _args, callId: 'old')));
      expect(find.text('No longer waiting for an answer'), findsOneWidget);
      await tester.tap(find.text('Casual'));
      await tester.pump();
      expect(results.answers, isEmpty);
    });
  });
}
