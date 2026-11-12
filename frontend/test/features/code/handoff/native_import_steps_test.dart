import 'dart:convert';

import 'package:every_ai/features/code/drivers/driver_events.dart' show stateEvent;
import 'package:every_ai/features/code/handoff/handoff.dart';
import 'package:every_ai/features/code/handoff/native/import_steps.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:flutter_test/flutter_test.dart';

import 'native_source.dart';

String _show(ImportStep s) => switch (s) {
  UserStep(:final text, :final ours) => '${ours ? 'note' : 'user'}: ${text.split('\n').first}',
  AgentStep(:final text) => 'agent: $text',
  CallStep(:final kind, :final result, :final finished) => 'call $kind${finished ? '' : ' (unfinished)'}: $result',
};

/// The characters [steps] write: every text, call argument and result.
int _size(List<ImportStep> steps) => steps.fold(
  0,
  (n, s) =>
      n +
      switch (s) {
        UserStep(:final text) || AgentStep(:final text) => text.length,
        CallStep(:final args, :final result) => jsonEncode(args).length + result.length,
      },
);

void main() {
  test('the cut turn round-trips: its calls, no closing reply, an error result, then the facts with <cut-turn>', () {
    final s = source();
    final steps = importSteps(s, into: 'Codex')!;
    expect(s.handoff.cut, isNotNull);
    final last = steps.last as UserStep;
    // The facts keep the cut request but not what the history above holds: the cut calls and the latest turns.
    expect(last.text, contains('<cut-turn>'));
    expect(last.text, contains('Now make bye.txt containing MANGO'));
    expect(last.text, contains('(2 earlier calls left out to keep this short; the transcript file has them.)'));
    expect(last.text, isNot(contains('<recent-turns>')));
    expect(last.text, isNot(contains('echo MANGO')));
    expect(handoffMessage(s.handoff, fromName: 'Claude Code'), contains('echo MANGO'));
    expect((steps.first as UserStep).text, contains('the calls made for it so far are the last ones'));
    expect(carryOnMessage('Claude Code', cut: true), contains('<cut-turn> above'));
    final before = steps[steps.length - 2] as CallStep;
    expect((before.finished, before.isError, before.result), (false, true, notFinishedResult));
    expect(steps.whereType<AgentStep>().map((a) => a.text), ['Created hello.txt with PINEAPPLE.']);
  });

  test('secrets: a .env read is withheld, a key in the user text redacted', () {
    final steps = importSteps(
      source(
        from: [
          (
            lead: 'EveryAI',
            conversationId: 'c',
            events: [
              user('u1', 'Use API_KEY=abcdef1234567890 for the client'),
              call('c1', 'terminal', {'kind': 'TerminalAction', 'command': 'cat .env'}),
              result('c1', 'OPENAI=whatever-value-123'),
              agent('a1', 'The token is sk-abcdefghijklmnopqrstuvwxyz'),
            ],
          ),
        ],
      ),
      into: 'Claude Code',
    )!;
    final all = steps.map(_show).join('\n');
    expect(all, contains('API_KEY=(redacted)'));
    expect(all, isNot(contains('abcdef1234567890')));
    expect(all, isNot(contains('whatever-value-123')));
    expect(all, isNot(contains('sk-abcdefghijklmnopqrstuvwxyz')));
  });

  test('caps: one result and one argument are cut, old turns give way with a note pointing at the transcript', () {
    final big = 'x' * (handoffTranscriptResultChars + 500);
    final turns = [
      for (var i = 0; i < 40; i++) ...[
        user('u$i', 'request $i'),
        call('c$i', 'file_editor', {
          'kind': 'FileEditorAction',
          'command': 'create',
          'path': '$cwd/f$i.txt',
          'file_text': 'y' * 9000,
        }),
        result('c$i', big),
        agent('a$i', 'done $i'),
        stateEvent('s$i', ExecutionStatus.finished),
      ],
    ];
    final steps = importSteps(source(from: [(lead: 'EveryAI', conversationId: 'c', events: turns)]), into: 'Codex')!;
    final calls = steps.whereType<CallStep>().toList();
    expect(calls.first.result.length, lessThan(handoffTranscriptResultChars + 100));
    expect(calls.first.str('file_text').length, lessThan(nativeImportArgChars + 100));
    expect(_size(steps), lessThan(nativeImportMaxChars));
    final dropped = 40 - importedTurns(steps);
    expect(dropped, greaterThan(0));
    expect(
      (steps[1] as UserStep).text,
      '($dropped earlier turns are left out to keep this short; the whole conversation is in .everyai/handoffs/x.md.)',
    );
    expect(steps.whereType<UserStep>().where((s) => !s.ours).last.text, 'request 39');
  });
}
