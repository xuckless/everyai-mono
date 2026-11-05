// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/drivers/driver.dart';
import 'package:every_ai/features/code/drivers/driver_env.dart';
import 'package:every_ai/features/code/drivers/driver_events.dart';
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:every_ai/features/code/environments/environment_providers.dart';
import 'package:every_ai/features/code/environments/environment_scan.dart' show EnvScan;
import 'package:every_ai/features/code/environments/exec_env.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/host/host_providers.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:every_ai/features/usage/usage_totals.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_leads.dart';
import 'env_fakes.dart';

/// [FakeLeadDriver] that can be bound to an environment: every copy shares
/// the fake, and records where it was used.
final class _EnvDriver implements HarnessDriver, AttachesBriefed, RunsInEnvironments {
  _EnvDriver(this.fake, this.used, [this.execEnv = HostEnv.instance]);

  final FakeLeadDriver fake;
  final List<String> used;
  @override
  final ExecEnv execEnv;

  @override
  HarnessDriver inEnv(ExecEnv env, EnvFind find) => _EnvDriver(fake, used, env);

  @override
  DriverInfo get info => fake.info;
  @override
  Set<DriverCap> get caps => fake.caps;
  @override
  Future<DriverStatus> detect() => fake.detect();
  @override
  Future<List<DriverModel>> models() => fake.models();
  @override
  Future<HarnessSession> start(SessionSpec spec) {
    used.add('start ${execEnv.id}');
    return fake.start(spec);
  }

  @override
  Future<HarnessSession> attach(String conversationId) {
    used.add('attach ${execEnv.id}');
    return fake.attach(conversationId);
  }

  @override
  Future<HarnessSession> attachBriefed(
    String id,
    DriverBriefing briefing, {
    Map<String, Object?> mcpConfig = const {},
  }) {
    used.add('attach ${execEnv.id}');
    return fake.attachBriefed(id, briefing, mcpConfig: mcpConfig);
  }

  @override
  Future<Map<String, ExecutionStatus>> statuses(List<String> conversationIds) => fake.statuses(conversationIds);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late Directory tmp;
  late FakeLeadSession session;
  late FakeLeadDriver fake;
  late List<String> used;
  late List<String> ended;
  late FakeEnv ubuntu;
  late FakeHost host;
  late ProviderContainer container;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tmp = await Directory.systemTemp.createTemp('code-env');
    await Directory('${tmp.path}/project').create();
    session = FakeLeadSession();
    host = FakeHost();
    fake = FakeLeadDriver('test', session: session);
    used = [];
    ended = [];
    ubuntu = FakeEnv(
      hostRoot: tmp.path,
      envRoot: '/home/u',
      urls: (u) => u.replace(host: 'host.docker.internal'),
    );
    final prefs = await Preferences.load(db);
    prefs['code.projects'] = jsonEncode([
      for (final (id, env) in [('p1', 'wsl:Ubuntu'), ('p2', 'docker:gone'), ('p3', 'wsl:Nat')])
        CodeProject(id: id, name: id, path: '${tmp.path}/project', environment: env).toJson(),
    ]);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(prefs),
        modelCatalogProvider.overrideWith(FixedCatalog.new),
        codeUsageProvider.overrideWithBuild((ref, n) async => UsageTotals.zero),
        driverRegistryProvider.overrideWithValue(
          DriverRegistry({'test': _EnvDriver(fake, used), everyaiHarnessName: FakeLeadDriver(everyaiHarnessName)}),
        ),
        hostServerProvider.overrideWithValue(host),
        driverDataDirProvider.overrideWithValue(() async => '${tmp.path}/data'),
        environmentsProvider.overrideWith(
          (ref) async => [
            HostEnv.instance,
            ubuntu,
            // NAT networking: no name for the host inside; its scan found the default gateway.
            FakeEnv(id: 'wsl:Nat', label: 'Nat (WSL)', hostRoot: tmp.path, envRoot: '/home/u', urls: (_) => null),
          ],
        ),
        environmentScanProvider('wsl:Nat').overrideWith((ref) async => const EnvScan(hostAddress: '172.20.0.1')),
        endInsideProvider.overrideWithValue((env, tag, {toolsOnly = false}) async {
          ended.add('${env.id} $tag $toolsOnly');
          return const [];
        }),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<CodeSessionInfo> start(String projectId, {String harness = 'test'}) => container
      .read(codeSessionsProvider.notifier)
      .start(
        project: container.read(codeProjectsProvider).firstWhere((p) => p.id == projectId),
        prompt: 'Add dark mode',
        model: '',
        mode: AgentMode.ask,
        harness: harness,
      );

