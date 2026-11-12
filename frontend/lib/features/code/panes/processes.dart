import 'package:flutter/foundation.dart';

import '../../../core/process/process_model.dart' show Ended, KillOutcome, ScanFailed, Survived;
import '../domain/local_ports.dart';
import 'processes_stub.dart' if (dart.library.io) 'processes_io.dart' as impl;

export '../../../core/process/process_model.dart' show KillOutcome;

/// Who started a process in the session.
enum ProcessOrigin { agent, terminal }

/// A process of a Code session, for the Processes pane.
@immutable
final class SessionProcess {
  const SessionProcess({
    required this.pid,
    required this.ppid,
    required this.command,
    required this.origin,
    this.ports = const [],
  });

  final int pid;
  final int ppid;
  final String command;
  final ProcessOrigin origin;
  final List<ListeningPort> ports;

  /// The program's name, without its folder or arguments.
  String get name {
    final first = command.trimLeft().split(RegExp(r'\s')).first;
    return first.substring(first.lastIndexOf('/') + 1);
  }
}

/// What a look at a session's processes found.
@immutable
sealed class ProcessListing {
  const ProcessListing();
}

final class ProcessesListed extends ProcessListing {
  const ProcessesListed(this.processes);
  final List<SessionProcess> processes;
}

/// The process table couldn't be read: the pane says so instead of "nothing running".
final class ProcessesUnreadable extends ProcessListing {
  const ProcessesUnreadable(this.why);
  final String why;
}

/// The error a failed listing reaches the Processes pane as (through its provider).
final class ProcessesUnreadableError implements Exception {
  const ProcessesUnreadableError(this.why);
  final String why;
  @override
  String toString() => "Couldn't read processes: $why";
}

/// The processes the agent's terminal left running for session [tag] (see
/// `killSessionProcesses`), the trees of [agentRoots] (the app app_run
/// started), and everything below the user's own terminal shells
/// [terminalShells], with the ports they listen on; or why they couldn't be
/// listed.
Future<ProcessListing> listSessionProcesses({
  required String tag,
  required String workingDir,
  required bool ownsDir,
  Set<int> agentRoots = const {},
  Set<int> terminalShells = const {},
}) => impl.listSessionProcesses(
  tag: tag,
  workingDir: workingDir,
  ownsDir: ownsDir,
  agentRoots: agentRoots,
  terminalShells: terminalShells,
);

/// The TCP ports [pids] listen on (none where that can't be found).
Future<List<ListeningPort>> listeningPorts(Iterable<int> pids) => impl.listeningPorts(pids);

/// Ends [pid] and its tree with the supervisor's verified kill (with [force], SIGKILL without a grace): what came
/// of it. Only [Ended]-type outcomes mean gone.
Future<KillOutcome> killProcess(int pid, {bool force = false}) => impl.killProcess(pid, force: force);

/// The toast for a Stop/Kill of [name] ([pid]) that came to [out]: "Stopped" only when it is proven gone.
String killToast(KillOutcome out, String name, int pid, {bool force = false}) => switch (out) {
  Ended() => '${force ? 'Killed' : 'Stopped'} $name ($pid)',
  Survived(:final pids) => 'Not closed: ${pids.join(', ')} still running after SIGKILL',
  ScanFailed(:final why) => "Couldn't check that $name ($pid) stopped: $why",
  _ => 'Not closed: $out',
};

/// The regular file [pid]'s standard output goes to (a process an outside lead started with its output in a file),
/// or null: a terminal, a pipe, a socket, or not found. Its row in Processes then tails it.
Future<String?> outputFileOf(int pid) => impl.outputFileOf(pid);

/// The file name in `lsof -Fn` output, or null.
String? lsofFileName(String out) {
  for (final line in out.split('\n')) {
    if (line.startsWith('n') && line.length > 1) return line.substring(1);
  }
  return null;
}
