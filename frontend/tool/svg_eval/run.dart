// Headless SVG eval runner. DRY by default: prints the grid and a cost
// estimate. Pass --live to call the backend (costs money; see README.md).
//
//   dart run tool/svg_eval/run.dart [--live] [--models a,b] [--judge m]
//       [--samples 3] [--prompts 1,2,8] [--conditions baseline,brief]
//       [--api http://127.0.0.1:8080] [--out build/svg_eval]
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'conditions.dart';
import 'gate.dart';
import 'judge.dart';
import 'prompts.dart';

/// Rough per-call costs in micro-dollars (Haiku-class generation, ~1.5k output
/// tokens; judge with one 768 px image; polish capped by the backend at 50k).
const estGenerateMicros = 9000;
const estJudgeMicros = 3500;
const estPolishMicros = 12000;
const estVectorMicros = 40000;

class Plan {
  Plan(this.prompts, this.conditions, this.models, this.samples);

  final List<EvalPrompt> prompts;
  final List<Condition> conditions;
  final List<String> models;
  final int samples;

  /// Cells: LLM conditions run per model, the vector engine once.
  int get cells {
    var n = 0;
    for (final c in conditions) {
      n += prompts.length * samples * (c.usesLlm ? models.length : 1);
    }
    return n;
  }

  /// Estimated spend in dollars, judging every cell once.
  double get estimateUsd {
    var micros = 0;
    for (final c in conditions) {
      final per = switch (c) {
        Condition.recraft => estVectorMicros,
        Condition.briefPolish => estGenerateMicros + estPolishMicros,
        _ => estGenerateMicros,
      };
      final n = prompts.length * samples * (c.usesLlm ? models.length : 1);
      micros += n * (per + estJudgeMicros);
    }
    return micros / 1e6;
  }
}

class Client {
  Client(this.base, [this.token]);

  final String base;
  final String? token;
  final _http = http.Client();

  Map<String, String> get _headers => {
    'content-type': 'application/json',
    if (token != null) 'authorization': 'Bearer $token',
  };

  /// One chat turn; returns the text and the charged micro-dollars.
  Future<(String, int)> chat(String model, List<Map<String, Object?>> messages, String session) async {
    final req = http.Request('POST', Uri.parse('$base/v1/chat/stream'))
      ..headers.addAll(_headers)
      ..body = jsonEncode({
        'model': model,
        'mode': 'chat',
        'messages': messages,
        'tools_enabled': false,
        'session': session,
      });
    final res = await _http.send(req);
    if (res.statusCode != 200) throw StateError('chat ${res.statusCode}: ${await res.stream.bytesToString()}');
    final text = StringBuffer();
    var micros = 0;
    String? event;
    await for (final line in res.stream.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.startsWith('event:')) {
        event = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        final d = jsonDecode(line.substring(5)) as Map<String, dynamic>;
        if (event == 'delta') text.write(d['text']);
        if (event == 'usage') micros += (d['charged_micros'] as num?)?.toInt() ?? 0;
        if (event == 'error') throw StateError('${d['message']}');
      }
    }
    return (text.toString(), micros);
  }

  Future<(String, int)> vector(String prompt, String session) async {
    final res = await _http.post(
      Uri.parse('$base/v1/images'),
      headers: _headers,
      body: jsonEncode({'engine': 'vector', 'prompt': prompt, 'aspect_ratio': '1:1', 'session': session}),
    );
    if (res.statusCode != 200) throw StateError('images ${res.statusCode}: ${res.body}');
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    final svg = utf8.decode(base64Decode(j['data'] as String));
    return (svg, (j['charged_micros'] as num?)?.toInt() ?? 0);
  }

  Future<(String, int)> polish(String svg, List<int> png, String brief, String session) async {
    final res = await _http.post(
      Uri.parse('$base/v1/figures/polish'),
      headers: _headers,
      body: jsonEncode({'svg': svg, 'png_base64': base64Encode(png), 'brief': brief, 'session': session}),
    );
    if (res.statusCode != 200) throw StateError('polish ${res.statusCode}: ${res.body}');
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    return (j['svg'] as String, (j['charged_micros'] as num?)?.toInt() ?? 0);
  }

  void close() => _http.close();
}

List<T> _pick<T>(String? csv, List<T> all, String Function(T) key) {
  if (csv == null) return all;
  final want = csv.split(',').map((s) => s.trim()).toSet();
  return all.where((x) => want.contains(key(x))).toList();
}

Plan planFrom(Map<String, String> args) {
  final prompts = _pick(args['prompts'], evalPrompts, (p) => '${p.id}');
  final conds = _pick(args['conditions'], Condition.values, (c) => c.key);
  final models = (args['models'] ?? 'anthropic/claude-haiku-5.5').split(',');
  return Plan(prompts, conds, models, int.tryParse(args['samples'] ?? '') ?? 3);
}

