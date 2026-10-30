// Live check of subagents: the parent's `run_subagent` call is held, a child
// conversation (no client tools, subagent rules) does the work, and its
// final message goes back as the held call's result. This plays the parts
// the app's controller plays. Not part of `flutter test`; run it explicitly:
//
//   AGENT_SERVER_URL=http://127.0.0.1:18732 AGENT_SERVER_KEY=… GATEWAY_KEY=sk-eai-… \
//   API_BASE_URL=http://127.0.0.1:18093 [EVAL_MODEL=anthropic/claude-haiku-5.5] \
//   flutter test tool/agent_eval/subagent_check_test.dart
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';

import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/subagents.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/harness/openhands_harness.dart';
import 'package:flutter_test/flutter_test.dart';

final _env = Platform.environment;

/// Folds a session's events (history first) until [done] holds.
Future<Transcript> _watch(HarnessSession s, bool Function(Transcript) done) {
  final b = TranscriptBuilder();
  final c = Completer<Transcript>();
  late final StreamSubscription<HarnessEvent> sub;
  var approved = '';
  sub = s.events.listen((e) {
    b.add(e);
    // Every mode has the server confirm each action; the app approves what
    // Full auto allows, and so does this check.
    final pending = b.snapshot.pending;
    final key = pending.map((c) => c.id).join(',');
    if (pending.isNotEmpty && key != approved) {
      approved = key;
      unawaited(s.respond(accept: true));
    }
    if (!c.isCompleted && done(b.snapshot)) {
      c.complete(b.snapshot);
      unawaited(sub.cancel());
    }
  });
  return c.future.timeout(const Duration(minutes: 4));
}

void main() {
  test(
    'a held task call runs a child conversation and gets its report',
    () async {
      final api = _env['API_BASE_URL'] ?? 'http://localhost:8080';
      final harness = OpenHandsHarness(
        baseUrl: Uri.parse('${_env['AGENT_SERVER_URL']}/'),
        sessionApiKey: _env['AGENT_SERVER_KEY']!,
      );
      final dir = await Directory.systemTemp.createTemp('everyai-subagent');
      File('${dir.path}/a.txt').writeAsStringSync('one\ntwo\nthree\n');
      File('${dir.path}/b.txt').writeAsStringSync('four\nfive\n');
      SessionSpec spec(String? first, {bool subagent = false}) => SessionSpec(
        workingDir: dir.path,
        model: _env['EVAL_MODEL'] ?? 'anthropic/claude-haiku-5.5',
        mode: AgentMode.fullAuto,
        llmBaseUrl: '$api/v1',
        llmApiKey: _env['GATEWAY_KEY']!,
        sessionTag: 'subagent-check',
        initialMessage: first,
        holdClientTools: !subagent,
        subagent: subagent,
      );

      final parent = await harness.start(
        spec(
          modeNote(
            AgentMode.fullAuto,
            'Use the task tool once: have a subagent count the lines of every .txt file here and report each count. '
            'Then tell me the total number of lines.',
          ),
        ),
      );
      var t = await _watch(parent, (t) => t.held.any(isTaskCall) || t.status == ExecutionStatus.finished);
      final call = t.held.firstWhere(isTaskCall, orElse: () => throw StateError('No task call: ${t.items}'));
      final task = SubagentTask.of(call);
      print('task: ${task.description} / ${task.prompt}');

      final child = await harness.start(
        spec(modeNote(AgentMode.fullAuto, subagentBrief(task), subagent: true), subagent: true),
      );
      final ct = await _watch(child, (t) => subagentOutcome(t) != null);
      final report = subagentOutcome(ct)!;
      print('child (${report.status}): ${report.text}');
      expect(report.status, SubagentStatus.completed);

      await parent.respond(accept: false, reason: subagentReason({call.id: report}));
      await parent.resume();
      t = await _watch(parent, (t) => t.status == ExecutionStatus.finished && t.held.isEmpty);
      final last = t.items.whereType<AgentText>().lastOrNull?.text ?? '';
      print('parent: $last');
      expect(t.items.whereType<SubagentItem>().single.report?.status, SubagentStatus.completed);
      expect(last, contains('5'));
      await child.close();
      await parent.close();
    },
    timeout: const Timeout(Duration(minutes: 10)),
    skip: _env['AGENT_SERVER_URL'] == null ? 'live: set AGENT_SERVER_URL' : false,
  );
}
