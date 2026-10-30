import 'processes.dart';

Future<List<SessionProcess>> listSessionProcesses({
  required String tag,
  required String workingDir,
  required bool ownsDir,
  Set<int> terminalShells = const {},
}) async => const [];

bool killProcess(int pid, {bool force = false}) => false;
