import '../../../core/process/process_model.dart' show KillOutcome, ScanFailed;
import 'processes.dart';

Future<ProcessListing> listSessionProcesses({
  required String tag,
  required String workingDir,
  required bool ownsDir,
  Set<int> agentRoots = const {},
  Set<int> terminalShells = const {},
}) async => const ProcessesListed([]);

Future<PortScan> scanListeningPorts(Iterable<int> pids) async => const PortsUnreadable('not on this platform');

Future<KillOutcome> killProcess(int pid, {bool force = false, String? expectedStart}) async =>
    const ScanFailed('processes are not stopped on this platform');

Future<String?> outputFileOf(int pid) async => null;
