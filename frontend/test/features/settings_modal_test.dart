import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:every_ai/features/settings/reply_language.dart';
import 'package:every_ai/features/settings/settings_registry.dart';
import 'package:every_ai/features/settings/ui/settings_modal.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

class _Catalog extends CatalogController {
  @override
  ModelCatalog build() => builtInCatalog;
}

Future<ProviderContainer> _pump(WidgetTester tester, Size size) async {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        preferencesProvider.overrideWithValue(Preferences.inMemory()),
        modelCatalogProvider.overrideWith(_Catalog.new),
        databaseProvider.overrideWithValue(db),
      ],
      child: m.MaterialApp(
        builder: (context, child) =>
            EveryThemeScope(theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light), child: child!),
        home: m.Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: m.TextButton(
                onPressed: () => showSettings(context, section: SettingsSection.about),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  return ProviderScope.containerOf(tester.element(find.text('open')));
}

void main() {
  group('settings search', () {
    test('finds rows by title, keyword and section, every word', () {
      expect(searchSettings('dark').map((e) => e.anchor), contains('theme'));
      expect(searchSettings('log out').single.anchor, 'sign-out');
      expect(searchSettings('PLANS').map((e) => (e.section, e.anchor)), contains((SettingsSection.billing, 'plans')));
      expect(searchSettings('language reply').single.anchor, 'language');
      expect(searchSettings(''), isEmpty);
      expect(searchSettings('zzz-nothing'), isEmpty);
    });

    test('leaves out sections the host does not have', () {
      final all = searchSettings('permissions', available: (_) => true);
      expect(all.map((e) => e.section), contains(SettingsSection.permissions));
      expect(searchSettings('permissions', available: (s) => !s.desktopOnly), isEmpty);
    });

    test('every anchored entry names its section and a unique anchor', () {
      final seen = <String>{};
      for (final e in settingsEntries) {
        if (e.anchor != null) expect(seen.add('${e.section.name}.${e.anchor}'), isTrue, reason: e.title);
      }
    });
  });

  group('old routes', () {
    SettingsTarget? at(String s) => settingsTargetForLocation(Uri.parse(s));

    test('map to a section, an anchor and arguments', () {
      expect(at('/settings')!.section, SettingsSection.general);
      expect(at('/settings/billing')!.section, SettingsSection.billing);
      expect(at('/settings/mcp')!.section, SettingsSection.mcp);
      expect(at('/settings/remote')!.section, SettingsSection.remote);
      expect(at('/settings/notices')!.anchor, 'notices');
      expect(at('/settings/notices')!.section, SettingsSection.about);
      final code = at('/code/settings?scope=project&project=p1&session=s1&tab=prompt')!;
      expect(code.section, SettingsSection.code);
      expect(code.anchor, 'prompt');
      expect(code.args, {'scope': 'project', 'project': 'p1', 'session': 's1'});
      expect(at('/settings/whatever')!.section, SettingsSection.general);
    });

    test('leave other places alone', () {
      expect(at('/chat/abc'), isNull);
      expect(at('/code'), isNull);
      expect(at('/code/s/1'), isNull);
      expect(at('/settingsx'), isNull);
    });
  });

  test('the reply language is stored, and auto sends nothing', () {
    final prefs = Preferences.inMemory();
    final c = ProviderContainer(overrides: [preferencesProvider.overrideWithValue(prefs)]);
    addTearDown(c.dispose);
    expect(c.read(replyLanguageProvider), ReplyLanguage.auto);
    expect(c.read(replyLanguageProvider.notifier).wire, isNull);
    c.read(replyLanguageProvider.notifier).set('French');
    expect(prefs[ReplyLanguage.key], 'French');
    expect(c.read(replyLanguageProvider.notifier).wire, 'French');
    c.read(replyLanguageProvider.notifier).set(ReplyLanguage.auto);
    expect(prefs[ReplyLanguage.key], isNull);
  });

  testWidgets('the modal opens at a section, search jumps to a row, Esc closes', (tester) async {
    final c = await _pump(tester, const Size(1400, 1000));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(c.read(settingsOpenProvider), isTrue);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings.notices')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings.nav.general')), findsOneWidget);

    await tester.enterText(
      find.descendant(of: find.byKey(const ValueKey('settings.search')), matching: find.byType(EditableText)),
      'reply language',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('settings.result.general.language')));
    await tester.pumpAndSettle();
    expect(find.text('Reply language'), findsWidgets);
    expect(find.byKey(const ValueKey('settings.language')), findsOneWidget);
    // The jump is spent once the row has been shown.
    expect(c.read(settingsTargetProvider)!.anchor, isNull);

    // A second open while showing only jumps.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsNothing);
    expect(c.read(settingsOpenProvider), isFalse);
  });

  testWidgets('narrow windows drill down from the list', (tester) async {
    await _pump(tester, const Size(500, 900));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // Opened at a section: it shows, with a way back to the list.
    expect(find.byKey(const ValueKey('settings.notices')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings.back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings.nav.about')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings.nav.general')));
    await tester.pumpAndSettle();
    expect(find.text('Reply language'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings.close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings.close')), findsNothing);
  });
}
