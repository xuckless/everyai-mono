import 'dart:io';

import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/gateway_key.dart';
import 'package:every_ai/features/local_models/data/local_http.dart';
import 'package:every_ai/core/local_backend/local_backend.dart';
import 'package:every_ai/core/process/process_model.dart';
import 'package:every_ai/core/local_backend/local_backend_providers.dart';
import 'package:every_ai/features/local_models/local_model_bridge.dart' show localDetectionProvider;
import 'package:every_ai/features/local_models/local_models_providers.dart';
import 'package:every_ai/features/local_models/ui/local_models_section.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

import 'fakes.dart';

final class _MemoryStore implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

const _tags = '{"models":[{"name":"qwen3.5:4b","size":3400000000}]}';
const _show = '{"capabilities":["completion","tools","vision"],"model_info":{"qwen35.context_length":262144}}';

Map<String, LocalReply> _ollamaRunning() => {
  'GET 127.0.0.1:11434/api/version': json('{"version":"0.21.0"}'),
  'GET 127.0.0.1:11434/api/tags': json(_tags),
  'POST 127.0.0.1:11434/api/show#qwen3.5:4b': json(_show),
};

Widget _app(List<Override> overrides, {Preferences? prefs}) => ProviderScope(
  overrides: [
    preferencesProvider.overrideWithValue(prefs ?? Preferences.inMemory()),
    bundledCatalogueProvider.overrideWith((ref) async => File('assets/local_models.json').readAsStringSync()),
    secretStoreProvider.overrideWithValue(_MemoryStore()),
    localDetectionProvider.overrideWithValue(true),
    localBackendProvider.overrideWithValue(_NoBackend()),
    ...overrides,
  ],
  child: m.MaterialApp(
    builder: (context, c) =>
        EveryThemeScope(theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light), child: c!),
    home: const m.Material(child: LocalModelsSection()),
  ),
);

final class _NoBackend implements LocalBackend {
  @override
  Future<LocalBackendInfo?> ensureStarted() async => null;
  @override
  BackendPhase get phase => const BackendUnavailable('test');
  @override
  String? get problem => 'test';
  @override
  bool get running => false;
  @override
  Future<KillOutcome> stop() async => const Ended([]);
  @override
  Future<KillOutcome> close({Duration unloadWithin = const Duration(seconds: 4)}) async => const Ended([]);
}

