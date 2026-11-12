import 'package:every_ai/features/code/domain/plan_batches.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/drivers/driver_events.dart' show actionEvent;
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _b({Object? id = 'add-form', Object? intent = 'Add the form', Object? files, Object? check}) => {
  'id': id,
  'intent': intent,
  'files': files ?? ['lib/form.dart'],
  'check': ?check,
};

void main() {
  group('parseBatch', () {
    test('bad ids, empty intents, paths out of the project and bad checks are refused readably', () {
      List<String> problems(Map<String, Object?> json) => parseBatch(json).problems;
      expect(problems(_b(id: 'Add Form')), [contains('id must be a short slug')]);
      expect(problems(_b(id: 'x' * 33)), [contains('id must be')]);
      expect(problems(_b(intent: '  ')), [contains('intent')]);
      expect(problems(_b(files: ['../secret'])), [contains('may not contain ..')]);
      expect(problems(_b(files: ['/etc/passwd'])), [contains('relative')]);
      expect(
        problems(
          _b(
            check: {
              'files': ['a/../../b'],
            },
          ),
        ),
        [startsWith('check.files:')],
      );
      expect(problems(_b(check: {'command': ''})), [contains('non-empty')]);
      expect(problems(_b(check: {'command': 'a\nb'})), [contains('one line')]);
      expect(
        problems(
          _b(
            check: {
              'command': 'x',
              'files': ['t_test.dart'],
            },
          ),
        ),
        [contains('give one of files, command')],
      );
      expect(problems(_b(check: {'full': 'yes'})), [contains('check.full must be true')]);
      expect(problems(_b(check: {'tests': <String>[]})), [contains('unknown key tests')]);
      expect(problems(_b(check: 'all')), [contains('check must be')]);
      expect(parseBatch('nope').problems, [contains('object')]);
      // A path is checked as it is kept: trimmed.
      expect(problems(_b(files: [' /Users/x/a.dart'])), [contains('relative')]);
      expect(
        problems(
          _b(
            check: {
              'files': [' ~/a_test.dart'],
            },
          ),
        ),
        [startsWith('check.files:')],
      );
      // A check that finds its tests from the batch's files needs some.
      expect(problems(_b(files: <String>[], check: 'full')), [contains('needs the batch')]);
      expect(problems(_b(files: <String>[], check: {'files': <String>[]})), [contains('needs the batch')]);
      expect(parseBatch(_b(files: <String>[], check: {'command': 'make test'})).batch, isNotNull);
      expect(parseBatch(_b(id: 'Bad', intent: '')).problems, hasLength(2));
    });
  });

  test('present_plan steps take the same flat check; a plan_ref names only a file in .everyai/plans/', () {
    final plan = PlanProposal(
      actionEvent(
        id: 'p',
        toolName: 'present_plan',
        kind: 'PresentPlanAction',
        args: {
          'title': 'T',
          'steps': [
            {
              'id': 'a',
              'title': 'A',
              'files': ['lib/a.dart'],
              'check': {'full': true, 'files': <String>[]},
            },
            {
              'id': 'b',
              'title': 'B',
              'files': ['lib/b.dart'],
              'check': {'command': 'make b', 'full': false},
            },
            {'title': 'plain'},
          ],
        },
      ),
    );
    expect(
      [for (final b in plan.batches) b.toJson()['check']],
      [
        {'full': true},
        {'command': 'make b'},
      ],
    );
    expect(planFileName('2026-11-05-x.md'), '2026-11-05-x.md');
    expect(planFileName('.everyai/plans/2026-11-05-x.md'), '2026-11-05-x.md');
    expect(planFileName('/Users/me/p/.everyai/plans/x.md'), 'x.md');
    for (final bad in ['../x.md', 'other/x.md', 'x.txt', '', 3, null]) {
      expect(planFileName(bad), isNull, reason: '$bad');
    }
  });

  group('the batches fence', () {
    test('round-trips through a plan', () {
      final batches = parseBatches([
        _b(
          id: 'a',
          check: {
            'files': ['test/a_test.dart'],
          },
        ),
        _b(id: 'b', check: 'full'),
        _b(id: 'c'),
      ]).batches;
      final md = '# Plan\n\n1. A\n\n## Batches\n${batchesFence(batches)}\n';
      final back = batchesInMarkdown(md)!;
      expect([for (final b in back) b.toJson()], [for (final b in batches) b.toJson()]);
    });
  });
}
