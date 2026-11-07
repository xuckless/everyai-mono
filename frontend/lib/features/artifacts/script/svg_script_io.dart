import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../code/harness/everyai/script_io.dart' show findDeno;
import 'svg_script.dart';

/// The longest a program may run, and the most of its output that is kept.
const _timeout = Duration(seconds: 15);
const _maxOutput = 2 * 1024 * 1024;

/// Whether this install can run programs (it has Deno).
bool get svgScriptAvailable => findDeno() != null;

/// The prelude: the vetted libraries as globals, then the model's program. Deno runs it with no permissions at
/// all (no files, network, environment or subprocesses); local imports of these files are the only loading.
const _prelude = '''
import * as d3 from "./d3-shape.js";
import rough from "./rough.js";
const g = globalThis as Record<string, unknown>;
g.d3 = d3;
g.rough = rough;
g.roughGenerator = rough.generator();
await import("./program.ts");
''';

/// Runs [code] (TypeScript or JavaScript) in a fresh folder and returns the SVG it printed.
Future<SvgScriptRun> runSvgScript(String code) async {
  final deno = findDeno();
  if (deno == null) return (svg: null, output: '', error: 'this install of the app has no Deno to run programs.');
  final dir = await Directory.systemTemp.createTemp('everyai-svg-');
  try {
    await File('${dir.path}/d3-shape.js').writeAsString(await rootBundle.loadString('assets/svg_script/d3-shape.js'));
    await File('${dir.path}/rough.js').writeAsString(await rootBundle.loadString('assets/svg_script/rough.js'));
    await File('${dir.path}/prelude.ts').writeAsString(_prelude);
    await File('${dir.path}/program.ts').writeAsString(code);
    final process = await Process.start(
      deno,
      [
        'run',
        '--no-prompt',
        '--no-config',
        '--no-lock',
        '--no-remote',
        '--no-npm',
        '--quiet',
        '--v8-flags=--max-old-space-size=256',
        'prelude.ts',
      ],
      workingDirectory: dir.path,
      environment: {'DENO_DIR': '${dir.path}/.cache', 'NO_COLOR': '1'},
      includeParentEnvironment: false,
    );
    unawaited(process.stdin.close());
    final out = StringBuffer();
    final err = StringBuffer();
    void keep(StringBuffer to, String chunk) {
      if (to.length < _maxOutput) to.write(chunk);
    }

    final stdoutDone = process.stdout.transform(utf8.decoder).forEach((c) => keep(out, c));
    final stderrDone = process.stderr.transform(utf8.decoder).forEach((c) => keep(err, c));
    final code0 = await process.exitCode.timeout(
      _timeout,
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    await Future.wait([stdoutDone, stderrDone]).timeout(const Duration(seconds: 2), onTimeout: () => const []);
    final text = out.toString();
    final svg = RegExp(r'<svg[\s\S]*</svg>').allMatches(text).lastOrNull?.group(0);
    final printed = svg == null ? text : text.replaceFirst(svg, '[the SVG]');
    final error = code0 == -1
        ? 'it ran past ${_timeout.inSeconds} s and was stopped.'
        : code0 != 0
        ? _cleanError(err.toString(), dir.path)
        : svg == null
        ? 'it printed no <svg>…</svg>; print the finished SVG with console.log.'
        : null;
    return (svg: svg, output: printed.trim(), error: error);
  } finally {
    unawaited(dir.delete(recursive: true).catchError((Object _) => dir));
  }
}

/// Deno's error without the temp folder's paths.
String _cleanError(String stderr, String dir) {
  final text = stderr.replaceAll('file://$dir/', '').replaceAll('$dir/', '').trim();
  return text.length > 2000 ? '${text.substring(0, 2000)}…' : (text.isEmpty ? 'it failed.' : text);
}
