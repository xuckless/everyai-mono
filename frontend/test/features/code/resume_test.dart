import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/net/api_client.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/drivers/acp/acp_mapping.dart' show agentMessageEvent, userMessageEvent;
import 'package:every_ai/features/code/drivers/driver.dart';
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:every_ai/features/code/drivers/usage_limit.dart' show usageLimitEvent;
import 'package:every_ai/features/code/gateway_key.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/host/host_providers.dart';
import 'package:every_ai/features/code/resume/past_sessions.dart';
import 'package:every_ai/features/code/resume/resume_providers.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:every_ai/features/usage/usage_totals.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../support/fake_leads.dart';

/// A harness's own sessions for a folder, as a test lists them.
final class _Source implements PastSessionSource {
  @override
  bool get deletes => true;

  _Source(this.harness, this.sessions, {this.gate, this.fails = false});

  @override
  final String harness;
  final List<PastSession> sessions;
  final Completer<void>? gate;
  final bool fails;
  final asked = <(String, List<String>)>[];

  @override
  Future<List<PastSession>> list(String folder, {List<String> worktrees = const []}) async {
    asked.add((folder, worktrees));
    if (gate case final g?) await g.future;
    if (fails) throw StateError('unreadable');
    return sessions;
  }

  @override
  Future<List<HarnessEvent>> history(PastSession session) async => const [];

  final deleted = <String>[];

  @override
  Future<void> delete(String nativeId, {required String cwd}) async => deleted.add(nativeId);
}

/// [FakeLeadDriver] that takes over a CLI's own conversation: adopting one makes it reopenable.
final class _Adopting implements HarnessDriver, AttachesBriefed, AdoptsNativeSession {
  _Adopting(this.inner);

  final FakeLeadDriver inner;
  final adopted = <({String id, String cwd, String tag})>[];

  @override
  Future<String> adoptNative(
    String nativeId, {
    required String cwd,
    required String sessionTag,
    required String model,
    String? effort,
    required AgentMode mode,
  }) async {
    adopted.add((id: nativeId, cwd: cwd, tag: sessionTag));
    inner.conversations[nativeId] = FakeLeadSession(id: nativeId, replays: true, history: const []);
    return nativeId;
  }

  @override
  bool get replaysNativeHistory => false;

  @override
  DriverInfo get info => inner.info;
  @override
  Set<DriverCap> get caps => inner.caps;
  @override
  Future<DriverStatus> detect() => inner.detect();
  @override
  Future<List<DriverModel>> models() => inner.models();
  @override
  Future<HarnessSession> start(SessionSpec spec) => inner.start(spec);
  @override
  Future<HarnessSession> attach(String conversationId) => inner.attach(conversationId);
  @override
  Future<HarnessSession> attachBriefed(
    String conversationId,
    DriverBriefing briefing, {
    Map<String, Object?> mcpConfig = const {},
  }) => inner.attachBriefed(conversationId, briefing, mcpConfig: mcpConfig);
  @override
  Future<Map<String, ExecutionStatus>> statuses(List<String> conversationIds) => inner.statuses(conversationIds);
}

