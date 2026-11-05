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
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/ui/code_composer.dart';
import 'package:every_ai/features/code/ui/code_home.dart';
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
    test('text alone goes to chat', () {
      final l = _prompt('everyai://prompt?text=Hello')!;
      expect((l.text, l.mode, l.projectId), ('Hello', PromptTarget.chat, null));
    });

    test('code mode and a project id', () {
      final l = _prompt('everyai://prompt?text=Fix%20it&mode=code&project=p1')!;
      expect((l.text, l.mode, l.projectId), ('Fix it', PromptTarget.code, 'p1'));
    });

    test('decodes percent, plus, unicode and newlines', () {
      expect(_prompt('everyai://prompt?text=a+b%20c')!.text, 'a b c');
      expect(_prompt('everyai://prompt?text=%E2%9C%93%20ok')!.text, '✓ ok');
      expect(_prompt('everyai://prompt?text=one%0Atwo%09x')!.text, 'one\ntwo\tx');
    });

    test('an unknown mode is chat; extra parameters are ignored', () {
      final l = _prompt('everyai://prompt?text=hi&mode=bypass&model=x/y&harness=codex')!;
      expect((l.mode, l.text), (PromptTarget.chat, 'hi'));
    });

    test('empty and blank text are no link', () {
      expect(parseAppLink(Uri.parse('everyai://prompt')), isNull);
      expect(parseAppLink(Uri.parse('everyai://prompt?text=')), isNull);
      expect(parseAppLink(Uri.parse('everyai://prompt?text=%20%0A')), isNull);
    });

    test('other hosts and schemes are no link; pair links are not handled', () {
      expect(parseAppLink(Uri.parse('everyai://pair?c=1&h=2&text=x')), isNull);
      expect(parseAppLink(Uri.parse('https://prompt/?text=x')), isNull);
      expect(parseAppLink(Uri.parse('other://prompt?text=x')), isNull);
    });

    test('control characters are stripped, newline and tab kept', () {
      expect(_prompt('everyai://prompt?text=a%00b%1Bc%0Dd%0Ae%7F')!.text, 'abcd\ne');
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

    test('32 KiB of UTF-8 is the cap', () {
      final ok = Uri(scheme: 'everyai', host: 'prompt', queryParameters: {'text': 'a' * maxPromptLinkBytes});
      expect(parseAppLink(ok), isA<PromptLink>());
      final over = Uri(scheme: 'everyai', host: 'prompt', queryParameters: {'text': 'a' * (maxPromptLinkBytes + 1)});
      expect(parseAppLink(over), isA<OversizedLink>());
      // Counted in bytes, not characters: 11000 three-byte characters are 33000 bytes.
      final wide = Uri(scheme: 'everyai', host: 'prompt', queryParameters: {'text': '✓' * 11000});
      expect(parseAppLink(wide), isA<OversizedLink>());
    });

    test('routes: code only on desktop', () {
      const code = PromptLink(text: 't', mode: PromptTarget.code);
      const chat = PromptLink(text: 't');
      String r(PromptLink l, bool d) => routeForPrompt(l, desktop: d, chat: '/chat', code: '/code');
      expect([r(code, true), r(code, false), r(chat, true), r(chat, false)], ['/code', '/chat', '/chat', '/chat']);
    });
  });

  test('off desktop a code link becomes a chat link; on desktop it stays', () {
    const code = PromptLink(text: 't', mode: PromptTarget.code, projectId: 'p');
    expect(linkForHost(code, desktop: false).mode, PromptTarget.chat);
    expect(linkForHost(code, desktop: false).projectId, isNull);
    expect(linkForHost(code, desktop: true), same(code));
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
    var requests = 0;

    setUp(() {
      requests = 0;
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
                if (r.url.path.contains('chat') || r.url.path.contains('stream')) requests++;
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

    testWidgets('chat home fills the box and sends nothing', (tester) async {
      container.read(pendingPromptProvider.notifier).offer(const PromptLink(text: 'Draft an email'));
      await pump(tester, const ChatScreen(conversationId: 'new'));
      expect(draft(tester), 'Draft an email');
      expect(container.read(pendingPromptProvider), isNull);
      expect(requests, 0);
      await finish(tester);
    });

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

    testWidgets('a link offered to a mounted chat home fills it, after what was typed', (tester) async {
      await pump(tester, const ChatScreen(conversationId: 'new'));
      await tester.enterText(find.byType(EditableText).first, 'my draft');
      container.read(pendingPromptProvider.notifier).offer(const PromptLink(text: 'From link'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(draft(tester), 'my draft\n\nFrom link');
      await finish(tester);
    });

    testWidgets('a code link does not fill the chat box', (tester) async {
      container.read(pendingPromptProvider.notifier).offer(const PromptLink(text: 'x', mode: PromptTarget.code));
      await pump(tester, const ChatScreen(conversationId: 'new'));
      expect(draft(tester), '');
      expect(container.read(pendingPromptProvider), isNotNull);
      await finish(tester);
    });

    testWidgets('Code home picks the project by id and fills the box', (tester) async {
      final notifier = container.read(codeProjectsProvider.notifier);
      notifier.add('/work/one');
      final two = notifier.add('/work/two');
      container
          .read(pendingPromptProvider.notifier)
          .offer(PromptLink(text: 'Fix the bug', mode: PromptTarget.code, projectId: two.id));
      await pump(tester, const CodeHome());
      expect(tester.widget<CodeComposer>(find.byType(CodeComposer)).project, '/work/two');
      expect(draft(tester), 'Fix the bug');
      expect(container.read(codeSessionsProvider), isEmpty);
      await finish(tester);
    });

    testWidgets('an unknown project keeps the default one, with the text', (tester) async {
      final one = container.read(codeProjectsProvider.notifier).add('/work/one');
      container
          .read(pendingPromptProvider.notifier)
          .offer(const PromptLink(text: 'Fix the bug', mode: PromptTarget.code, projectId: 'nope'));
      await pump(tester, const CodeHome());
      expect(tester.widget<CodeComposer>(find.byType(CodeComposer)).project, one.path);
      expect(draft(tester), 'Fix the bug');
      expect(container.read(codeSessionsProvider), isEmpty);
      await finish(tester);
    });
  });
}
