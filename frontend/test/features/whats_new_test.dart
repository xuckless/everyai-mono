import 'package:every_ai/core/config/version.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/updates/domain/whats_new.dart';
import 'package:every_ai/features/updates/ui/whats_new_dialog.dart';
import 'package:every_ai/features/updates/whats_new_providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

const _long =
    'Commands that take three seconds or more are timed on every harness and kept per project, so every lead sees '
    'the slow ones in its briefing, marked as recorded data, and a profiles file a repository ships is ignored. '
    'A path with no spaces: /Users/someone/Library/Application-Support/dev.alidirect.everyai/agent-server/workspace/'
    'conversations/0123456789abcdef0123456789abcdef/events.jsonl';

final _note = ReleaseNote(
  version: appVersion,
  date: 'Nov 7',
  title: 'A cheaper execution loop, and a headline long enough that it has to wrap onto a second line',
  items: [
    for (var i = 0; i < 12; i++)
      WhatsNewItem('Change $i with a headline that runs on for a while before it stops, to test wrapping', _long),
    const WhatsNewItem('A headline alone'),
  ],
);

ProviderContainer _container(Map<String, String> prefs, List<ReleaseNote> notes) {
  final c = ProviderContainer(
    overrides: [
      preferencesProvider.overrideWithValue(Preferences.inMemory(prefs)),
      releaseNotesProvider.overrideWithValue(notes),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  test('shown once after an update, only when the build has notes', () {
    final updated = _container({'onboarding.accepted': '0.0.9', WhatsNew.key: '0.0.9'}, [_note]);
    expect(updated.read(whatsNewProvider), same(_note));
    updated.read(whatsNewProvider.notifier).markSeen();
    expect(updated.read(whatsNewProvider), isNull);

    expect(_container({WhatsNew.key: appVersion}, [_note]).read(whatsNewProvider), isNull);
    expect(_container({WhatsNew.key: '0.0.9'}, const []).read(whatsNewProvider), isNull);
  });

  for (final size in [const Size(1200, 800), const Size(390, 700)]) {
    testWidgets('long notes wrap and scroll without overflowing (${size.width.toInt()} wide)', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        m.MaterialApp(
          builder: (context, c) =>
              EveryThemeScope(theme: EveryTheme.resolve(DesignLanguage.material, Brightness.dark), child: c!),
          home: m.Material(
            child: Builder(
              builder: (context) => Center(
                child: m.TextButton(onPressed: () => showWhatsNew(context, _note), child: const Text('open')),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text("What's new"), findsOneWidget);
      // The panel keeps a reading width and fits the window; the rest scrolls.
      final panel = tester.getRect(find.byType(WhatsNewBody));
      expect(panel.width, lessThanOrEqualTo(520));
      expect(tester.getRect(find.byKey(const ValueKey('whats-new.close'))).bottom, lessThanOrEqualTo(size.height));
      final last = find.text('A headline alone');
      expect(tester.getRect(last).top, greaterThan(size.height)); // below the fold until scrolled
      await tester.ensureVisible(last);
      await tester.pumpAndSettle();
      expect(tester.getRect(last).bottom, lessThanOrEqualTo(size.height));
      await tester.tap(find.byKey(const ValueKey('whats-new.close')));
      await tester.pumpAndSettle();
      expect(find.text("What's new"), findsNothing);
    });
  }
}
