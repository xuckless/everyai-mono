import '../../../core/process/process_model.dart' show KillOutcome, ScanFailed;
import '../domain/local_ports.dart';
import 'processes.dart';

Future<ProcessListing> listSessionProcesses({
  required String tag,
  required String workingDir,
  required bool ownsDir,
  Set<int> agentRoots = const {},
  Set<int> terminalShells = const {},
}) async => const ProcessesListed([]);

Future<List<ListeningPort>> listeningPorts(Iterable<int> pids) async => const [];

Future<KillOutcome> killProcess(int pid, {bool force = false}) async =>
    const ScanFailed('processes are not stopped on this platform');

Future<String?> outputFileOf(int pid) async => null;
