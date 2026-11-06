import 'dart:convert';

import 'package:drift/native.dart';
import 'package:every_ai/app/shell.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/net/api_client.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/environments/environment_providers.dart';
import 'package:every_ai/features/code/environments/exec_env.dart';
import 'package:every_ai/features/code/ui/code_home.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../../layout/layout_host.dart';
import 'env_fakes.dart';

// The new-session page: where it runs is a part of the line under the box and changes the project.

void main() {
  testWidgets('the Runs in chip shows the project\'s environment and picking one updates the project', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    final db = AppDatabase(NativeDatabase.memory());
    final prefs = Preferences.inMemory({
      'code.projects': jsonEncode([
        {'id': 'p1', 'name': 'app', 'path': '/work/app'},
      ]),
    });
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(prefs),
        apiClientProvider.overrideWithValue(
          ApiClient(baseUrl: Uri.parse('http://backend/'), client: MockClient((_) async => http.Response('no', 599))),
        ),
        environmentsProvider.overrideWith((ref) async => [HostEnv.instance, FakeEnv()]),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: LayoutHost(
          language: DesignLanguage.material,
          child: ShellScope(sidebarVisible: true, compact: false, toggleSidebar: () {}, child: const CodeHome()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('This computer'), findsOneWidget);

    await tester.tap(find.text('This computer'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('environment.wsl:Ubuntu')));
    await tester.pumpAndSettle();
    expect(container.read(codeProjectsProvider).single.environment, 'wsl:Ubuntu');
    expect(find.text('Ubuntu (WSL)'), findsOneWidget);
    expect(tester.takeException(), isNull);
    // Pollers the page started run out before the test ends.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 10));
    debugDefaultTargetPlatformOverride = null;
    tester.view.reset();
    await tester.runAsync(() async {
      container.dispose();
      await db.close();
    });
  });
}