void main() {
  Future<void> big(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('a 16 GB Mac with Ollama running: the spec line, Balanced picked, the installed model', (tester) async {
    await big(tester);
    final http = FakeLocalHttp(_ollamaRunning());
    await tester.pumpWidget(
      _app([localHttpProvider.overrideWithValue(http), localSystemProvider.overrideWithValue(FakeLocalSystem())]),
    );
    await tester.pumpAndSettle();
    expect(find.text('This Mac: M2 Pro · 16 GB unified · 212 GB free'), findsOneWidget);
    expect(find.text('Fits best'), findsOneWidget);
    expect(find.textContaining('11 GB usable here'), findsOneWidget);
    expect(find.byKey(const ValueKey('local.server.ollama')), findsOneWidget);
    expect(find.text('qwen3.5:4b'), findsOneWidget);
    expect(find.text('Download Balanced'), findsOneWidget);

    // Light is installed already: picking it says so.
    await tester.tap(find.byKey(const ValueKey('local.pack.light')));
    await tester.pumpAndSettle();
    expect(find.text('Light is ready'), findsOneWidget);

    // Best doesn't fit: tapping it changes nothing.
    await tester.tap(find.byKey(const ValueKey('local.pack.best')));
    await tester.pumpAndSettle();
    expect(find.text('Light is ready'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('local.pack.balanced')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download Balanced'));
    await tester.pump();
    expect(http.calls, contains('PULL qwen3.5:9b'));
    expect(find.byKey(const ValueKey('local.download.qwen3.5:9b')), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Download again to carry on'), findsOneWidget);
  });

  testWidgets('Ollama installed but stopped: Start; missing: Set up Ollama', (tester) async {
    await big(tester);
    final system = FakeLocalSystem(ollama: '/opt/homebrew/bin/ollama');
    final http = FakeLocalHttp();
    // Once launched, it answers.
    system.onLaunch = (id, _) => http.replies.addAll(_ollamaRunning());
    await tester.pumpWidget(
      _app([localHttpProvider.overrideWithValue(http), localSystemProvider.overrideWithValue(system)]),
    );
    await tester.pumpAndSettle();
    expect(find.text('Installed, not running · 127.0.0.1:11434'), findsOneWidget);
    expect(find.text('Start Ollama'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('local.server.ollama.start')));
    await tester.pump(const Duration(seconds: 11));
    await tester.pumpAndSettle();
    expect(system.ollamaStarts, 1);
    expect(find.text('Running · started by EveryAI · 127.0.0.1:11434'), findsOneWidget);

    // Stop ends the process EveryAI started; nothing answers any more.
    http.replies.clear();
    await tester.tap(find.byKey(const ValueKey('local.server.ollama.stop')));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(system.owns('ollama'), isFalse);
    expect(find.byKey(const ValueKey('local.server.ollama.start')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      _app([
        localHttpProvider.overrideWithValue(FakeLocalHttp()),
        localSystemProvider.overrideWithValue(FakeLocalSystem()),
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.text('Set up Ollama to download'), findsOneWidget);
    expect(find.byKey(const ValueKey('local.none')), findsOneWidget);
  });

  testWidgets("Apple's model: Set up until the terms are agreed, then started and listed", (tester) async {
    await big(tester);
    await tester.pumpWidget(
      _app([
        localHttpProvider.overrideWithValue(FakeLocalHttp()),
        localSystemProvider.overrideWithValue(FakeLocalSystem(fm: const FmStatus(FmState.needsLicence))),
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.text("Agree to Apple's terms once to use it"), findsOneWidget);
    expect(find.byKey(const ValueKey('local.fm.setup')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    final http = FakeLocalHttp({
      'GET 127.0.0.1:4567/health': json('{"status":"ok"}'),
      'GET 127.0.0.1:4567/v1/models': json('{"data":[{"id":"system"}]}'),
    });
    await tester.pumpWidget(
      _app([
        localHttpProvider.overrideWithValue(http),
        localSystemProvider.overrideWithValue(FakeLocalSystem(fm: const FmStatus(FmState.ready), fmPort: 4567)),
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.text('Ready · free and private, on this Mac'), findsOneWidget);
    expect(find.text('system'), findsOneWidget);
    expect(find.textContaining('~4K context'), findsOneWidget);
  });

  testWidgets('adding a server by URL: Test, Add, kept in prefs with the key in the keychain', (tester) async {
    await big(tester);
    final prefs = Preferences.inMemory();
    final http = FakeLocalHttp({'GET 10.0.0.5:8000/v1/models': json('{"data":[{"id":"big-model"}]}')});
    await tester.pumpWidget(
      _app([
        localHttpProvider.overrideWithValue(http),
        localSystemProvider.overrideWithValue(FakeLocalSystem()),
      ], prefs: prefs),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('local.add-server')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(of: find.byKey(const ValueKey('local.add.url')), matching: find.byType(EditableText)),
      '10.0.0.5:8000',
    );
    await tester.enterText(
      find.descendant(of: find.byKey(const ValueKey('local.add.key')), matching: find.byType(EditableText)),
      'sk-1',
    );
    await tester.tap(find.byKey(const ValueKey('local.add.test')));
    await tester.pumpAndSettle();
    expect(find.text('It answered with 1 model'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('local.add.save')));
    await tester.pumpAndSettle();
    expect(prefs[ManualServers.prefsKey], contains('http://10.0.0.5:8000/v1'));
    expect(find.byKey(const ValueKey('local.server.custom:1')), findsOneWidget);
    expect(find.text('big-model'), findsOneWidget);
  });

  testWidgets("a test's result goes away when the URL changes", (tester) async {
    await big(tester);
    final http = FakeLocalHttp({'GET 10.0.0.5:8000/v1/models': json('{"data":[{"id":"big-model"}]}')});
    await tester.pumpWidget(
      _app([localHttpProvider.overrideWithValue(http), localSystemProvider.overrideWithValue(FakeLocalSystem())]),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('local.add-server')));
    await tester.pumpAndSettle();
    final url = find.descendant(of: find.byKey(const ValueKey('local.add.url')), matching: find.byType(EditableText));
    await tester.enterText(url, '10.0.0.5:8000');
    await tester.tap(find.byKey(const ValueKey('local.add.test')));
    await tester.pumpAndSettle();
    expect(find.text('It answered with 1 model'), findsOneWidget);
    await tester.enterText(url, 'not a url');
    await tester.pump();
    expect(find.byKey(const ValueKey('local.add.result')), findsNothing);
  });

  test('two adds at once get their own ids', () async {
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(Preferences.inMemory()),
        secretStoreProvider.overrideWithValue(_MemoryStore()),
      ],
    );
    addTearDown(container.dispose);
    final servers = container.read(manualServersProvider.notifier);
    final added = await Future.wait([
      servers.add(baseUrl: 'http://10.0.0.5:8000', apiKey: 'a'),
      servers.add(baseUrl: 'http://10.0.0.6:8000', apiKey: 'b'),
    ]);
    expect(added.map((s) => s!.id).toSet(), hasLength(2));
    expect(container.read(manualServersProvider), hasLength(2));
  });
}
