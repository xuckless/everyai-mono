import 'dart:io';

import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/drivers/acp/acp_driver.dart';
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:every_ai/features/code/drivers/registry_install/acp_registry.dart';
import 'package:every_ai/features/code/drivers/registry_install/installed_agents.dart';
import 'package:every_ai/features/code/drivers/registry_install/ui/add_agent_list.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart' as m;

final _fixture = File('test/fixtures/drivers/acp_registry/registry.json').readAsStringSync();

void main() {
  late Preferences prefs;
  late int rescans;
  late ProviderContainer c;
  var fetched = false;

  setUp(() {
    prefs = Preferences.inMemory();
    rescans = 0;
    fetched = false;
    c = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        driverRegistryProvider.overrideWithValue(
          DriverRegistry({'gemini': AcpDriver(id: 'gemini', label: 'Gemini CLI', command: 'gemini')}),
        ),
        rescanHarnessesProvider.overrideWithValue((_) => rescans++),
        acpRegistryClientProvider.overrideWithValue(
          AcpRegistryClient(prefs, client: MockClient((_) async => http.Response(_fixture, 200))),
        ),
        agentInstallerProvider.overrideWithValue(
          AgentInstaller(
            client: MockClient((_) async {
              fetched = true;
              return http.Response('', 404);
            }),
            dataDir: () async => '/nonexistent',
            platform: () => 'darwin-aarch64',
            makeDir: (_) async {},
          ),
        ),
        agentRunnersProvider.overrideWith((ref) async => {DistKind.npx: false, DistKind.uvx: true}),
      ],
    );
    addTearDown(c.dispose);
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.runAsync(() async {
      await c.read(acpRegistryProvider.future);
      await c.read(agentRunnersProvider.future);
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: m.MaterialApp(
          home: EveryThemeScope(
            theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
            child: const m.Scaffold(body: SingleChildScrollView(child: AddAgentList())),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a download without a checksum asks before installing', (tester) async {
    await pump(tester);
    expect(find.text('Cursor'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('add-agent.cursor.install')));
    await tester.pump();
    expect(find.byKey(const ValueKey('add-agent.cursor.unchecked')), findsOneWidget);
    expect(fetched, isFalse);
    await tester.tap(find.byKey(const ValueKey('add-agent.cursor.cancel')));
    await tester.pump();
    expect(find.byKey(const ValueKey('add-agent.cursor.unchecked')), findsNothing);
  });
}
