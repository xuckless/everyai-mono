import 'package:every_ai/features/code/drivers/driver.dart';
import 'package:every_ai/features/code/drivers/driver_process.dart' show noAnswerProblem, notBuiltProblem;
import 'package:every_ai/features/code/environments/exec_env.dart';
import 'package:every_ai/features/onboarding/domain/harness_rows.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_leads.dart';
import '../support/fake_wsl_env.dart';

EnvStatus _on(String id, DriverStatus s, [ExecEnv env = HostEnv.instance]) => (env: env, driverId: id, status: s);

void main() {
  final drivers = [
    FakeLeadDriver('everyai', label: 'EveryAI'),
    FakeLeadDriver('claude-code', label: 'Claude Code'),
    FakeLeadDriver('codex', label: 'Codex'),
    FakeLeadDriver('opencode', label: 'OpenCode'),
  ];

  test('one state per check: ready, sign in, set up, unknown, absent, checking', () {
    expect(stateOf(null), RowState.checking);
    expect(stateOf(const DriverStatus(installed: true, signedIn: true)), RowState.ready);
    // Unknown sign-in is not a reason to ask.
    expect(stateOf(const DriverStatus(installed: true)), RowState.ready);
    expect(stateOf(const DriverStatus(installed: true, signedIn: false)), RowState.signIn);
    expect(stateOf(const DriverStatus(installed: true, problem: 'Too old')), RowState.setUp);
    expect(stateOf(const DriverStatus()), RowState.absent);
    expect(stateOf(const DriverStatus(), appFound: true), RowState.setUp);
    expect(stateOf(const DriverStatus(installed: true, problem: notBuiltProblem)), RowState.absent);
    expect(stateOf(const DriverStatus(problem: noAnswerProblem), appFound: true), RowState.unknown);
  });

  test('absent harnesses drop out only when asked; the built-in agent stays first', () {
    final found = [
      _on('claude-code', const DriverStatus(installed: true, signedIn: false)),
      _on('codex', const DriverStatus()),
      _on('opencode', const DriverStatus(problem: noAnswerProblem)),
    ];
    final shown = harnessRows(drivers, found, hideAbsent: true);
    expect(shown.map((r) => r.id), ['everyai', 'claude-code', 'opencode']);
    expect(shown.map((r) => r.state), [RowState.ready, RowState.signIn, RowState.unknown]);
    expect(harnessRows(drivers, found, hideAbsent: false).map((r) => r.id), [
      'everyai',
      'claude-code',
      'codex',
      'opencode',
    ]);
    // A missing CLI whose desktop app is here is on offer.
    expect(harnessRows(drivers, found, hideAbsent: true, appFound: (id) => id == 'codex').map((r) => r.id), [
      'everyai',
      'claude-code',
      'codex',
      'opencode',
    ]);
  });

  test('before the first check every harness reads checking', () {
    final rows = harnessRows(drivers, const [], hideAbsent: true);
    expect(rows.map((r) => r.state), [RowState.ready, RowState.checking, RowState.checking, RowState.checking]);
  });

  test('another environment is labelled, listed after the host, and only for what it was checked for', () {
    const wsl = FakeWslEnv();
    final rows = harnessRows(drivers, [
      _on('claude-code', const DriverStatus(installed: true), wsl),
      _on('codex', const DriverStatus(installed: true)),
    ], hideAbsent: true);
    expect(rows.map((r) => r.title), ['EveryAI', 'Claude Code', 'Codex', 'OpenCode', 'Claude Code · Ubuntu (WSL)']);
    expect(rows.last.env.id, 'wsl:Ubuntu');
  });

  test("the host's desktop app does not make a missing CLI in WSL a row", () {
    final rows = harnessRows(
      drivers,
      [_on('codex', const DriverStatus()), _on('codex', const DriverStatus(), const FakeWslEnv())],
      hideAbsent: true,
      appFound: (_) => true,
    );
    expect(rows.where((r) => !r.env.isHost), isEmpty);
    expect(rows.firstWhere((r) => r.id == 'codex').state, RowState.setUp);
  });

  test('a blocked built-in agent is a row to set up, not Ready', () {
    final rows = harnessRows(drivers, const [], hideAbsent: true, builtInBlocked: true);
    expect(rows.first.state, RowState.setUp);
  });
}
