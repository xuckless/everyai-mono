import 'package:flutter_test/flutter_test.dart';

import '../../tool/svg_eval/conditions.dart';
import '../../tool/svg_eval/gate.dart';
import '../../tool/svg_eval/judge.dart';
import '../../tool/svg_eval/prompts.dart';
import '../../tool/svg_eval/run.dart';

const _good = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><g id="a"><path d="M0 0L5 5"/></g></svg>';

void main() {
  test('twenty prompts with unique ids and valid references', () {
    expect(evalPrompts, hasLength(20));
    expect(evalPrompts.map((p) => p.id).toSet(), hasLength(20));
    for (final p in evalPrompts) {
      if (p.preset != null) expect(stylePresets, contains(p.preset));
      if (p.editOf != null) expect(evalPrompts.any((e) => e.id == p.editOf), isTrue);
    }
  });

  test('conditions build progressively richer prompts', () {
    final p = evalPrompts.first;
    expect(promptFor(Condition.baseline, p), startsWith('Draw this as SVG'));
    expect(promptFor(Condition.brief, p), contains('vector illustrator'));
    expect(promptFor(Condition.briefPreset, p), contains(stylePresets['line_icon']!));
    expect(promptFor(Condition.brief, p), isNot(contains(stylePresets['line_icon']!)));
    expect(promptFor(Condition.briefPreset, p), endsWith(p.text));
    expect(Condition.recraft.usesLlm, isFalse);
  });

  test('extractSvg prefers the last fence, falls back to a bare span', () {
    expect(extractSvg('plan\n```svg\n$_good\n```\ndone'), _good);
    expect(extractSvg('here: $_good thanks'), _good);
    expect(extractSvg('no figure'), isNull);
  });

  group('checkStructure', () {
    test('accepts a clean figure and counts paths', () {
      final r = checkStructure(_good);
      expect(r.parses, isTrue);
      expect(r.paths, 1);
      expect(r.problems, isEmpty);
    });

    test('rejects unbalanced, wrong root, and unsafe content', () {
      expect(checkStructure('<svg xmlns="x" viewBox="0 0 1 1"><g></svg>').parses, isFalse);
      expect(checkStructure('<div></div>').parses, isFalse);
      expect(checkStructure(_good.replaceFirst('<g', '<script/><g')).parses, isFalse);
      expect(checkStructure(_good.replaceFirst('<g id', '<g onclick="x()" id')).parses, isFalse);
      expect(checkStructure(_good.replaceFirst('<g', '<use href="https://e.com/a.svg"/><g')).parses, isFalse);
    });

    test('flags a missing viewBox without failing the parse', () {
      final r = checkStructure('<svg xmlns="http://www.w3.org/2000/svg"><rect/></svg>');
      expect(r.parses, isTrue);
      expect(r.problems, contains('missing viewBox'));
    });
  });

  group('judge', () {
    const reply =
        '{"prompt_match":4,"recognizability":5,"composition":3,"color_harmony":4,"polish":2,"defects":9,"defect_list":["a"],"notes":"ok"}';

    test('parses, clamps, and averages', () {
      final s = parseJudge('```json\n$reply\n```')!;
      expect(s.scores['defects'], 5);
      expect(s.mean, closeTo((4 + 5 + 3 + 4 + 2 + 5) / 6, 1e-9));
      expect(s.defectList, ['a']);
    });

    test('rejects replies missing a dimension', () {
      expect(parseJudge('{"prompt_match":4}'), isNull);
      expect(parseJudge('nope'), isNull);
    });

    test('pairwise accounts for the order swap', () {
      expect(pairwiseOutcome('{"winner":"1"}', swapped: false), 1);
      expect(pairwiseOutcome('{"winner":"1"}', swapped: true), -1);
      expect(pairwiseOutcome('{"winner":"tie"}', swapped: true), 0);
    });

    test('summary and ship rule', () {
      final s = summarize([
        for (var i = 0; i < 4; i++)
          CellResult(condition: 'a', promptId: i, sample: 0, pass: i < 3, score: 3, micros: 100),
        for (var i = 0; i < 4; i++)
          CellResult(condition: 'b', promptId: i, sample: 0, pass: true, score: 4, micros: 150),
      ]);
      expect(s.first.passRate, 0.75);
      expect(ships(s[1], s[0]), isTrue);
      expect(ships(s[1], s[0], gain: 1.5), isFalse);
      expect(ships(s[1], s[0], maxCostRatio: 1.2), isFalse);
    });
  });

  test('dry-run plan counts cells and estimates cost', () {
    final plan = planFrom(parseArgs(['--samples', '1', '--models', 'a,b']));
    // 4 LLM conditions x 20 prompts x 2 models + 20 vector.
    expect(plan.cells, 4 * 20 * 2 + 20);
    expect(plan.estimateUsd, greaterThan(1));
    expect(planFrom(parseArgs(['--prompts', '1,8', '--conditions', 'baseline'])).cells, 2 * 3);
  });
}
