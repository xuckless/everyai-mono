// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io';

import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/drivers/acp/acp_driver.dart';
import 'package:every_ai/features/code/drivers/claude/claude_driver.dart';
import 'package:every_ai/features/code/drivers/driver.dart';
import 'package:every_ai/features/code/drivers/driver_env.dart';
import 'package:every_ai/features/code/drivers/driver_registry.dart';
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
      expect(r.resolve('claude-code', env: ubuntu), same(inside));
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
}
