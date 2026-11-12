import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../../core/process/supervisor.dart';
import '../../code/harness/everyai/script_io.dart' show findDeno;
import 'svg_script.dart';

/// The longest a program may run, and the most of its output that is kept.
const _timeout = Duration(seconds: 15);
const _maxOutput = 2 * 1024 * 1024;

/// Whether this install can run programs (it has Deno).
bool get svgScriptAvailable => findDeno() != null;

/// The prelude: the vetted libraries as globals, then the model's program. Deno runs it with no permissions at
/// all (no files, network, environment or subprocesses), and the import map keeps module loading inside the run's
/// folder.
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
    // Deno loads local modules whatever the permissions (also with --deny-read and through import() or eval), so the
    // import map sends every file URL outside this folder to a remote address, which --no-remote refuses.
    final own = Uri.directory(dir.resolveSymbolicLinksSync()).toString();
    await File('${dir.path}/imports.json').writeAsString(
      jsonEncode({
        'imports': {'file:///': 'https://blocked.invalid/', '/': 'https://blocked.invalid/', own: own},
      }),
    );
    final r = await ProcessSupervisor.instance.runBounded(
      deno,
      const [
        'run',
        '--no-prompt',
        '--no-config',
        '--no-lock',
        '--no-remote',
        '--no-npm',
        '--quiet',
        '--v8-flags=--max-old-space-size=256',
        '--import-map=imports.json',
        'prelude.ts',
      ],
      timeout: _timeout,
      cwd: dir.path,
      env: {'DENO_DIR': '${dir.path}/.cache', 'NO_COLOR': '1'},
      includeParentEnvironment: false,
      kind: ProcessKind.script,
      owner: const ProbeOwner('svg_script'),
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
      maxOutputBytes: _maxOutput,
      label: 'svg_script',
    );
    final String text;
    final String? failed;
    switch (r) {
      case Finished(:final code, :final stdout, :final stderr):
        text = stdout;
        failed = code != 0 ? _cleanError(stderr, dir.path) : null;
      case TimedOut(:final kill, :final stdout):
        text = stdout;
        failed =
            'it ran past ${_timeout.inSeconds} s and was stopped'
            '${kill is Ended ? '' : ', but it is not closed ($kill)'}.';
      case Cancelled() || StartFailed() || Refused():
        text = '';
        failed = "it didn't run: $r";
    }
    // Only the last <svg> printed counts.
    final svg = RegExp(r'<svg[\s\S]*?</svg>').allMatches(text).lastOrNull?.group(0);
    final printed = svg == null ? text : text.replaceFirst(svg, '[the SVG]');
    final error =
        failed ?? (svg == null ? 'it printed no <svg>…</svg>; print the finished SVG with console.log.' : null);
    return (svg: svg, output: printed.trim(), error: error);
  } finally {
    unawaited(dir.delete(recursive: true).catchError((Object _) => dir));
  }
}

/// Deno's error without the temp folder's paths.
String _cleanError(String stderr, String dir) {
  // Deno names the real path (/private/var/… on macOS), not the temp folder's link.
  var text = stderr;
  for (final d in {Directory(dir).resolveSymbolicLinksSync(), dir}) {
    text = text.replaceAll('file://$d/', '').replaceAll('$d/', '');
  }
  text = text.trim();
  return text.length > 2000 ? '${text.substring(0, 2000)}…' : (text.isEmpty ? 'it failed.' : text);
}
