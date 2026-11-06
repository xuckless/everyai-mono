import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/code/domain/plan_batches.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/drivers/driver_events.dart' show actionEvent;
import 'package:every_ai/features/code/workflows/workflow_prelude.dart' show batchJs;
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _b({Object? id = 'add-form', Object? intent = 'Add the form', Object? files, Object? check}) => {
  'id': id,
  'intent': intent,
  'files': files ?? ['lib/form.dart'],
  'check': ?check,
};

void main() {
  group('parseBatch', () {
    test('each check form parses, and a batch without one is not gated', () {
      final files = parseBatch(
        _b(
          check: {
            'files': ['test/form_test.dart'],
          },
        ),
      ).batch!;
      expect(files.id, 'add-form');
      expect(files.files, ['lib/form.dart']);
      expect((files.check! as FilesCheck).files, ['test/form_test.dart']);
      expect((parseBatch(_b(check: {'command': ' make test '})).batch!.check! as CommandCheck).command, 'make test');
      expect(parseBatch(_b(check: 'full')).batch!.check, isA<FullCheck>());
      expect(parseBatch(_b()).batch!.check, isNull);
      expect(parseBatch(_b(check: {'files': <String>[]})).batch!.toJson()['check'], {'files': <String>[]});
    });

    test('a flat check (present_plan, the Max skill) is normalised: blank keys drop, the one left is the check', () {
      BatchCheck? check(Object? c) => parseBatch(_b(check: c)).batch!.check;
      expect(check({'full': true}), isA<FullCheck>());
      expect(parseBatch(_b(check: 'full')).batch!.toJson()['check'], {'full': true});
      expect(
        (check({'files': <String>[], 'command': 'make test', 'full': false})! as CommandCheck).command,
        'make test',
      );
      expect(
        (check({
                  'files': ['test/a_test.dart'],
                  'command': '',
                  'full': null,
                })!
                as FilesCheck)
            .files,
        ['test/a_test.dart'],
      );
      expect(check({'full': false}), isNull);
      expect(check({}), isNull);
      expect(check(false), isNull);
    });

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

    test('parseBatches wants unique ids and drops the list on any problem', () {
      final ok = parseBatches([_b(id: 'a'), _b(id: 'b')]);
      expect([for (final b in ok.batches) b.id], ['a', 'b']);
      final dup = parseBatches([_b(id: 'a'), _b(id: 'a')]);
      expect(dup.batches, isEmpty);
      expect(dup.problems, [contains('batch 2: the id a is used twice')]);
      expect(parseBatches({}).problems, [contains('list')]);
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

    test('a plan without one, or with a broken one, has none', () {
      expect(batchesInMarkdown('# Plan\n```json\n[]\n```'), isNull);
      expect(batchesInMarkdown('```json batches\n[{"id": "a"\n```'), isNull);
      expect(batchesInMarkdown('```json batches\n[{"id": "A", "intent": "x"}]\n```'), isNull);
    });
  });

  // batchOf in the workflow prelude must agree with parseBatch; run it in node when there is one.
  final hasNode = Process.runSync('which', ['node']).exitCode == 0;
  test('the prelude batchOf accepts and refuses what parseBatch does', () async {
    final cases = <Object?>[
      _b(
        check: {
          'files': ['test/a_test.dart'],
        },
      ),
      _b(check: {'command': 'make test'}),
      _b(check: 'full'),
      _b(),
      _b(id: 'Bad'),
      _b(intent: ''),
      _b(files: ['../x']),
      _b(files: [r'C:\x']),
      _b(check: {'command': 'a\nb'}),
      _b(check: {'command': 'x', 'files': <String>[]}),
      _b(
        check: {
          'command': 'x',
          'files': ['a'],
        },
      ),
      _b(check: {'full': true}),
      _b(check: {'full': false, 'command': ''}),
      _b(check: {'full': 'yes'}),
      _b(check: {'tests': 1}),
      _b(check: {'command': ''}),
      _b(
        check: {
          'files': ['t.dart'],
          'command': '',
          'full': false,
        },
      ),
      _b(check: 'all'),
      _b(files: [' /abs/a.dart']),
      _b(files: [' lib/a.dart ']),
      _b(files: <String>[], check: 'full'),
      _b(files: <String>[], check: {'files': <String>[]}),
      [1],
    ];
    final dir = await Directory.systemTemp.createTemp('batch-of');
    addTearDown(() => dir.delete(recursive: true));
    File('${dir.path}/b.js').writeAsStringSync(
      'const __g = globalThis;\nconst agent = () => null;\n$batchJs\n'
      'console.log(JSON.stringify(${jsonEncode(cases)}.map((c) => { try { return __g.batchOf(c); } '
      'catch (e) { return null; } })));',
    );
    final r = await Process.run('node', ['${dir.path}/b.js']);
    if (r.exitCode != 0) fail('${r.stderr}');
    final js = jsonDecode('${r.stdout}') as List;
    for (final (i, c) in cases.indexed) {
      expect(js[i], parseBatch(c).batch?.toJson(), reason: jsonEncode(c));
    }
  }, skip: hasNode ? false : 'no node');
}