  test('a session in an environment gets its paths and the host address as seen from inside', () async {
    final info = await start('p1');
    expect(info.environment, 'wsl:Ubuntu');
    expect(info.workingDir, '${tmp.path}/project');
    expect(used, ['start wsl:Ubuntu']);
    final spec = fake.specs.single;
    expect(spec.workingDir, '/home/u/project');
    expect(spec.briefing!.skillDir, '/home/u/data/driver-sessions/${info.id}/briefing/skills');
    expect(spec.briefing!.mcpUrl, 'http://host.docker.internal:9/mcp');
    // Served there for this session's token only.
    expect(host.reached, ['${spec.briefing!.mcpToken} http://host.docker.internal:9/mcp']);
    expect(spec.briefing!.sessionSkill, contains('/home/u/project'));
    expect(CodeSessionInfo.fromJson(info.toJson()).environment, 'wsl:Ubuntu');
  });

  test("WSL in NAT mode reaches the MCP host at the distro's default gateway", () async {
    await start('p3');
    final b = fake.specs.single.briefing!;
    expect(b.mcpUrl, 'http://172.20.0.1:9/mcp');
    expect(host.reached, ['${b.mcpToken} http://172.20.0.1:9/mcp']);
  });

  test('reopening goes to the copy bound to the environment', () async {
    final info = await start('p1');
    await container.read(codeSessionsProvider.notifier).attachSession(info);
    expect(used, ['start wsl:Ubuntu', 'attach wsl:Ubuntu']);
  });

  test("an environment that's gone stops the start; it never runs here instead", () async {
    await expectLater(
      start('p2'),
      throwsA(isA<HarnessError>().having((e) => e.message, 'message', contains("isn't on this computer any more"))),
    );
    expect(fake.specs, isEmpty);
    expect(used, isEmpty);
  });

  test('the EveryAI harness stays on this computer', () async {
    await expectLater(
      start('p1', harness: everyaiHarnessName),
      throwsA(isA<HarnessError>().having((e) => e.message, 'message', contains('runs on this computer only'))),
    );
  });

  test("Stop ends what the CLI's shells run inside", () async {
    final info = await start('p1');
    container.listen(codeSessionProvider(info.id), (_, _) {});
    await whenValue(container, codeSessionProvider(info.id).select((s) => s.connected), (bool c) => c);
    await container.read(codeSessionProvider(info.id).notifier).stop();
    expect(ended, ['wsl:Ubuntu ${info.id} true']);
  });

  test('paths in its tool calls come back as host paths', () async {
    final info = await start('p1');
    container.listen(codeSessionProvider(info.id), (_, _) {});
    await whenValue(container, codeSessionProvider(info.id).select((s) => s.connected), (bool c) => c);
    session.add(
      actionEvent(id: 'a1', toolName: 'Read', kind: 'ReadFileAction', args: {'path': '/home/u/project/lib/a.dart'}),
    );
    await pumpEventQueue();
    final call = container.read(codeSessionProvider(info.id).notifier).mirrorEvents.whereType<ActionCall>().single;
    expect(call.str('path'), '${tmp.path}/project/lib/a.dart');
  });
}