final _noNetwork = MockClient((req) async => http.Response('no network in this test', 599));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late Directory tmp;
  late Directory project;
  late Preferences prefs;
  late ProviderContainer container;
  late Map<String, HarnessDriver> drivers;
  late List<PastSessionSource> sources;
  var gitTrees = <String>[];

  ProviderContainer make() => ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      preferencesProvider.overrideWithValue(prefs),
      modelCatalogProvider.overrideWith(FixedCatalog.new),
      codeUsageProvider.overrideWithBuild((ref, n) async => UsageTotals.zero),
      driverRegistryProvider.overrideWithValue(DriverRegistry({...drivers})),
      hostServerProvider.overrideWithValue(FakeHost()),
      driverDataDirProvider.overrideWithValue(() async => '${tmp.path}/data'),
      gatewayKeysProvider.overrideWith((ref) => throw StateError('no gateway key for outside agents')),
      apiClientProvider.overrideWithValue(ApiClient(baseUrl: Uri.parse('http://backend/'), client: _noNetwork)),
      pastSessionSourcesProvider.overrideWith((ref) => sources),
      pastSessionTimeoutProvider.overrideWithValue(const Duration(milliseconds: 200)),
      gitWorktreesProvider.overrideWithValue((dir) async => gitTrees),
    ],
  );

  PastSession past(String harness, String id, {required DateTime at, String? cwd, String title = 'Fix the login'}) =>
      PastSession(
        harness: harness,
        nativeId: id,
        cwd: cwd ?? project.path,
        title: title,
        lastActive: at,
        turns: 3,
        model: 'm1',
        branch: 'main',
      );

  CodeProject theProject() => container.read(codeProjectsProvider).single;
  Future<List<PastSession>> listed() => container.read(pastSessionsProvider('p1').future);

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tmp = await Directory.systemTemp.createTemp('code-resume');
    project = await Directory('${tmp.path}/project').create();
    drivers = {
      everyaiHarnessName: FakeLeadDriver(everyaiHarnessName, label: 'EveryAI'),
      'alpha': _Adopting(FakeLeadDriver('alpha', label: 'Alpha')),
      'beta': _Adopting(FakeLeadDriver('beta', label: 'Beta')),
      'gone': _Adopting(FakeLeadDriver('gone', label: 'Gone', status: const DriverStatus())),
      'off': _Adopting(
        FakeLeadDriver('off', label: 'Off', status: const DriverStatus(installed: true, signedIn: false)),
      ),
      'cli': _Adopting(FakeLeadDriver('cli', label: 'Consent', needsConsent: true)),
    };
    sources = const [];
    gitTrees = [];
    prefs = await Preferences.load(db);
    prefs['code.projects'] = jsonEncode([CodeProject(id: 'p1', name: 'P', path: project.path).toJson()]);
    container = make();
  });

  tearDown(() async {
    container.dispose();
    await db.close();
    await tmp.delete(recursive: true);
  });

  test('every installed harness is listed for the folder, newest first; a slow or broken one is left out', () async {
    final slow = Completer<void>();
    final alpha = _Source('alpha', [past('alpha', 'a1', at: DateTime(2026, 11, 1))]);
    sources = [
      alpha,
      _Source('beta', [past('beta', 'b1', at: DateTime(2026, 11, 3))]),
      _Source('cli', [past('cli', 'x1', at: DateTime(2026, 11, 2))], gate: slow),
      _Source('off', const [], fails: true),
      // Not installed: never asked.
      _Source('gone', [past('gone', 'g1', at: DateTime(2026, 11, 4))]),
    ];
    container = make();
    final got = await listed();
    expect([for (final p in got) p.nativeId], ['b1', 'a1']);
    expect(alpha.asked.single.$1, project.path);
    expect((sources[4] as _Source).asked, isEmpty);
    slow.complete();
  });

  test("deleting a session deletes the harness's own copy, and one it can't delete never comes back", () async {
    final info = await container
        .read(codeSessionsProvider.notifier)
        .start(project: theProject(), prompt: 'Add dark mode', model: '', mode: AgentMode.ask, harness: 'alpha');
    // A source that can't delete (like ACP): the copy stays on disk.
    final alpha = _Source('alpha', [
      past('alpha', info.conversationId, at: DateTime(2026, 11, 3)),
      past('alpha', 'a2', at: DateTime(2026, 11, 2)),
    ]);
    sources = [alpha];
    container.invalidate(pastSessionSourcesProvider);
    expect([for (final p in await listed()) p.nativeId], ['a2']);
    await container.read(codeSessionsProvider.notifier).remove(info.id);
    expect(alpha.deleted, [info.conversationId]);
    expect([for (final p in await listed()) p.nativeId], ['a2']);
    // Still hidden after a restart.
    container.dispose();
    container = make();
    expect([for (final p in await listed()) p.nativeId], ['a2']);
  });

  test('Resume after a usage limit sends a carry-on turn, even to a lead whose own resume does nothing', () async {
    final info = await container
        .read(codeSessionsProvider.notifier)
        .start(project: theProject(), prompt: 'Add dark mode', model: '', mode: AgentMode.ask, harness: 'alpha');
    container.listen(codeSessionProvider(info.id), (_, _) {});
    await whenValue(container, codeSessionProvider(info.id).select((s) => s.connected), (bool c) => c);
    final lead = (drivers['alpha']! as _Adopting).inner.latest!;
    lead.add(usageLimitEvent('lim', 'You hit your limit', resetsAt: DateTime.now()));
    await pumpEventQueue();
    final before = lead.sent.length;
    expect(await container.read(codeSessionProvider(info.id).notifier).resumeAfterLimit(), isNull);
    await pumpEventQueue();
    // One turn (the session's mode note may lead it), ending in the carry-on words.
    expect(lead.sent.skip(before), [endsWith(resumeAfterLimitMessage)]);
    expect(lead.resumes, 0);
  });

  test('resuming runs on its own harness in the folder it ran in, reopened by its id, with its history once', () async {
    final worktree = await Directory('${tmp.path}/wt').create();
    final history = [userMessageEvent('h-u', 'Fix the login'), agentMessageEvent('h-a', 'Fixed it.')];
    final alpha = drivers['alpha']! as _Adopting;
    final pick = past('alpha', 'native-1', at: DateTime(2026, 11, 1), cwd: worktree.path);
    final info = await container
        .read(codeSessionsProvider.notifier)
        .resumePast(project: theProject(), past: pick, mode: AgentMode.autoEdit, history: history);
    expect(
      (info.harness, info.conversationId, info.workingDir, info.mode),
      ('alpha', 'native-1', worktree.path, AgentMode.autoEdit),
    );
    expect(alpha.adopted.single, (id: 'native-1', cwd: worktree.path, tag: info.id));
    expect(info.worktree, isNull);
    container.listen(codeSessionProvider(info.id), (_, _) {});
    await whenValue(container, codeSessionProvider(info.id).select((s) => s.connected), (bool c) => c);
    await pumpEventQueue();
    expect(alpha.inner.attached, ['native-1']);
    // Briefed like any reopen of an outside session.
    expect(alpha.inner.reopened, hasLength(1));
    final texts = [
      for (final i in container.read(codeSessionProvider(info.id)).transcript.items)
        if (i is UserTurn) i.text else if (i is AgentText) i.text,
    ];
    expect(texts, ['Fix the login', 'Fixed it.']);
  });
}
