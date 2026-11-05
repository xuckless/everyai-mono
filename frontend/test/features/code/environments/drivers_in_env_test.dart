// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io';

import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/drivers/acp/acp_driver.dart';
import 'package:every_ai/features/code/drivers/claude/claude_driver.dart';
import 'package:every_ai/features/code/drivers/codex/codex_driver.dart';
import 'package:every_ai/features/code/drivers/driver.dart';
import 'package:every_ai/features/code/drivers/driver_env.dart';
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:every_ai/features/code/drivers/opencode/opencode_driver.dart';
import 'package:every_ai/features/code/drivers/terminal/terminal_driver.dart';
import 'package:every_ai/features/code/environments/exec_env.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'env_fakes.dart';

Future<DriverStatus> _found(String c) async => DriverStatus(installed: true, path: '/env/bin/$c');

SessionSpec _spec() => const SessionSpec(
  workingDir: '/env/p',
  model: 'm',
  mode: AgentMode.ask,
  llmBaseUrl: '',
  llmApiKey: '',
  sessionTag: 's1',
);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('drivers-env'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('registry', () {
    final claude = ClaudeDriver();
    final looked = <String>[];
    DriverRegistry registry() => DriverRegistry(
      {'claude-code': claude, 'terminal:x': TerminalDriver(id: 'terminal:x', label: 'x', command: 'x')},
      envFind: (env) => (c) async {
        looked.add('${env.id} $c');
        return _found(c);
      },
    );

    test('the host gets the driver itself', () {
      expect(registry().resolve('claude-code'), same(claude));
      expect(registry().resolve('claude-code', env: HostEnv.instance), same(claude));
    });

    test('an environment gets one bound copy per driver and environment id', () async {
      final r = registry();
      final ubuntu = FakeEnv();
      final inside = r.resolve('claude-code', env: ubuntu);
      expect(inside, isA<ClaudeDriver>());
      expect((inside! as RunsInEnvironments).execEnv, same(ubuntu));
      expect(r.resolve('claude-code', env: FakeEnv()), same(inside));
      expect(
        r.resolve(
          'claude-code',
          env: FakeEnv(id: 'docker:dev', kind: EnvKind.container),
        ),
        isNot(same(inside)),
      );
      expect((await inside.detect()).path, '/env/bin/claude');
      expect(looked, ['wsl:Ubuntu claude']);
    });

    test("terminal agents and unknown ids don't run inside", () {
      final r = registry();
      expect(r.resolve('terminal:x', env: FakeEnv()), isNull);
      expect(r.resolve('terminal:y', env: FakeEnv()), isNull);
      expect(r.resolve('nope', env: FakeEnv()), isNull);
      expect(r.resolve('acp:kimi', env: FakeEnv()), isA<AcpDriver>());
    });
  });

  test("Claude's model probe runs in the app's folder as the environment sees it", () async {
    final cwds = <String>[];
    final d = ClaudeDriver(
      dataDir: () async => tmp.path,
      spawn: (args, {required cwd, required env, required sessionTag, required logPath}) async {
        cwds.add(cwd);
        throw const HarnessError('no');
      },
    ).inEnv(FakeEnv(hostRoot: tmp.path), _found);
    expect(await d.models(), isNotEmpty);
    expect(cwds, ['/env/driver-sessions/claude-code']);
  });

  test("Codex's sign-in probe runs inside, from a folder the environment sees", () async {
    final cwds = <String>[];
    final d = CodexDriver(
      dataDir: () async => '/elsewhere',
      spawn: ({required args, required cwd, required env, required sessionTag}) async {
        cwds.add(cwd);
        throw const HarnessError('no');
      },
    ).inEnv(FakeEnv(), _found);
    final s = await d.detect();
    expect(s.path, '/env/bin/codex');
    expect(s.problem, contains('signed in'));
    // The app's data isn't shared into it: the root.
    expect(cwds, ['/']);
  });

  test('an agent that needs a terminal is refused inside', () async {
    final d = AcpDriver(
      id: 'grok',
      label: 'Grok Build',
      command: 'grok',
      dataDir: () async => tmp.path,
    ).inEnv(FakeEnv(), _found);
    await expectLater(
      d.start(_spec()),
      throwsA(isA<HarnessError>().having((e) => e.message, 'message', contains("can't run inside Ubuntu (WSL)"))),
    );
  });

  test('an ACP agent inside is looked up by its scan', () async {
    final d = AcpDriver(id: 'acp:kimi', label: 'kimi', command: 'kimi').inEnv(FakeEnv(), _found);
    expect(await d.detect(), isA<DriverStatus>().having((s) => s.path, 'path', '/env/bin/kimi'));
  });

  test("OpenCode's server runs inside WSL only; elsewhere it points at its ACP entry", () async {
    final docker = OpenCodeDriver().inEnv(FakeEnv(id: 'docker:dev', kind: EnvKind.container, label: 'dev'), _found);
    expect((await docker.detect()).problem, contains('Use OpenCode (ACP) in dev'));
    await expectLater(
      docker.start(_spec()),
      throwsA(isA<HarnessError>().having((e) => e.message, 'message', contains('Use OpenCode (ACP)'))),
    );
    final wsl = OpenCodeDriver(run: (exe, args) async => (exitCode: 1, stdout: '')).inEnv(FakeEnv(), _found);
    expect((await wsl.detect()).path, '/env/bin/opencode');
  });
}
