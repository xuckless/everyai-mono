import 'dart:convert';

/// Rubric dimensions, each scored 1-5 (defects: 5 = none).
const rubricDimensions = ['prompt_match', 'recognizability', 'composition', 'color_harmony', 'polish', 'defects'];

/// Our own rubric wording. The image attached is the rendered figure.
String judgePrompt(String request) =>
    '''
You are judging a vector illustration made by an automated system. You see only the rendered picture.
The request was: "$request"

Score each dimension from 1 (poor) to 5 (excellent), using the whole range and being strict:
- prompt_match: does it show what was asked, including every named element, count and color?
- recognizability: would a stranger name the subject at a glance, and at thumbnail size?
- composition: balance, focal point, sensible scale and spacing, nothing cropped by the edges.
- color_harmony: a coherent palette, enough contrast, no muddy or clashing areas.
- polish: clean consistent shapes, intentional detail, depth; looks designed rather than generated.
- defects: 5 means none. Lower it for detached parts, shapes hidden behind same-colored shapes, wrong layering, broken proportions, overlapping text, or empty areas.
Also list up to five concrete defects you can see.

Reply with ONLY this JSON, no prose and no code fence:
{"prompt_match":int,"recognizability":int,"composition":int,"color_harmony":int,"polish":int,"defects":int,"defect_list":[string],"notes":string}''';

/// Prompt for comparing two renders; the judge sees image A then image B.
String pairwisePrompt(String request) =>
    '''
Two vector illustrations answer the same request: "$request"
Image 1 is the first picture, image 2 the second. Decide which is better overall (match to the request, composition, color, polish, fewer defects).
Reply with ONLY this JSON: {"winner":"1"|"2"|"tie","reason":string}''';

class JudgeScore {
  const JudgeScore(this.scores, this.defectList, this.notes);

  final Map<String, int> scores;
  final List<String> defectList;
  final String notes;

  double get mean => scores.values.fold<int>(0, (a, b) => a + b) / scores.length;

  Map<String, Object?> toJson() => {...scores, 'mean': mean, 'defect_list': defectList, 'notes': notes};
}

/// Parses a judge reply. Tolerates a code fence or surrounding prose; clamps
/// scores to 1-5; returns null if any dimension is missing or not a number.
JudgeScore? parseJudge(String reply) {
  final start = reply.indexOf('{');
  final end = reply.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(reply.substring(start, end + 1));
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final scores = <String, int>{};
  for (final d in rubricDimensions) {
    final v = decoded[d];
    if (v is! num) return null;
    scores[d] = v.round().clamp(1, 5);
  }
  final list = decoded['defect_list'];
  return JudgeScore(scores, [if (list is List) ...list.map((e) => '$e')], '${decoded['notes'] ?? ''}');
}

/// Pairwise result mapped back through the order swap: `+1` if [first] wins.
/// [swapped] means the first condition was shown as image 2.
int pairwiseOutcome(String reply, {required bool swapped}) {
  final m = RegExp(r'"winner"\s*:\s*"?(1|2|tie)"?').firstMatch(reply);
  if (m == null || m.group(1) == 'tie') return 0;
  final firstWon = (m.group(1) == '1') != swapped;
  return firstWon ? 1 : -1;
}

/// One finished cell of the grid.
class CellResult {
  const CellResult({
    required this.condition,
    required this.promptId,
    required this.sample,
    required this.pass,
    this.score,
    this.micros = 0,
    this.bytes = 0,
  });

  final String condition;
  final int promptId;
  final int sample;
  final bool pass;
  final double? score;
  final int micros;
  final int bytes;
}

class ConditionSummary {
  const ConditionSummary(this.condition, this.n, this.passRate, this.meanScore, this.meanMicros);

  final String condition;
  final int n;
  final double passRate;
  final double meanScore;
  final double meanMicros;
}

/// Per-condition pass rate, mean judge score (scored cells only) and mean cost.
List<ConditionSummary> summarize(List<CellResult> cells) {
  final by = <String, List<CellResult>>{};
  for (final c in cells) {
    (by[c.condition] ??= []).add(c);
  }
  return [
    for (final e in by.entries)
      ConditionSummary(
        e.key,
        e.value.length,
        e.value.where((c) => c.pass).length / e.value.length,
        _mean([
          for (final c in e.value)
            if (c.score != null) c.score!,
        ]),
        _mean([for (final c in e.value) c.micros.toDouble()]),
      ),
  ];
}

double _mean(List<double> xs) => xs.isEmpty ? 0 : xs.reduce((a, b) => a + b) / xs.length;

/// The decision rule: ship the critique round when it gains at least 0.5
/// judge points over [base] at under twice the cost; ship the vector engine
/// when it beats [reference] by 0.5.
bool ships(ConditionSummary candidate, ConditionSummary base, {double gain = 0.5, double maxCostRatio = 2}) {
  final cheapEnough = base.meanMicros <= 0 || candidate.meanMicros < base.meanMicros * maxCostRatio;
  return candidate.meanScore - base.meanScore >= gain && cheapEnough;
}
