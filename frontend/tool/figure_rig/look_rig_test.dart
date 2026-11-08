// Dev rig: runs the chat's `look` tool outside the app, so an agent can make figures and documents with the real
// tools' rules and see what the app shows. Not part of the test suite (it lives under tool/).
//
//   EVERYAI_LOOK_CALLS=calls.json EVERYAI_LOOK_ID=fig-x EVERYAI_LOOK_OUT=out/ \
//     flutter test tool/figure_rig/look_rig_test.dart
//
// EVERYAI_LOOK_SLIDE=N looks at one slide of a deck. svg_script calls run in Deno; out/script_N.txt says how
// call N went.
// calls.json: the chat's UI tool calls in order, [{"tool": "render_svg", "args": {...}}, ...]. The rig writes
// out/look.txt (what the model would read) and out/picture_N.png (what it would see). Mermaid needs the app's
// webview, so diagrams aren't drawn here.
import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/artifacts/checks/look.dart';
import 'package:every_ai/features/artifacts/export/svg_raster.dart';
import 'package:every_ai/features/artifacts/script/svg_script.dart';
import 'package:every_ai/features/chat/domain/message.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The app's fonts, and Geist for the families SVGs usually name, so text draws as in the app rather than
/// as the test font's boxes.
Future<void> _loadFonts() async {
  final manifest = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final family in manifest.cast<Map<String, Object?>>()) {
    final loader = FontLoader(family['family']! as String);
    for (final font in (family['fonts']! as List).cast<Map<String, Object?>>()) {
      loader.addFont(rootBundle.load(font['asset']! as String));
    }
    await loader.load();
  }
  // Serif text: the app takes Georgia from the system; the rig loads the Mac's copy.
  const georgia = '/System/Library/Fonts/Supplemental';
  if (File('$georgia/Georgia.ttf').existsSync()) {
    final loader = FontLoader('Georgia');
    for (final f in ['Georgia.ttf', 'Georgia Bold.ttf', 'Georgia Italic.ttf', 'Georgia Bold Italic.ttf']) {
      if (File('$georgia/$f').existsSync()) {
        loader.addFont(Future.value(ByteData.sublistView(File('$georgia/$f').readAsBytesSync())));
      }
    }
    await loader.load();
  }
  final noto = manifest.cast<Map<String, Object?>>().where((f) => f['family'] == 'Geist').firstOrNull;
  if (noto == null) return;
  for (final name in ['sans-serif', 'Arial', 'Helvetica', 'system-ui', 'Inter', 'Roboto']) {
    final loader = FontLoader(name);
    for (final font in (noto['fonts']! as List).cast<Map<String, Object?>>()) {
      loader.addFont(rootBundle.load(font['asset']! as String));
    }
    await loader.load();
  }
}

/// As the app's look draws (768 px across), with text in Geist. The app's SVG renderer takes a font-family list
/// as one name it doesn't have, so text there falls back to the system font; the test engine has none, so the rig
/// names a bundled font everywhere instead (monospace lists get Geist Mono).
Future<RasterFigure?> _rigRaster(String svg) => rasterizeSvg(_rigFonts(svg), maxWidth: 384, scale: 2);

String _rigFonts(String svg) {
  var out = svg.replaceAllMapped(RegExp(r'font-family\s*=\s*("[^"]*"|\x27[^\x27]*\x27)'), (m) {
    final mono = RegExp('mono|courier|consolas|menlo', caseSensitive: false).hasMatch(m.group(1)!);
    return 'font-family="${mono ? 'GeistMono' : 'Geist'}"';
  });
  out = out.replaceAllMapped(RegExp(r'font-family\s*:\s*[^;"]+'), (m) => 'font-family: Geist');
  final root = RegExp(r'<svg\b[^>]*>').firstMatch(out);
  if (root != null && !root.group(0)!.contains('font-family')) {
    out = out.replaceFirst('<svg', '<svg font-family="Geist"');
  }
  return out;
}

void main() {
  final calls = Platform.environment['EVERYAI_LOOK_CALLS'];
  final id = Platform.environment['EVERYAI_LOOK_ID'];
  final out = Platform.environment['EVERYAI_LOOK_OUT'];
  testWidgets('look', (tester) async {
    if (calls == null || id == null || out == null) {
      markTestSkipped('set EVERYAI_LOOK_CALLS, EVERYAI_LOOK_ID and EVERYAI_LOOK_OUT');
      return;
    }
    await tester.runAsync(() async {
      await _loadFonts();
      final list = (jsonDecode(File(calls).readAsStringSync()) as List).cast<Map<String, Object?>>();
      final dir = Directory(out)..createSync(recursive: true);
      // svg_script calls run for real (Deno, no permissions); their SVG becomes the call's result, as in the app.
      final results = <int, String>{};
      for (final (i, c) in list.indexed) {
        if (c['tool'] != svgScriptTool) continue;
        final run = await runSvgScript((c['args'] as Map?)?['code'] as String? ?? '');
        results[i] = jsonEncode({'svg': run.svg, 'error': run.error});
        File('${dir.path}/script_${i + 1}.txt')
            .writeAsStringSync('${run.error == null ? 'OK' : 'ERROR ${run.error}'}\n${run.output}\n');
      }
      final message = Message(
        id: 'rig',
        conversationId: 'rig',
        role: Role.assistant,
        createdAt: DateTime(2026),
        parts: [
          for (final (i, c) in list.indexed)
            ToolCallPart(
              toolName: c['tool']! as String,
              argumentsJson: jsonEncode(c['args']),
              callId: 'call_$i',
              resultJson: results[i],
            ),
        ],
      );
      final answer = await Looker(rasterize: _rigRaster, prepareSvg: _rigFonts).look(
        jsonEncode({'id': id, 'slide': ?int.tryParse(Platform.environment['EVERYAI_LOOK_SLIDE'] ?? '')}),
        [message],
      );
      for (final f in dir.listSync().whereType<File>().where((f) => f.path.contains('picture_'))) {
        f.deleteSync();
      }
      File('${dir.path}/look.txt').writeAsStringSync('${answer.isError ? 'ERROR ' : ''}${answer.text}\n');
      for (final (i, png) in answer.pictures.indexed) {
        File('${dir.path}/picture_${i + 1}.png').writeAsBytesSync(png);
      }
    });
  });
}
