// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/transcript.dart' show NoticeItem;
import 'package:every_ai/features/code/drivers/driver.dart';
import 'package:every_ai/features/code/drivers/driver_env.dart';
import 'package:every_ai/features/code/drivers/driver_events.dart';
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:every_ai/features/code/environments/environment_providers.dart';
import 'package:every_ai/features/code/environments/environment_scan.dart' show EnvScan;
import 'package:every_ai/features/code/environments/exec_env.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/host/host.dart';
import 'package:every_ai/features/code/host/host_max_tools.dart' show forkHostTool;
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
      for (final (id, env) in [
        ('p1', 'wsl:Ubuntu'),
        ('p2', 'docker:gone'),
        ('p3', 'wsl:Nat'),
        ('p4-devbox', 'docker:dev'),
        ('p5', 'ssh:box'),
        ('p6', 'multipass:vm'),
      ])
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
            FakeEnv(id: 'ssh:box', kind: EnvKind.ssh, label: 'box (SSH)'),
            // A VM with no name for the host inside.
            FakeEnv(
              id: 'multipass:vm',
              kind: EnvKind.vm,
              label: 'vm (Multipass)',
              hostRoot: '${tmp.path}/project',
              envRoot: '/workspace',
              urls: (_) => null,
            ),
            // A container that mounts only the project.
            FakeEnv(
              id: 'docker:dev',
              kind: EnvKind.container,
              label: 'dev (Container)',
              hostRoot: '${tmp.path}/project',
              envRoot: '/workspace',
              urls: (u) => u.replace(host: 'host.docker.internal'),
            ),
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

  Future<CodeSessionInfo> start(String projectId, {String harness = 'test', bool isolated = false}) => container
      .read(codeSessionsProvider.notifier)
      .start(
        project: container.read(codeProjectsProvider).firstWhere((p) => p.id == projectId),
        prompt: 'Add dark mode',
        model: '',
        mode: AgentMode.ask,
        harness: harness,
        isolated: isolated,
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

  test("an ssh remote is refused before it's briefed: its files have no path here yet", () async {
    await expectLater(
      start('p5'),
      throwsA(isA<HarnessError>().having((e) => e.message, 'message', contains("can't run on box (SSH) yet"))),
    );
    expect(host.minted, isEmpty);
    expect(fake.specs, isEmpty);
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

  test("where the host can't be reached from inside, the agent gets no token and no host tools, and is told", () async {
    final info = await start('p6');
    final b = fake.specs.single.briefing!;
    expect(fake.specs.single.workingDir, '/workspace');
    expect(b.mcpToken, isEmpty);
    expect(host.reached, isEmpty);
    expect(b.sessionSkill, contains('None are connected in this session.'));
    container.listen(codeSessionProvider(info.id), (_, _) {});
    await whenValue(container, codeSessionProvider(info.id).select((s) => s.connected), (bool c) => c);
    final notes = [
      for (final i in container.read(codeSessionProvider(info.id)).transcript.items)
        if (i is NoticeItem) i.message,
    ];
    expect(notes, contains(hostUnreachedNotice('vm (Multipass)')));
  });

  Future<void> gitInit() async {
    for (final a in [
      ['init', '-q', '-b', 'main'],
      ['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '--allow-empty', '-m', 'x'],
    ]) {
      expect((await Process.run('git', a, workingDirectory: '${tmp.path}/project')).exitCode, 0);
    }
  }

  test("a fork asked for its own worktree shares the folder where the agent can't write the app's data", () async {
    await gitInit();
    final info = await start('p4-devbox');
    container.listen(codeSessionProvider(info.id), (_, _) {});
    await whenValue(container, codeSessionProvider(info.id).select((s) => s.connected), (bool c) => c);
    final r = await host.tools[info.id]!.call(
      HostCall(
        id: 'h1',
        sessionId: info.id,
        name: forkHostTool,
        args: const {'task': 'Add b.txt', 'worktree': true},
        ended: Completer<HostEnd>().future,
      ),
    );
    expect(r.isError, isFalse, reason: r.text);
    final child = container.read(codeSessionsProvider).where((s) => s.parentId == info.id).single;
    expect(child.forkCopy, isNull);
    expect(child.workingDir, '${tmp.path}/project');
    expect(Directory('${tmp.path}/data/forks').existsSync(), isFalse);
  });

  test("an isolated session is refused before anything is made where the agent can't write the worktree", () async {
    final dir = '${tmp.path}/project';
    await gitInit();
    await expectLater(
      start('p4-devbox', isolated: true),
      throwsA(isA<HarnessError>().having((e) => e.message, 'message', isolatedUnreachable('dev (Container)'))),
    );
    expect(Directory('${tmp.path}/data/worktrees').existsSync(), isFalse);
    expect((await Process.run('git', ['branch', '--list', 'everyai/*'], workingDirectory: dir)).stdout, isEmpty);
    expect(fake.specs, isEmpty);
  });
}
