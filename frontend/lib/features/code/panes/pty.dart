import 'dart:typed_data';

import 'pty_stub.dart' if (dart.library.io) 'pty_io.dart' as impl;

/// A login shell in a pseudo-terminal.
abstract interface class ShellPty {
  int get pid;
  Stream<Uint8List> get output;
  Future<int> get exitCode;
  void write(Uint8List data);
  void resize(int rows, int columns);
  void kill();
}

/// Whether this platform can run [startShell].
bool get shellSupported => impl.shellSupported;

/// Starts the user's shell in [workingDir], or null where there is none.
/// [env] is added to the app's own environment.
ShellPty? startShell({
  required String workingDir,
  int rows = 24,
  int columns = 80,
  Map<String, String> env = const {},
}) => impl.startShell(workingDir: workingDir, rows: rows, columns: columns, env: env);
