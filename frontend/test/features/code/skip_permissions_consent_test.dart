import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/ui/skip_permissions_consent.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

void main() {
  late AppDatabase db;
  late Preferences prefs;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    prefs = await Preferences.load(db);
  });
  tearDown(() => db.close());

  testWidgets('Full auto on an outside lead asks once per harness; Cancel leaves the mode as it was', (tester) async {
    var mode = AgentMode.ask;
    late WidgetRef ref;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [preferencesProvider.overrideWithValue(prefs)],
        child: m.MaterialApp(
          builder: (_, child) =>
              EveryThemeScope(theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light), child: child!),
          home: m.Material(
            child: Consumer(
              builder: (context, r, _) {
                ref = r;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      ),
    );
    final context = tester.element(find.byType(SizedBox).last);
    SkipPermissionsConsent consent() => ref.read(skipPermissionsProvider.notifier).of('claude-code');

    Future<void> pick(AgentMode m) async {
      if (await confirmSkipPermissions(context, ref, harness: 'claude-code', lead: 'Claude Code', mode: m)) mode = m;
    }

    // Not a skip-permissions mode: nothing asks.
    await pick(AgentMode.autoEdit);
    await tester.pumpAndSettle();
    expect(mode, AgentMode.autoEdit);
    expect(find.text('Run Claude Code without asking?'), findsNothing);

    var picking = pick(AgentMode.fullAuto);
    await tester.pumpAndSettle();
    expect(find.text(skipPermissionsText('Claude Code')), findsOneWidget);
    expect(consent(), SkipPermissionsConsent.asking);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await picking;
    expect(mode, AgentMode.autoEdit, reason: 'Cancel applies nothing');
    expect(consent(), SkipPermissionsConsent.refusedThisTime);

    picking = pick(AgentMode.bypass);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await picking;
    expect(mode, AgentMode.bypass);
    expect(consent(), SkipPermissionsConsent.allowed);
    expect(prefs[SkipPermissions.key], '["claude-code"]');

    // Agreed: not asked again for this harness; another harness asks on its own.
    mode = AgentMode.ask;
    await pick(AgentMode.fullAuto);
    await tester.pumpAndSettle();
    expect(mode, AgentMode.fullAuto);
    expect(ref.read(skipPermissionsProvider.notifier).of('codex'), SkipPermissionsConsent.unasked);

    // Ask again (Settings): back to unasked, and kept that way.
    ref.read(skipPermissionsProvider.notifier).reset('claude-code');
    expect(consent(), SkipPermissionsConsent.unasked);
    expect(prefs[SkipPermissions.key], '[]');
  });

  test("Full auto and Bypass say they are an outside lead's own mode", () {
    expect(AgentMode.fullAuto.descriptionOn(null), AgentMode.fullAuto.description);
    expect(AgentMode.bypass.descriptionOn('Codex'), contains("Codex's own skip-permissions mode"));
    expect(AgentMode.ask.descriptionOn('Codex'), AgentMode.ask.description);
  });
}
