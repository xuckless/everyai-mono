// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io';

import '../../../../core/process/supervisor.dart';
import '../../harness/everyai/shell_io.dart' show ShellEnv;
import '../../harness/harness.dart' show HarnessError;
import '../short_run.dart';
import 'opencode_host.dart';

/// Throws a [HarnessError] when it can't start or runs past 10 s (then it is stopped, verified, with what it
/// started), as it threw before (a timeout, a missing program).
Future<CliRun> runOpenCodeCli(String executable, List<String> args, {String? cwd}) async {
  final shell = await ShellEnv.load();
  final r = await runShort(
    executable,
    args,
    timeout: const Duration(seconds: 10),
    cwd: cwd,
    env: {...shell.env, 'OPENCODE_DISABLE_AUTOUPDATE': '1'},
    owner: const ProbeOwner('opencode-cli'),
  );
  switch (r) {
    case Finished(:final code, :final stdout):
      return (exitCode: code, stdout: stdout);
    case TimedOut(:final kill) || Cancelled(:final kill):
      logStop('opencode ${args.take(2).join(' ')}', kill);
      throw HarnessError(runProblem('opencode ${args.take(2).join(' ')}', r)!);
    case StartFailed() || Refused():
      throw HarnessError(runProblem('opencode', r)!);
  }
}

Future<String?> readTextFile(String path) async {
  final f = File(path);
  return await f.exists() ? f.readAsString() : null;
}

Future<void> writeTextFile(String path, String text) async {
  final f = File(path);
  await f.parent.create(recursive: true);
  final tmp = File('$path.tmp');
  await tmp.writeAsString(text, flush: true);
  await tmp.rename(path);
}
