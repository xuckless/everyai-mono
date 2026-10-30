import 'pty.dart';

bool get shellSupported => false;

ShellPty? startShell({
  required String workingDir,
  int rows = 24,
  int columns = 80,
  Map<String, String> env = const {},
}) => null;
