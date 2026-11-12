import '../../../core/process/process_model.dart' show KillOutcome, ScanFailed;
import 'session_processes.dart' show SessionScan, SessionScanFailed;

Future<KillOutcome> killSessionProcesses({
  required String tag,
  required String workingDir,
  required bool ownsDir,
  Set<int> roots = const {},
  bool workflows = false,
}) async => const ScanFailed('processes are not listed on this platform');

Future<SessionScan> findSessionProcesses({
  required String tag,
  required String workingDir,
  required bool ownsDir,
  Set<int> roots = const {},
}) async => const SessionScanFailed('processes are not listed on this platform');
