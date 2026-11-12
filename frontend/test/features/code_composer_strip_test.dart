import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:every_ai/features/code/drivers/detection/desktop_apps.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/agent_models.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/drivers/claude/claude_wire.dart' show claudeModes;
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:every_ai/features/code/settings/agent_prompt.dart' show HarnessTier;
import 'package:every_ai/features/code/ui/agent_menu.dart';
import 'package:every_ai/features/code/ui/code_composer.dart';
import 'package:every_ai/features/code/workflows/workflow_picker.dart' show WorkflowPick;
import 'package:every_ai/features/models/models_providers.dart';
import 'package:every_ai/features/skills/skills_providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

import '../support/fake_leads.dart';

const _project = '/work/app';

final class _Skills extends NoInstalledSkills {
  _Skills(this.skills);
  final List<InstalledSkill> skills;

  @override
  Future<List<InstalledSkill>> build() async => skills;
}

void main() {
  late AppDatabase db;
  late Preferences prefs;
  final harnesses = <String>[];
  final modes = <AgentMode>[];

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    prefs = Preferences.inMemory({
      'code.projects': jsonEncode([
        {'id': 'p1', 'name': 'app', 'path': _project},
      ]),
    });
    harnesses.clear();
    modes.clear();
  });
  tearDown(() => db.close());

  AgentMenu menu({
    String harness = 'everyai',
    bool switchable = true,
    WorkflowPick? workflow,
    ValueChanged<WorkflowPick?>? onWorkflow,
  }) => AgentMenu(
    harness: harness,
    onHarness: switchable ? harnesses.add : null,
    model: harness == 'everyai' ? 'anthropic/claude-opus-5.5' : '',
    effort: harness == 'everyai' ? 'medium' : '',
    onChanged: (_, _) {},
    level: HarnessTier.efficient,
    onLevel: (_) {},
    workflow: workflow,
    onWorkflow: onWorkflow ?? (_) {},
  );

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    AgentMenu? agent,
    List<InstalledSkill> skills = const [],
    bool native = false,
    dynamic Function(String, List<Object>)? onSend,
  }) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(prefs),
          modelCatalogProvider.overrideWith(FixedCatalog.new),
          agentCatalogProvider.overrideWithBuild((ref, _) => AgentCatalog.builtIn),
          installedSkillsProvider.overrideWith(() => _Skills(skills)),
          driverRegistryProvider.overrideWithValue(
            DriverRegistry({
              'everyai': FakeLeadDriver('everyai', label: 'EveryAI'),
              'alpha': FakeLeadDriver('alpha', label: 'Alpha CLI'),
            }),
          ),
          driverStatusesProvider.overrideWith(
            () => DriverStatuses(scanApps: _noApps, loadShell: () async {}, reloadShell: () async {}),
          ),
        ],
        child: m.MaterialApp(
          builder: (context, child) =>
              EveryThemeScope(theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light), child: child!),
          home: m.Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                width: 900,
                child: CodeComposer(
                  busy: false,
                  mode: AgentMode.ask,
                  onModeChanged: modes.add,
                  onSend: onSend ?? (_, _) {},
                  project: _project,
                  agent: agent,
                  nativeModes: native ? claudeModes(autoMode: false) : null,
                  nativeMode: native ? 'default' : null,
                  harnessLabel: native ? 'Claude Code' : '',
                  onNativeModeChanged: native ? (_) {} : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(tester.element(find.byType(CodeComposer)));
  }

  group('sending', () {
    Future<void> send(WidgetTester tester, String text) async {
      await tester.enterText(find.byType(EditableText), text);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('send')));
      await tester.pump();
    }

    String draft(WidgetTester tester) => tester.widget<EditableText>(find.byType(EditableText)).controller.text;

    testWidgets('a refused send puts the text back', (tester) async {
      final sent = <String>[];
      final answer = Completer<bool>();
      await pump(
        tester,
        agent: menu(),
        onSend: (t, _) {
          sent.add(t);
          return answer.future;
        },
      );
      await send(tester, 'build the thing');
      expect(sent, ['build the thing']);
      // Cleared at once while the send runs.
      expect(draft(tester), isEmpty);
      answer.complete(false);
      await tester.pump();
      expect(draft(tester), 'build the thing');
    });

    testWidgets('a refused send leaves a newer draft alone', (tester) async {
      final answer = Completer<bool>();
      await pump(tester, agent: menu(), onSend: (_, _) => answer.future);
      await send(tester, 'first');
      await tester.enterText(find.byType(EditableText), 'second');
      answer.complete(false);
      await tester.pump();
      expect(draft(tester), 'second');
    });
  });
}

Future<AppScan> _noApps() async => const AppScan();
