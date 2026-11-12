import 'dart:async';
import 'dart:io';

import '../drivers/detection/cli_scan.dart' show findCli;
import '../drivers/driver_process.dart' show spawnDriver;
import '../../../core/process/supervisor.dart' show Ended;
import '../drivers/json_rpc.dart' show EndsInput;
import '../drivers/short_run.dart' show logStop;
import '../harness/harness.dart' show HarnessError;
import 'board_planner.dart';

/// Runs [harness]'s CLI once, headless and read-only, in [cwd] with [prompt]; its reply text. On the user's own plan
/// or key for that CLI (EveryAI spends nothing). [PlannerCli.of] says which harnesses can. The process is one of the
/// app's driver processes (tagged [tag]): a timeout, [cancel] or quitting the app ends it with what it started.
Future<String> runPlannerCli(
  String harness,
  String model,
  String prompt,
  String cwd, {
  required String tag,
  Duration? timeout,
  Future<void>? cancel,
}) async {
  final cli = PlannerCli.of(harness) ?? (throw HarnessError("$harness can't plan without a session."));
  final path = await findCli(cli.command) ?? (throw HarnessError("${cli.label} isn't installed on this computer."));
  final tmp = await Directory.systemTemp.createTemp('everyai-plan');
  try {
    final lastMessage = cli == PlannerCli.codex ? '${tmp.path}/reply.txt' : null;
    final p = await spawnDriver(
      executable: path,
      args: plannerArgs(cli, model: model, prompt: prompt, lastMessage: lastMessage),
      cwd: cwd,
      sessionTag: tag,
      logPath: '${tmp.path}/stderr.log',
    );
    // Nothing comes on stdin: ending it tells `claude -p` not to wait for more.
    if (p case final EndsInput input) input.endInput();
    final out = StringBuffer();
    final read = p.lines.listen(out.writeln, onError: (Object _) {});
    final ended = Completer<String?>();
    void end(String? why) {
      if (!ended.isCompleted) ended.complete(why);
    }

    final timer = Timer(timeout ?? plannerTimeout, () => end('${cli.label} took too long to plan.'));
    unawaited(cancel?.then((_) => end('Stopped.')));
    unawaited(p.exitCode.then((_) => end(null), onError: (Object _) => end(null)));
    final why = await ended.future;
    timer.cancel();
    if (why != null) {
      // Stopped (verified) with what it started; a stop that isn't proven is said with the reason.
      final outcome = logStop('${cli.label} planner', await p.close());
      await read.cancel();
      throw HarnessError(outcome is Ended ? why : '$why It may still be running ($outcome).');
    }
    final code = await p.exitCode;
    await read.asFuture<void>().catchError((Object _) {});
    if (code != 0) {
      final lines = p.lastError.trim().split('\n').where((l) => l.trim().isNotEmpty);
      final last = lines.isEmpty ? '' : lines.last.trim();
      throw HarnessError('${cli.label} stopped (exit $code)${last.isEmpty ? '' : ': $last'}');
    }
    final text = lastMessage != null && File(lastMessage).existsSync()
        ? await File(lastMessage).readAsString()
        : plannerReplyText(cli, out.toString());
    if (text.trim().isEmpty) throw HarnessError('${cli.label} gave no plan.');
    return text;
  } finally {
    try {
      await tmp.delete(recursive: true);
    } on FileSystemException {
      // Only a temp folder left behind.
    }
  }
}
