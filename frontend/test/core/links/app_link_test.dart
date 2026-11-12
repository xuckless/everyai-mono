import 'dart:convert';

import 'package:drift/native.dart';
import 'package:every_ai/app/shell.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/links/app_link.dart';
import 'package:every_ai/core/links/link_providers.dart';
import 'package:every_ai/core/net/api_client.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/chat/ui/chat_screen.dart';
import 'package:every_ai/features/code/gateway_key.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../layout/layout_host.dart';

final class _Store implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

PromptLink? _prompt(String uri) => switch (parseAppLink(Uri.parse(uri))) {
  final PromptLink l => l,
  _ => null,
};

void main() {
  group('parseAppLink', () {
    test('decodes percent, plus, unicode and newlines', () {
      expect(_prompt('everyai://prompt?text=a+b%20c')!.text, 'a b c');
      expect(_prompt('everyai://prompt?text=%E2%9C%93%20ok')!.text, '✓ ok');
      expect(_prompt('everyai://prompt?text=one%0Atwo%09x')!.text, 'one\ntwo\tx');
    });

    test('invisible and bidi characters, C1 controls and tag characters are stripped', () {
      final hidden = String.fromCharCodes([0x200B, 0x202E, 0x2066, 0xFEFF, 0x85, 0xE0041, 0xE0042, 0xE007F]);
      final uri = Uri(scheme: 'everyai', host: 'prompt', queryParameters: {'text': 'Fix${hidden}it'});
      expect(parseAppLink(uri), isA<PromptLink>().having((l) => l.text, 'text', 'Fixit'));
      // Only hidden characters is no text at all.
      expect(parseAppLink(Uri(scheme: 'everyai', host: 'prompt', queryParameters: {'text': hidden})), isNull);
    });

    test('bad percent-encoded UTF-8 is no link, not a throw', () {
      expect(parseAppLink(Uri.parse('everyai://prompt?text=a%FFb')), isNull);
      expect(parseAppLink(Uri.parse('everyai://prompt?text=%E0%A4')), isNull);
    });
  });

  test('a pending prompt is taken once; a newer link replaces it', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final n = c.read(pendingPromptProvider.notifier);
    n.offer(const PromptLink(text: 'one'));
    n.offer(const PromptLink(text: 'two'));
    expect(n.take()?.text, 'two');
    expect(n.take(), isNull);
    expect(c.read(pendingPromptProvider), isNull);
  });

  group('consumers', () {
    late AppDatabase db;
    late ProviderContainer container;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(Preferences.inMemory()),
          secretStoreProvider.overrideWithValue(_Store()),
          apiClientProvider.overrideWithValue(
            ApiClient(
              baseUrl: Uri.parse('http://backend/'),
              client: MockClient((r) async {
                return http.Response(jsonEncode({}), 599);
              }),
            ),
          ),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    Future<void> pump(WidgetTester tester, Widget screen) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: LayoutHost(
            language: DesignLanguage.cupertino,
            child: ShellScope(sidebarVisible: true, compact: false, toggleSidebar: () {}, child: screen),
          ),
        ),
      );
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    /// Debounces, pollers and the toast's timer run out once the screen is gone.
    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(minutes: 10));
    }

    String draft(WidgetTester tester) => tester.widget<EditableText>(find.byType(EditableText).first).controller.text;

    testWidgets('a link offered after the screen changed lands in the new screen, not the old one', (tester) async {
      Future<void> show(String id) => pump(tester, ChatScreen(key: ValueKey(id), conversationId: id));
      await show('a');
      await show('b'); // the shell went to a new chat
      container.read(pendingPromptProvider.notifier).offer(const PromptLink(text: 'Hello'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(draft(tester), 'Hello');
      await finish(tester);
    });
  });
}
