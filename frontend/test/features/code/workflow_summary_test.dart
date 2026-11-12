import 'package:every_ai/features/code/workflows/workflow_engine.dart';
import 'package:every_ai/features/code/workflows/workflow_summary.dart';
import 'package:flutter_test/flutter_test.dart';

WorkflowRun _run(Object? result, {String name = 'Bug fix', int micros = 0, Duration? took, String? error}) =>
    WorkflowRun(
      runId: 'r',
      name: name,
      state: const RunEnded(WorkflowOutcome.done),
      started: 3,
      spentMicros: micros,
      took: took,
      result: result,
      error: error,
    );

void main() {
  test('a bug fix reads verdict first, with each field once', () {
    final text = workflowSummary(
      _run({
        'verified': true,
        'cause': 'The parser drops the last line',
        'fix_summary': 'Keep the last line',
        'repro_command': 'dart test a_test.dart',
        'proof': 'bug_check',
        'files': ['lib/parser.dart', 'test/parser_test.dart'],
        'commits': ['abc1234 fix'],
        'review': {
          'verdict': 'ship',
          'findings': [
            {
              'severity': 'minor',
              'lenses': ['a', 'b'],
            },
          ],
        },
        'refix': {'verified': true},
      }),
    );
    expect(text, contains('Outcome: fixed and proved'));
    expect(text, contains('Proof: bug_check · dart test a_test.dart'));
    expect(text, contains('Files: lib/parser.dart, test/parser_test.dart'));
    expect(text, contains('Review: ship · 1 minor, merged from 2 lenses'));
    for (final once in ['The parser drops the last line', 'Keep the last line', 'dart test a_test.dart']) {
      expect(once.allMatches(text), hasLength(1), reason: once);
    }
    expect(text, isNot(contains('abc1234')));
    expect(text, contains('Commits: 1'));
  });
}
