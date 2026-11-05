// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../../code/domain/code_session.dart' show everyaiHarnessName;
import '../../code/drivers/detection/cli_state.dart';
import '../../code/drivers/driver.dart';
import '../../code/drivers/driver_process.dart' show noAnswerProblem;
import '../../code/environments/exec_env.dart';

/// One check of one harness in one environment. The environments lane feeds a list of these; today it is the host's.
typedef EnvStatus = ({ExecEnv env, String driverId, DriverStatus status});

/// What a row says about its harness.
enum RowState {
  /// Still being checked.
  checking,

  /// Usable ([CliState.ready], or the built-in agent).
  ready,
  signIn,
  setUp,

  /// The check timed out: neither found nor missing.
  unknown,

  /// Nothing found and nothing to set up from.
  absent,
}

class HarnessRow {
  const HarnessRow({required this.env, required this.driver, required this.status, required this.state});

  final ExecEnv env;
  final HarnessDriver driver;

  /// Null while checking.
  final DriverStatus? status;
  final RowState state;

  String get id => driver.info.id;
  String get title => rowTitle(driver.info.label, env);
}

/// "Claude Code", or "Claude Code · Ubuntu (WSL)" when it is not on this computer.
String rowTitle(String label, ExecEnv env) => env.isHost ? label : '$label · ${env.label}';

/// The rows to show: the built-in agent first, then the host's, then each other environment, each in registry order.
/// [found] has no entry for a harness not checked yet (row state `checking`). [appFound] says a missing CLI has a
/// desktop app to set up from. [hideAbsent] drops harnesses with nothing found (the setup step; Settings keeps them
/// for their install line).
List<HarnessRow> harnessRows(
  List<HarnessDriver> drivers,
  List<EnvStatus> found, {
  required bool hideAbsent,
  bool Function(String driverId) appFound = _never,
}) {
  final envs = <ExecEnv>[HostEnv.instance];
  for (final f in found) {
    if (!envs.any((e) => e.id == f.env.id)) envs.add(f.env);
  }
  final rows = <HarnessRow>[];
  for (final d in drivers) {
    if (d.info.id == everyaiHarnessName) {
      final status = [
        for (final f in found)
          if (f.env.isHost && f.driverId == d.info.id) f.status,
      ].firstOrNull;
      rows.add(HarnessRow(env: HostEnv.instance, driver: d, status: status, state: RowState.ready));
    }
  }
  for (final env in envs) {
    for (final d in drivers) {
      if (d.info.id == everyaiHarnessName) continue;
      final status = [
        for (final f in found)
          if (f.env.id == env.id && f.driverId == d.info.id) f.status,
      ].firstOrNull;
      // A non-host environment only lists what it was checked for.
      if (status == null && !env.isHost) continue;
      final state = stateOf(status, appFound: appFound(d.info.id));
      if (hideAbsent && state == RowState.absent) continue;
      rows.add(HarnessRow(env: env, driver: d, status: status, state: state));
    }
  }
  return rows;
}

bool _never(String _) => false;

/// The one rule from a check to a row state; the button and the check mark follow it.
RowState stateOf(DriverStatus? status, {bool appFound = false}) {
  if (status == null) return RowState.checking;
  if (!status.installed && status.problem == noAnswerProblem) return RowState.unknown;
  return switch (cliStateOf(status, appFound: appFound)) {
    CliState.ready => RowState.ready,
    CliState.signIn => RowState.signIn,
    CliState.setUp => RowState.setUp,
    CliState.absent => RowState.absent,
  };
}
