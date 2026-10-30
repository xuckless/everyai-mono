// Live check: compaction keeps what matters. A short Full auto session
// records a fact, the older part is summarized through the gateway, and a
// continuation conversation (which starts without running) still knows the
// fact. Uses a private agent-server and backend. Run explicitly:
//
//   AGENT_SERVER_URL=http://127.0.0.1:P/ AGENT_SERVER_KEY=… \
//   GATEWAY_URL=http://127.0.0.1:Q/v1 GATEWAY_KEY=sk-eai-… WORKDIR=/tmp/empty-git-repo \
//   flutter test tool/agent_eval/compaction_check_test.dart
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';

import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/compaction.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/harness/openhands_harness.dart';
import 'package:every_ai/features/code/harness/summarizer.dart';
import 'package:flutter_test/flutter_test.dart';

const _model = 'anthropic/claude-haiku-5.5';

/// Collects [session]'s events, approves every action, and ends a turn when it finishes.
final class _Watch {
  _Watch(HarnessSession session) {
    session.events.listen((e) {
      if (e is StreamDelta || e is ConnectionChange) return;
      events.add(e);
      if (e is StateChange) {
        if (e.executionStatus == ExecutionStatus.running) _ran = true;
        // Full auto: the app approves everything (the server always asks).
        if (e.executionStatus == ExecutionStatus.waitingForConfirmation) unawaited(session.respond(accept: true));
        // The server passes through idle while an approval is answered; a turn ends at finished.
        if (_ran &&
            (e.executionStatus == ExecutionStatus.finished ||
                e.executionStatus == ExecutionStatus.error ||
                e.executionStatus == ExecutionStatus.stuck)) {
          _ran = false;
          final c = _turn;
          _turn = Completer<void>();
          c.complete();
        }
      }
    });
  }

  final events = <HarnessEvent>[];
  bool _ran = false;
  var _turn = Completer<void>();

  Future<void> nextTurn() => _turn.future.timeout(const Duration(minutes: 4));
}

void main() {
  final env = Platform.environment;
  final skip = env['AGENT_SERVER_URL'] == null ? 'live check: set AGENT_SERVER_URL and friends' : null;

  test(
    'a compacted session remembers the facts from before',
    skip: skip,
    timeout: const Timeout(Duration(minutes: 12)),
    () async {
      final harness = OpenHandsHarness(
        baseUrl: Uri.parse(env['AGENT_SERVER_URL']!),
        sessionApiKey: env['AGENT_SERVER_KEY']!,
      );
      SessionSpec spec(String first, {bool run = true}) => SessionSpec(
        workingDir: env['WORKDIR']!,
        model: _model,
        mode: AgentMode.fullAuto,
        llmBaseUrl: env['GATEWAY_URL']!,
        llmApiKey: env['GATEWAY_KEY']!,
        sessionTag: 'compaction-check',
        maxInputTokens: 200000,
        initialMessage: modeNote(AgentMode.fullAuto, first),
        runInitial: run,
      );

      final s1 = await harness.start(
        spec(
          'Create notes.txt with two lines: "code: PLUM-4417" and "owner: Dana Okafor". Then run `wc -l notes.txt` '
          'and reply with one short sentence.',
        ),
      );
      final w1 = _Watch(s1);
      await w1.nextTurn();
      await s1.send('Run `ls -la` and tell me how many entries it lists, in one sentence.');
      await w1.nextTurn();
      await s1.send('Now create hello.py that prints "hi", run it with python3, and reply in one sentence.');
      await w1.nextTurn();
      await s1.close();

      final plan = planCompaction(w1.events, budget: const CompactionBudget(tail: 3000))!;
      print('head ${plan.head.length} events, tail ${plan.tail.length} events');
      final summarize = gatewaySummarizer(
        baseUrl: env['GATEWAY_URL']!,
        apiKey: env['GATEWAY_KEY']!,
        sessionTag: 'compaction-check',
      );
      final summary = cleanSummary(await summarize(summaryRequest(plan, focus: 'the notes file contents')));
      print('--- summary ---\n$summary\n---');
      expect(summary, isNotNull);

      final message = continuationMessage(summary: summary!, recent: renderTail(plan));
      final s2 = await harness.start(spec(message, run: false));
      final w2 = _Watch(s2);
      await Future<void>.delayed(const Duration(seconds: 2));
      final first = w2.events.whereType<ChatMessage>().first;
      final b = TranscriptBuilder()..add(first);
      expect(b.snapshot.items.single, isA<NoticeItem>());
      expect(w2.events.whereType<ActionCall>(), isEmpty, reason: 'the continuation waits for the user');

      await s2.send(
        modeNote(
          AgentMode.fullAuto,
          'From memory, without running any tools: what is the code in notes.txt, who is the owner, '
          'and what does hello.py print?',
          full: false,
        ),
      );
      await w2.nextTurn();
      final reply = w2.events.whereType<ChatMessage>().where((m) => !m.fromUser).map((m) => m.text).join('\n');
      final finish = w2.events
          .whereType<ActionCall>()
          .where((c) => c.actionKind == 'FinishAction')
          .map((c) => c.str('message'))
          .join('\n');
      final answer = '$reply\n$finish';
      print('--- answer ---\n$answer\n---');
      print('tools used after compaction: ${w2.events.whereType<ActionCall>().map((c) => c.toolName).toList()}');
      expect(answer, contains('PLUM-4417'));
      expect(answer, contains('Dana'));
      await s2.close();
    },
  );
}
