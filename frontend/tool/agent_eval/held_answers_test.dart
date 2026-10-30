// Live check of the held-call answer path: question-card answers and plan
// approval go back as the result of the client tool call itself (a
// rejection with a reason, then /run) instead of as a new user message.
// Not part of `flutter test`; run it explicitly:
//
//   AGENT_SERVER_URL=http://127.0.0.1:18732 AGENT_SERVER_KEY=… GATEWAY_KEY=sk-eai-… \
//   API_BASE_URL=http://127.0.0.1:18093 [EVAL_MODEL=anthropic/claude-haiku-5.5 EVAL_RUNS=1] \
//   flutter test tool/agent_eval/held_answers_test.dart
//
// Each scenario passes when the agent acts on the answer without being sent
// another user message.
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';

import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/questions.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/harness/openhands_harness.dart';
import 'package:flutter_test/flutter_test.dart';

final _env = Platform.environment;

/// Runs one session, answering held client tools in the call itself.
/// Returns the transcript and the number of user messages sent after the first.
Future<(Transcript, int)> _run(AgentMode startMode, String dir, String prompt, String tag, {String? revision}) async {
  final api = _env['API_BASE_URL'] ?? 'http://localhost:8080';
  final harness = OpenHandsHarness(
    baseUrl: Uri.parse('${_env['AGENT_SERVER_URL']}/'),
    sessionApiKey: _env['AGENT_SERVER_KEY']!,
  );
  var mode = startMode;
  final session = await harness.start(
    SessionSpec(
      workingDir: dir,
      model: _env['EVAL_MODEL'] ?? 'anthropic/claude-haiku-5.5',
      mode: mode,
      llmBaseUrl: '$api/v1',
      llmApiKey: _env['GATEWAY_KEY']!,
      sessionTag: tag,
      initialMessage: modeNote(mode, prompt),
      maxInputTokens: 200000,
      holdClientTools: true,
    ),
  );
  final builder = TranscriptBuilder();
  final done = Completer<void>();
  var respondedTo = '';
  var ranOnce = false;
  var plans = 0;
  final sub = session.events.listen((e) {
    builder.add(e);
    final t = builder.snapshot;
    if (t.running) ranOnce = true;
    final waiting = [...t.held, ...t.pending];
    if (waiting.isNotEmpty) {
      final key = waiting.map((c) => c.id).join(',');
      if (key == respondedTo) return;
      respondedTo = key;
      final call = waiting.first;
      // A rejection parks the conversation until /run; wait for it to run again.
      ranOnce = false;
      if (call.toolName == askUserQuestionTool) {
        final qs = Question.listFrom(call.action);
        // The last option, so a lucky guess of the first one can't pass.
        final answers = [
          for (final q in qs) QuestionAnswer(selected: {q.options.length - 1}),
        ];
        print('ANSWERING: ${answers.indexed.map((a) => a.$2.labels(qs[a.$1])).join('; ')}');
        unawaited(session.respond(accept: false, reason: answersReason(qs, answers)).then((_) => session.resume()));
      } else if (call.toolName == presentPlanTool && revision != null && plans++ == 0) {
        print('REVISING PLAN: ${call.str('title')}');
        unawaited(session.respond(accept: false, reason: '$planRevisionLead $revision').then((_) => session.resume()));
      } else if (call.toolName == presentPlanTool) {
        print('APPROVING PLAN: ${call.str('title')}');
        mode = AgentMode.autoEdit;
        unawaited(
          session
              .setMode(mode)
              .then((_) => session.respond(accept: false, reason: planApprovedReason))
              .then((_) => session.resume()),
        );
      } else if (waiting.any(mode.rejects)) {
        unawaited(session.respond(accept: false, reason: AgentMode.planRefusal).then((_) => session.resume()));
      } else {
        unawaited(session.respond(accept: true));
      }
      return;
    }
    if (!ranOnce || t.running) return;
    if (t.status
        case ExecutionStatus.finished || ExecutionStatus.idle || ExecutionStatus.error || ExecutionStatus.stuck) {
      if (!done.isCompleted) done.complete();
    }
  });
  try {
    await done.future.timeout(const Duration(minutes: 6));
  } finally {
    await sub.cancel();
    await session.close();
  }
  final t = builder.snapshot;
  return (t, t.items.whereType<UserTurn>().length - 1);
}

