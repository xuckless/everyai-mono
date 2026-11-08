import 'dart:convert';

import 'package:every_ai/core/net/api_client.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/core/ui/adaptive.dart';
import 'package:every_ai/core/ui/every_icons.dart';
import 'package:every_ai/features/code/automations/ui/webhooks_part.dart';
import 'package:every_ai/features/code/automations/webhook_providers.dart';
import 'package:every_ai/features/code/gateway_key.dart' show SecretStore, secretStoreProvider;
import 'package:every_ai/features/remote/data/remote_api.dart';
import 'package:every_ai/features/remote/data/remote_store.dart';
import 'package:every_ai/features/remote/domain/remote_crypto.dart';
import 'package:every_ai/features/remote/remote_providers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart' as m;
import 'package:web_socket/testing.dart';

final class _MemoryStore implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// The backend's `/v1/hooks` in memory.
final class _Hooks {
  final hooks = <Map<String, Object?>>[];
  final calls = <String>[];

  /// The next create answers 500, once.
  var failCreate = false;

  Future<http.Response> handle(http.Request r) async {
    calls.add('${r.method} ${r.url.path}');
    // Only the host's own token adds or deletes its hooks (registering the host itself needs none yet).
    final registering = r.method == 'POST' && r.url.path == '/v1/remote/hosts';
    if (r.method != 'GET' && !registering && r.headers['X-Remote-Host-Token'] != 'rh_t') {
      return http.Response('{}', 401);
    }
    if (r.method == 'POST' && r.url.path == '/v1/hooks' && failCreate) {
      failCreate = false;
      return http.Response(jsonEncode({'message': 'server down'}), 500);
    }
    if (r.method == 'POST' && r.url.path == '/v1/hooks') {
      final body = jsonDecode(r.body) as Map<String, Object?>;
      final hook = {
        'id': 'hook-${hooks.length + 1}',
        'name': body['name'],
        'host_id': body['host_id'],
        'url': 'https://api.test/v1/hooks/hook-${hooks.length + 1}',
        'created_at': 0,
        'pending': 0,
      };
      hooks.add(hook);
      return http.Response(jsonEncode({...hook, 'secret': 'whk_shown-once'}), 201);
    }
    if (r.method == 'POST' && r.url.path == '/v1/remote/hosts') {
      // Slow enough that a second click lands while the first registers.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return http.Response(jsonEncode({'id': 'host-new', 'host_token': 'rh_new'}), 201);
    }
    if (r.method == 'GET' && r.url.path == '/v1/hooks') return http.Response(jsonEncode(hooks), 200);
    if (r.method == 'DELETE') {
      hooks.removeWhere((h) => r.url.path.endsWith('/${h['id']}'));
      return http.Response('', 204);
    }
    return http.Response('{}', 404);
  }
}

Future<ProviderContainer> _pump(WidgetTester tester, {required bool hosting, required _Hooks api}) async {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final secrets = _MemoryStore();
  if (hosting) {
    final key = await tester.runAsync(RemoteIdentity.generate);
    secrets.values[RemoteStore.hostKey] = jsonEncode(
      HostRegistration(id: 'host-1', name: 'Mac', token: 'rh_t', privateKey: key!.privateKeyBase64).toJson(),
    );
  }
  final prefs = Preferences.inMemory({
    'code.projects': jsonEncode([
      {'id': 'p', 'name': 'app', 'path': '/work/app'},
    ]),
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        secretStoreProvider.overrideWithValue(secrets),
        relayConnectorProvider.overrideWithValue((url, token) async => fakes().$2),
        remoteApiProvider.overrideWithValue(
          RemoteApi(
            ApiClient(baseUrl: Uri.parse('http://api.test/'), client: MockClient(api.handle)),
            authenticated: false,
          ),
        ),
      ],
      child: m.MaterialApp(
        home: EveryThemeScope(
          theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
          child: const m.Material(child: SingleChildScrollView(child: WebhooksPart())),
        ),
      ),
    ),
  );
  // Hosting loads from the (memory) keychain.
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(WebhooksPart)));
}

void main() {
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.macOS);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  testWidgets('with hosting off it asks to turn hosting on', (tester) async {
    await _pump(tester, hosting: false, api: _Hooks());
    expect(find.text('Turn on remote hosting to receive webhooks'), findsOneWidget);
    expect(find.text('Add webhook'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('turning hosting on twice at once registers one host', (tester) async {
    final api = _Hooks();
    final container = await _pump(tester, hosting: false, api: api);
    final hosting = container.read(remoteHostingProvider.notifier);
    await tester.runAsync(() => Future.wait([hosting.enable(), hosting.enable()]));
    await tester.pumpAndSettle();
    expect(api.calls.where((c) => c == 'POST /v1/remote/hosts'), hasLength(1));
    expect(container.read(remoteHostingProvider).enabled, isTrue);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('create shows the URL and secret once; delete calls the backend', (tester) async {
    final api = _Hooks();
    final container = await _pump(tester, hosting: true, api: api);
    expect(find.text('No webhooks yet'), findsOneWidget);
    await tester.tap(find.text('Add webhook'));
    await tester.pumpAndSettle();
    final fields = find.byType(EditableText);
    await tester.enterText(fields.at(0), 'New issues');
    await tester.enterText(fields.at(3), 'Triage {{json.issue.title}}');
    await tester.pump();
    await tester.tap(find.widgetWithText(AdaptiveButton, 'Create'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();

    expect(api.calls, contains('POST /v1/hooks'));
    expect(api.hooks.single['host_id'], 'host-1');
    expect(find.text('whk_shown-once'), findsOneWidget);
    expect(find.text('https://api.test/v1/hooks/hook-1'), findsOneWidget);
    final saved = container.read(webhookAutomationsProvider).single;
    expect(saved.hookId, 'hook-1');
    expect(saved.prompt, 'Triage {{json.issue.title}}');
    expect(saved.effectiveMode.label, 'Auto-edit');

    await tester.tap(find.widgetWithText(AdaptiveButton, 'Done'));
    await tester.pumpAndSettle();
    expect(find.text('whk_shown-once'), findsNothing);
    expect(find.text('New issues'), findsOneWidget);

    await tester.tap(find.byWidgetPredicate((w) => w is AdaptiveIcon && w.icon == EveryIcon.more));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last); // the confirmation
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(api.calls, contains('DELETE /v1/hooks/hook-1'));
    expect(container.read(webhookAutomationsProvider), isEmpty);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a failed create says why until the next action, and the next try clears it', (tester) async {
    final api = _Hooks()..failCreate = true;
    await _pump(tester, hosting: true, api: api);
    await tester.tap(find.text('Add webhook'));
    await tester.pumpAndSettle();
    final fields = find.byType(EditableText);
    await tester.enterText(fields.at(0), 'New issues');
    await tester.enterText(fields.at(3), 'Triage it');
    await tester.pump();
    Future<void> create() async {
      await tester.tap(find.widgetWithText(AdaptiveButton, 'Create'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pumpAndSettle();
    }

    await create();
    expect(find.textContaining("Couldn't create the webhook"), findsOneWidget);
    expect(api.hooks, isEmpty);
    await create();
    expect(find.textContaining("Couldn't create the webhook"), findsNothing);
    expect(find.text('whk_shown-once'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}