Map<String, String> parseArgs(List<String> argv) {
  final out = <String, String>{};
  for (var i = 0; i < argv.length; i++) {
    if (!argv[i].startsWith('--')) continue;
    final k = argv[i].substring(2);
    final hasValue = i + 1 < argv.length && !argv[i + 1].startsWith('--');
    out[k] = hasValue ? argv[++i] : 'true';
  }
  return out;
}

Future<void> main(List<String> argv) async {
  final args = parseArgs(argv);
  final plan = planFrom(args);
  print(
    '${plan.prompts.length} prompts x ${plan.conditions.length} conditions, ${plan.samples} samples, '
    'models ${plan.models.join(', ')}: ${plan.cells} cells, about \$${plan.estimateUsd.toStringAsFixed(2)}.',
  );
  if (args['live'] != 'true') {
    print('Dry run. Add --live to call the backend.');
    return;
  }
  final judgeModel = args['judge'] ?? 'google/gemini-3.5-flash';
  final rsvg = await hasRsvg();
  if (!rsvg) print('rsvg-convert not found: structural gate only, no judging, no polish.');
  final client = Client(args['api'] ?? 'http://127.0.0.1:8080', args['token']);
  final out = Directory(args['out'] ?? 'build/svg_eval')..createSync(recursive: true);
  final cells = <CellResult>[];
  final session = 'svg-eval-${DateTime.now().millisecondsSinceEpoch}';
  final firstOutputs = <String, String>{}; // "<model>/<cond>/<prompt>" -> svg, for the edit prompt

  for (final cond in plan.conditions) {
    for (final model in cond.usesLlm ? plan.models : ['vector']) {
      for (final p in plan.prompts) {
        for (var s = 0; s < plan.samples; s++) {
          var micros = 0;
          String? svg;
          try {
            if (cond == Condition.recraft) {
              final r = await client.vector(p.text, session);
              svg = r.$1;
              micros += r.$2;
            } else {
              final messages = <Map<String, Object?>>[];
              final base = p.editOf == null ? null : firstOutputs['$model/${cond.key}/${p.editOf}'];
              if (p.editOf != null && base != null) {
                final prev = evalPrompts.firstWhere((e) => e.id == p.editOf);
                messages
                  ..add({'role': 'user', 'content': promptFor(cond, prev)})
                  ..add({'role': 'assistant', 'content': '```svg\n$base\n```'});
                messages.add({'role': 'user', 'content': p.text});
              } else {
                messages.add({'role': 'user', 'content': promptFor(cond, p)});
              }
              final r = await client.chat(model, messages, session);
              svg = extractSvg(r.$1);
              micros += r.$2;
              if (svg != null && cond.polishes && rsvg) {
                final png = await rasterize(svg);
                if (png != null) {
                  final pr = await client.polish(svg, png, p.text, session);
                  svg = pr.$1;
                  micros += pr.$2;
                }
              }
            }
          } on Object catch (e) {
            print('  ${cond.key} $model #${p.id}/$s failed: $e');
          }
          final gate = svg == null ? null : await runGate(svg, rsvg: rsvg);
          double? score;
          if (svg != null && gate!.pass && rsvg) {
            final png = await rasterize(svg);
            if (png != null) {
              final r = await client.chat(judgeModel, [
                {
                  'role': 'user',
                  'content': [
                    {'type': 'text', 'text': judgePrompt(p.text)},
                    {
                      'type': 'image_url',
                      'image_url': {'url': 'data:image/png;base64,${base64Encode(png)}'},
                    },
                  ],
                },
              ], session);
              score = parseJudge(r.$1)?.mean;
            }
          }
          if (svg != null && s == 0) {
            firstOutputs['$model/${cond.key}/${p.id}'] = svg;
            File('${out.path}/${cond.key}_${model.replaceAll('/', '_')}_${p.id}.svg').writeAsStringSync(svg);
          }
          cells.add(
            CellResult(
              condition: cond.key,
              promptId: p.id,
              sample: s,
              pass: gate?.pass ?? false,
              score: score,
              micros: micros,
              bytes: gate?.bytes ?? 0,
            ),
          );
        }
      }
    }
  }
  client.close();
  final summary = summarize(cells);
  for (final s in summary) {
    print(
      '${s.condition.padRight(14)} n=${s.n} pass=${(s.passRate * 100).toStringAsFixed(0)}% '
      'score=${s.meanScore.toStringAsFixed(2)} cost=${s.meanMicros.toStringAsFixed(0)}µ\$',
    );
  }
  File('${out.path}/summary.json').writeAsStringSync(
    jsonEncode([
      for (final s in summary)
        {'condition': s.condition, 'n': s.n, 'pass_rate': s.passRate, 'score': s.meanScore, 'micros': s.meanMicros},
    ]),
  );
}