Directory _repo(String name) {
  final dir = Directory.systemTemp.createTempSync('held-$name-');
  File('${dir.path}/README.md').writeAsStringSync('# Scratch\n\nAn empty project.\n');
  Process.runSync('git', ['init', '-q'], workingDirectory: dir.path);
  return dir;
}

String _dump(Transcript t) => [
  for (final i in t.items)
    switch (i) {
      UserTurn(:final text) => 'USER: ${text.split('\n').first}',
      AgentText(:final text) when text.trim().isNotEmpty => 'AGENT: ${text.replaceAll('\n', ' ')}',
      StepItem(:final step) => 'STEP: ${stepTitle(step.call)}${step.rejected ? ' [rejected]' : ''}',
      ExploreGroup(:final steps) => 'EXPLORED: ${steps.map((s) => stepTitle(s.call)).join(' | ')}',
      QuestionItem(:final answers) => 'QUESTION answered=${answers?.length}',
      PlanProposal(:final verdict) => 'PLAN ${verdict?.name}',
      NoticeItem(:final message) => 'NOTICE: $message',
      _ => '',
    },
].where((l) => l.isNotEmpty).join('\n');

void main() {
  final runs = int.tryParse(_env['EVAL_RUNS'] ?? '') ?? 1;
  final stamp = DateTime.now().millisecondsSinceEpoch;

  for (var n = 0; n < runs; n++) {
    test('question answers come back in the tool call ($n)', () async {
      final dir = _repo('q');
      final (t, extra) = await _run(
        AgentMode.ask,
        dir.path,
        'Write a hello-world program in this folder. First ask me with ask_user_question which language to use '
            '(offer Python, Ruby and Go, in that order), then create hello.<ext> in the language I pick and stop.',
        'held-q-$stamp-$n',
      );
      print(_dump(t));
      final files = dir.listSync().map((f) => f.uri.pathSegments.last).toList();
      print('files: $files; extra user messages: $extra; status ${t.status.name}');
      expect(extra, 0);
      expect(t.items.whereType<QuestionItem>().first.answers, isNotEmpty);
      expect(files, contains('hello.go'));
    }, timeout: Timeout.none);

    test('plan approval comes back in the tool call ($n)', () async {
      final dir = _repo('p');
      final (t, extra) = await _run(
        AgentMode.plan,
        dir.path,
        'Add greet.py with a function greet(name) that returns "Hello, <name>!". Look around first, then present '
            'a short plan with present_plan.',
        'held-p-$stamp-$n',
      );
      print(_dump(t));
      final files = dir.listSync().map((f) => f.uri.pathSegments.last).toList();
      print('files: $files; extra user messages: $extra; status ${t.status.name}');
      expect(extra, 0);
      expect(t.items.whereType<PlanProposal>().first.verdict, PlanVerdict.approved);
      expect(files, contains('greet.py'));
    }, timeout: Timeout.none);

    test('a plan revision comes back in the tool call ($n)', () async {
      final dir = _repo('r');
      final (t, extra) = await _run(
        AgentMode.plan,
        dir.path,
        'Add greet.py with a function greet(name) that returns "Hello, <name>!". Look around first, then present '
            'a short plan with present_plan.',
        'held-r-$stamp-$n',
        revision: 'Name the file salute.py instead, and add a test file for it.',
      );
      print(_dump(t));
      final files = dir.listSync().map((f) => f.uri.pathSegments.last).toList();
      print('files: $files; extra user messages: $extra; status ${t.status.name}');
      expect(extra, 0);
      expect(t.items.whereType<PlanProposal>().map((p) => p.verdict), [PlanVerdict.revised, PlanVerdict.approved]);
      expect(files, contains('salute.py'));
    }, timeout: Timeout.none);
  }
}
