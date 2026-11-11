import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../drivers/detection/cli_scan.dart' show findCli;
import '../harness/everyai/shell_io.dart' show ShellEnv;
import '../harness/harness.dart' show HarnessError;
import 'board_planner.dart';

/// Runs [harness]'s CLI once, headless and read-only, in [cwd] with [prompt]; its reply text. On the user's own plan
/// or key for that CLI (EveryAI spends nothing). [PlannerCli.of] says which harnesses can.
Future<String> runPlannerCli(String harness, String model, String prompt, String cwd, {Duration? timeout}) async {
  final cli = PlannerCli.of(harness) ?? (throw HarnessError("$harness can't plan without a session."));
  final path = await findCli(cli.command) ?? (throw HarnessError("${cli.label} isn't installed on this computer."));
  final env = (await ShellEnv.load()).env;
  Directory? tmp;
  try {
    String? lastMessage;
    if (cli == PlannerCli.codex) {
      tmp = await Directory.systemTemp.createTemp('everyai-plan');
      lastMessage = '${tmp.path}/reply.txt';
    }
    final args = plannerArgs(cli, model: model, prompt: prompt, lastMessage: lastMessage);
    final p = await Process.start(path, args, workingDirectory: cwd, environment: env);
    // Nothing comes on stdin: closing it tells `claude -p` not to wait for more.
    unawaited(p.stdin.close().catchError((Object _) {}));
    final out = p.stdout.transform(const Utf8Decoder(allowMalformed: true)).join();
    final err = p.stderr.transform(const Utf8Decoder(allowMalformed: true)).join();
    final int code;
    try {
      code = await p.exitCode.timeout(timeout ?? const Duration(minutes: 4));
    } on TimeoutException {
      p.kill();
      throw HarnessError('${cli.label} took too long to plan.');
    }
    final stdout = await out;
    if (code != 0) {
      final lines = (await err).trim().split('\n').where((l) => l.trim().isNotEmpty);
      final why = lines.isEmpty ? '' : lines.last.trim();
      throw HarnessError('${cli.label} stopped (exit $code)${why.isEmpty ? '' : ': $why'}');
    }
    final text = lastMessage != null && File(lastMessage).existsSync()
        ? await File(lastMessage).readAsString()
        : plannerReplyText(cli, stdout);
    if (text.trim().isEmpty) throw HarnessError('${cli.label} gave no plan.');
    return text;
  } finally {
    try {
      await tmp?.delete(recursive: true);
    } on FileSystemException {
      // Only a temp folder left behind.
    }
  }
}
