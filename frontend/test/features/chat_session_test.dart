import 'dart:async';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/net/api_error.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/chat/chat_providers.dart';
import 'package:every_ai/features/chat/data/chat_transport.dart';
import 'package:every_ai/features/chat/domain/chat_session.dart';
import 'package:every_ai/features/chat/domain/message.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A transport the test drives by hand: each send() opens a controller.
class FakeTransport implements ChatTransport {
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

/// The built-in catalog, without the network refresh.
class FixedCatalog extends CatalogController {
  @override
  ModelCatalog build() => builtInCatalog;
}

void main() {
  late AppDatabase db;
  late FakeTransport transport;
  late ProviderContainer container;
  const id = 'conv-1';

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    transport = FakeTransport();
    final prefs = await Preferences.load(db);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(prefs),
        chatTransportProvider.overrideWithValue(transport),
        modelCatalogProvider.overrideWith(FixedCatalog.new),
      ],
    );
    // Keep the auto-dispose family alive for the whole test.
    container.listen(chatSessionProvider(id), (_, _) {});
  });

  tearDown(() async {
    // Let fire-and-forget writes finish before the database closes.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    container.dispose();
    await db.close();
  });

  ChatSessionState state() => container.read(chatSessionProvider(id));
  ChatController ctl() => container.read(chatSessionProvider(id).notifier);
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

  test('loads to Idle for a brand-new conversation', () async {
    expect(state().phase, isA<Loading>());
    await settle();
    expect(state().phase, isA<Idle>());
    expect(state().messages, isEmpty);
    expect(state().title, isNull);
  });

  test('send → Awaiting → Streaming → Idle, persisted with title', () async {
    await settle();
    await ctl().send('Hello there');
    expect(state().phase, isA<Awaiting>());
    expect(state().messages.map((m) => m.role), [Role.user, Role.assistant]);
    expect(state().title, 'Hello there');

    transport.turns.single.add(const TextDelta('Hi'));
    await settle();
    expect(state().phase, isA<Streaming>());
    expect(state().streamingText, 'Hi');

    final listBefore = state().messages;
    transport.turns.single.add(const TextDelta(', friend'));
    await settle();
    expect(state().streamingText, 'Hi, friend');
    expect(identical(state().messages, listBefore), isTrue, reason: 'no list rebuild per token');

    transport.turns.single.add(const TurnDone());
    unawaited(transport.turns.single.close());
    await settle();
    expect(state().phase, isA<Idle>());
    expect(state().streamingText, isEmpty);
    final assistant = state().messages.last;
    expect(assistant.status, MessageStatus.complete);
    expect(assistant.plainText, 'Hi, friend');

    final stored = await container.read(chatRepositoryProvider).messages(id);
    expect(stored.map((m) => (m.role, m.plainText, m.status)), [
      (Role.user, 'Hello there', MessageStatus.complete),
      (Role.assistant, 'Hi, friend', MessageStatus.complete),
    ]);
  });

  test('a second send while busy is ignored', () async {
    await settle();
    await ctl().send('one');
    await ctl().send('two');
    expect(transport.requests, hasLength(1));
  });

  test('cancel keeps partial text and returns to Idle', () async {
    await settle();
    await ctl().send('long answer please');
    transport.turns.single.add(const TextDelta('Partial'));
    await settle();
    ctl().cancel();
    await settle();
    expect(state().phase, isA<Idle>());
    expect(state().messages.last.status, MessageStatus.cancelled);
    expect(state().messages.last.plainText, 'Partial');
  });

  test('error → Failed, then retry resends the same prompt and model', () async {
    await settle();
    await ctl().send('flaky');
    transport.turns.single.addError(const TimeoutError());
    await settle();
    final phase = state().phase;
    expect(phase, isA<Failed>());
    expect((phase as Failed).error, isA<TimeoutError>());

    await ctl().retry();
    expect(transport.requests, hasLength(2));
    expect(transport.requests.last.prompt, 'flaky');
    expect(state().messages.where((m) => m.status == MessageStatus.failed), isEmpty);
    expect(state().messages.where((m) => m.role == Role.user), hasLength(1));
  });

  test('@mention routes one message to another model and records it', () async {
    await settle();
    final defaultModel = state().model;
    await ctl().send('@claude summarize this');
    final request = transport.requests.single;
    expect(request.model.provider, ModelProvider.anthropic);
    expect(request.prompt, 'summarize this');
    expect(state().messages.last.model, request.model.id);
    expect(state().model, defaultModel, reason: 'override is one-shot');
  });

  test('tool calls keep their place among text; sources append; reasoning and session are kept', () async {
    await settle();
    await ctl().send('quiz me');
    expect(transport.requests.single.conversationId, id);
    final turn = transport.turns.single
      ..add(const ReasoningDelta('Plan a quiz.'))
      ..add(SourcesFound([Source(url: Uri.parse('https://a.dev'), title: 'A')]))
      ..add(const TextDelta("Here's a quiz."))
      ..add(const UiToolCall(id: 't1', name: 'make_quiz', argumentsJson: '{"title":"Q","questions":[]}'))
      ..add(const ToolProgress(id: 't2', name: 'web_fetch', status: ToolRunStatus.running, detail: 'https://b.dev/x'));
    await settle();
    expect(state().liveParts, hasLength(2)); // the text before the call, then the call
    expect(state().streamingText, isEmpty);
    expect(state().toolStatus, 'Reading b.dev…');
    turn
      ..add(SourcesFound([Source(url: Uri.parse('https://b.dev'), title: 'B')]))
      ..add(const TextDelta('Good luck [2]'))
      ..add(const FollowUpsSuggested(['More?']))
      ..add(const TurnDone());
    unawaited(turn.close());
    await settle();

    final parts = state().messages.last.parts;
    expect(parts.map((p) => p.runtimeType.toString()), [
      'ReasoningPart',
      'SourcesPart',
      'TextPart',
      'ToolCallPart',
      'TextPart',
      'FollowUpsPart',
    ]);
    expect(state().messages.last.sources.map((s) => s.title), ['A', 'B']);
    expect((parts[3] as ToolCallPart).callId, 't1');
    expect(state().toolStatus, isEmpty);

    // Round-trips through the database.
    container.invalidate(chatSessionProvider(id));
    container.listen(chatSessionProvider(id), (_, _) {});
    await settle();
    final reloaded = state().messages.last.parts;
    expect(reloaded.whereType<ToolCallPart>().single.toolName, 'make_quiz');
    expect(reloaded.whereType<ReasoningPart>().single.text, 'Plan a quiz.');
  });

  test('a 402 fails the turn with an out-of-credits error', () async {
    await settle();
    await ctl().send('hi');
    transport.turns.single.addError(const HttpStatusError(402, 'Out of credits', code: 'out_of_credits'));
    await settle();
    final phase = state().phase as Failed;
    expect((phase.error as HttpStatusError).outOfCredits, isTrue);
  });

  test('reopening a conversation restores its messages', () async {
    await settle();
    await ctl().send('persist me');
    transport.turns.single
      ..add(const TextDelta('ok'))
      ..add(const TurnDone());
    unawaited(transport.turns.single.close());
    await settle();

    container.invalidate(chatSessionProvider(id));
    container.read(chatSessionProvider(id));
    await settle();
    expect(state().phase, isA<Idle>());
    expect(state().messages.map((m) => m.plainText), ['persist me', 'ok']);
    expect(state().title, 'persist me');
  });

  Future<void> answer(String text) async {
    transport.turns.last
      ..add(TextDelta(text))
      ..add(const TurnDone());
    unawaited(transport.turns.last.close());
    await settle();
  }

  test('regenerate drops the last answer and asks again, optionally with another model', () async {
    await settle();
    await ctl().send('question');
    await answer('first');
    final claude = container.read(modelCatalogProvider).byProvider(ModelProvider.anthropic).first;

    await ctl().regenerate(model: claude);
    expect(transport.requests, hasLength(2));
    expect(transport.requests.last.prompt, 'question');
    expect(transport.requests.last.model, claude);
    await answer('second');

    expect(state().messages.map((m) => m.plainText), ['question', 'second']);
    final stored = await container.read(chatRepositoryProvider).messages(id);
    expect(stored.map((m) => m.plainText), ['question', 'second'], reason: 'old answer deleted from the DB');
  });

  test('editAndResend replaces the message and everything after it', () async {
    await settle();
    await ctl().send('one');
    await answer('a1');
    await ctl().send('two');
    await answer('a2');

    final first = state().messages.first;
    await ctl().editAndResend(first.id, 'one, edited');
    await answer('b1');

    expect(state().messages.map((m) => m.plainText), ['one, edited', 'b1']);
    final stored = await container.read(chatRepositoryProvider).messages(id);
    expect(stored.map((m) => m.plainText), ['one, edited', 'b1']);
  });

  test('mode is sent with the request; sources and follow-ups are stored as parts', () async {
    await settle();
    ctl().setMode(ChatMode.search);
    await ctl().send('latest news');
    expect(transport.requests.single.mode, ChatMode.search);

    final source = Source(url: Uri.parse('https://example.com/a'), title: 'Example');
    transport.turns.single.add(SourcesFound([source]));
    await settle();
    expect(state().liveSources, hasLength(1), reason: 'sources show before text arrives');

    transport.turns.single
      ..add(const TextDelta('Answer [1]'))
      ..add(const FollowUpsSuggested(['And then?']))
      ..add(const TurnDone());
    unawaited(transport.turns.single.close());
    await settle();

    final last = state().messages.last;
    expect(last.parts.map((p) => p.runtimeType), [SourcesPart, TextPart, FollowUpsPart]);
    expect(state().liveSources, isEmpty);

    container.invalidate(chatSessionProvider(id));
    container.read(chatSessionProvider(id));
    await settle();
    final reloaded = state().messages.last;
    expect(reloaded.sources.single.url, source.url);
    expect((reloaded.parts.last as FollowUpsPart).questions, ['And then?']);
  });
}
