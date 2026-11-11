import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/core/ui/kit.dart';
import 'package:every_ai/features/code/live/agent_logins.dart';
import 'package:every_ai/features/code/live/browser_jar.dart';
import 'package:every_ai/features/code/ui/logins_settings.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

void main() {
  testWidgets('add a login, switch it off for agents, delete it; the switches are saved', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final tmp = Directory.systemTemp.createTempSync('logins-ui');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final store = AgentLogins(SealedStore('${tmp.path}/s', () async => SecretKey(List.filled(32, 2))));
    final prefs = Preferences.inMemory();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [preferencesProvider.overrideWithValue(prefs)],
        child: m.MaterialApp(
          home: EveryThemeScope(
            theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
            child: m.Material(child: LoginsSettingsBody(store: store)),
          ),
        ),
      ),
    );
    // Real file work (the sealed store) runs outside the test's fake clock.
    Future<void> settle() async {
      for (var i = 0; i < 15; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
        await tester.pumpAndSettle();
      }
    }

    await settle();
    expect(find.text('No logins yet'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('logins.add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('login.name')), 'GitHub');
    await tester.enterText(find.byKey(const ValueKey('login.url')), 'https://github.com/login');
    await tester.enterText(find.byKey(const ValueKey('login.username')), 'ada');
    await tester.enterText(find.byKey(const ValueKey('login.password')), 'hunter2-long');
    await tester.tap(find.byKey(const ValueKey('login.save')));
    await settle();
    expect(find.byKey(const ValueKey('logins.row.github')), findsOneWidget);
    expect(find.textContaining('github.com · ada · •••••'), findsOneWidget);
    expect(find.text('Add a login'), findsNothing);
    expect(find.textContaining('hunter2'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('logins.use.github')));
    await settle();
    expect(store.entries.value.single.agentsCanUse, isFalse);

    final codes = find.descendant(
      of: find.byKey(const ValueKey('logins.switch.${LoginPolicy.prefCodes}')),
      matching: find.byType(KitSwitch),
    );
    await tester.tap(codes);
    await tester.pumpAndSettle();
    expect(prefs[LoginPolicy.prefCodes], '0');

    await tester.tap(find.byKey(const ValueKey('logins.delete.github')));
    await settle();
    expect(store.entries.value, isEmpty);
    expect(find.text('No logins yet'), findsOneWidget);
  });
}
