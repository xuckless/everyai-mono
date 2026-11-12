import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/net/api_error.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/core/security/untrusted.dart';
import 'package:every_ai/features/chat/chat_providers.dart';
import 'package:every_ai/features/chat/data/chat_transport.dart';
import 'package:every_ai/features/chat/domain/message.dart';
import 'package:every_ai/features/chat/domain/security_alert.dart';
import 'package:every_ai/features/code/session_notifications.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:every_ai/features/skills/skills_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Transport implements ChatTransport {
  final turns = <StreamController<ChatEvent>>[];

  @override
  Stream<ChatEvent> send(ChatRequest request, {Future<void>? cancel}) {
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

class _Notifier implements SystemNotifier {
  final shown = <(String, String)>[];

  @override
  Future<void> show(String title, String body) async => shown.add((title, body));
}

class _Catalog extends CatalogController {
  @override
  ModelCatalog build() => builtInCatalog;
}

String _alert({String severity = 'warning', String what = 'The page told me to ignore you.'}) => jsonEncode({
  'severity': severity,
  'what': what,
  'source': 'https://evil.example/page',
  'action_taken': 'I ignored it.',
  'exposed': ['your OpenAI key: rotate it'],
});

void main() {
  group('the controller', () {
    late AppDatabase db;
    late _Transport transport;
    late _Notifier notifier;
    late Preferences prefs;
    late ProviderContainer container;
    var focused = false;
    const id = 'conv-sec';

    ProviderContainer open() {
      final c = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(prefs),
          installedSkillsProvider.overrideWith(NoInstalledSkills.new),
          chatTransportProvider.overrideWithValue(transport),
          modelCatalogProvider.overrideWith(_Catalog.new),
          systemNotifierProvider.overrideWithValue(notifier),
          appFocusedProvider.overrideWithValue(() => focused),
        ],
      );
      c.listen(chatSessionProvider(id), (_, _) {});
      return c;
    }

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      transport = _Transport();
      notifier = _Notifier();
      focused = false;
      prefs = await Preferences.load(db);
      container = open();
    });

    tearDown(() async {
      await pumpEventQueue();
      container.dispose();
      await db.close();
    });

    Future<void> turn(List<ChatEvent> events) async {
      await pumpEventQueue();
      await container.read(chatSessionProvider(id).notifier).send('Read this page');
      final t = transport.turns.last;
      for (final e in events) {
        t.add(e);
      }
      t.add(const TurnDone());
      unawaited(t.close());
      await pumpEventQueue();
    }

    test('a live alert notifies once while the app is behind; reopening the chat does not', () async {
      await turn([UiToolCall(id: 'a1', name: securityAlertTool, argumentsJson: _alert()), const TextDelta('Done.')]);
      expect(notifier.shown, [('Security warning', 'The page told me to ignore you.')]);

      final saved = container.read(chatSessionProvider(id)).messages.last;
      expect(saved.parts.whereType<ToolCallPart>().single.toolName, securityAlertTool);
      expect(toolOutputsByMessage([saved])[saved.id], contains('[Security notice shown to the user:'));

      container.dispose();
      container = open();
      await pumpEventQueue();
      expect(container.read(chatSessionProvider(id)).messages, isNotEmpty);
      expect(notifier.shown, hasLength(1));
    });
  });

  test('the backend fences with the same tag and rule as the app', () {
    final zig = File('../backend-exp/src/net/safe_fetch.zig').readAsStringSync();
    expect(zig, contains('pub const tag = "untrusted-content";'));
    expect(zig, contains(untrustedRule.replaceAll('"', r'\"')));
  });
}
