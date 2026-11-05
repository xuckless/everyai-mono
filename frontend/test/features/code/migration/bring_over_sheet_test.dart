import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/domain/mcp_servers.dart';
import 'package:every_ai/features/code/migration/migration_providers.dart';
import 'package:every_ai/features/code/migration/migration_scan.dart';
import 'package:every_ai/features/code/migration/ui/bring_over_sheet.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

ImportItem mcp(String name, {bool checked = true, String? unavailable, String? scope}) => ImportItem(
  kind: ImportKind.mcp,
  source: 'Cursor',
  title: name,
  scope: scope,
  detail: 'npx $name',
  checked: checked,
  unavailable: unavailable,
  mcp: McpServer(name: name, command: 'npx'),
);

Finder row(String name) => find.byKey(ValueKey('bring-over.row.mcp.Cursor.null.$name'));

void main() {
  late List<List<ImportItem>> applied;

  Future<void> open(WidgetTester tester, List<ImportItem> items) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    applied = [];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          preferencesProvider.overrideWithValue(Preferences.inMemory()),
          migrationScanProvider.overrideWith((ref) async => items),
          importApplierProvider.overrideWithValue((chosen, {skills}) async {
            applied.add(chosen);
            return [for (final i in chosen) '${i.title}: imported.'];
          }),
        ],
        child: m.MaterialApp(
          builder: (context, child) =>
              EveryThemeScope(theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light), child: child!),
          home: const m.Material(child: BringOverSheet()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('flagged rows start unticked, Import is off at zero and writes nothing before the click', (tester) async {
    await open(tester, [
      mcp('safe'),
      mcp('risky', checked: false),
      mcp('blocked', unavailable: 'Blocked: sudo'),
      const ImportItem(
        kind: ImportKind.rule,
        source: 'Gemini CLI',
        title: 'GEMINI.md',
        detail: 'EveryAI does not read it.',
      ),
    ]);
    expect(find.text('Import selected (1)'), findsOneWidget);
    expect(find.text('Blocked: sudo'), findsOneWidget);
    expect(find.text('EveryAI does not read it.'), findsOneWidget);
    expect(applied, isEmpty);

    await tester.tap(row('safe'));
    await tester.pump();
    expect(find.text('Import selected (0)'), findsOneWidget);
    await tester.tap(find.text('Import selected (0)'), warnIfMissed: false);
    await tester.pump();
    expect(applied, isEmpty, reason: 'disabled at zero');

    // A row that cannot be brought over does not toggle.
    await tester.tap(row('blocked'));
    await tester.pump();
    expect(find.text('Import selected (0)'), findsOneWidget);

    await tester.tap(row('risky'));
    await tester.pump();
    expect(find.text('Import selected (1)'), findsOneWidget);
  });

  testWidgets('Import sends the ticked rows and shows a line for each', (tester) async {
    await open(tester, [mcp('safe'), mcp('risky', checked: false)]);
    await tester.tap(row('risky'));
    await tester.pump();
    await tester.tap(find.text('Import selected (2)'));
    await tester.pumpAndSettle();
    expect(applied.single.map((i) => i.title), ['safe', 'risky']);
    expect(find.text('safe: imported.'), findsOneWidget);
    expect(find.text('risky: imported.'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
  });

  testWidgets('with nothing found it says so and still links to earlier sessions', (tester) async {
    await open(tester, const []);
    expect(find.text('No MCP servers, commands, agents or skills found.'), findsOneWidget);
    expect(find.byKey(const ValueKey('bring-over.sessions')), findsOneWidget);
  });
}
