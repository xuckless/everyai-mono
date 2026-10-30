import 'session_processes.dart' show ProcessTable;

Future<List<int>> killSessionProcesses({
  required String tag,
  required String workingDir,
  required bool ownsDir,
}) async => const [];

Future<(ProcessTable, List<int>)?> findSessionProcesses({
  required String tag,
  required String workingDir,
  required bool ownsDir,
}) async => null;
