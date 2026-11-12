import 'dart:convert';
import 'dart:typed_data';

import 'package:every_ai/features/artifacts/checks/diagram_render.dart';
import 'package:every_ai/features/artifacts/checks/tool_checks.dart';
import 'package:every_ai/features/artifacts/checks/web_scripts.dart';
import 'package:every_ai/features/artifacts/ui/renderers/web_view.dart';
import 'package:flutter_test/flutter_test.dart';

/// Draws "graph" diagrams, rejects anything else, counts calls.
class _FakeRenderer implements DiagramRenderer {
  int calls = 0;
  bool available = true;

  @override
  Future<DiagramRender> render(String source) async {
    calls++;
    if (!available) throw const DiagramUnavailable('no webview');
    if (source.startsWith('graph')) {
      return DiagramDrawn(svg: '<svg/>', width: 960, height: 200, png: Uint8List.fromList([1, 2, 3]));
    }
    return const DiagramFailed('Parse error on line 1: expecting graph');
  }
}

void main() {
  group('diagram renders', () {
    test('renders run one at a time, are cached, and failures to draw are not', () async {
      var running = 0;
      var maxRunning = 0;
      var calls = 0;
      var fail = true;
      final renderer = CachingDiagramRenderer((source) async {
        calls++;
        running++;
        maxRunning = running > maxRunning ? running : maxRunning;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        running--;
        if (source == 'flaky' && fail) throw const DiagramUnavailable('down');
        return DiagramFailed(source);
      }, capacity: 2);
      await Future.wait([renderer.render('a'), renderer.render('b'), renderer.render('a ')]);
      expect(calls, 2);
      expect(maxRunning, 1);
      await expectLater(renderer.render('flaky'), throwsA(isA<DiagramUnavailable>()));
      fail = false;
      expect(await renderer.render('flaky'), isA<DiagramFailed>());
      // Capacity 2, least recently used out: 'a' (used again) stayed, 'b' went.
      await renderer.render('a');
      expect(calls, 4);
      await renderer.render('b');
      expect(calls, 5);
    });
  });

  group('tool checks', () {
    test('markdown artifacts: bad math and broken Mermaid blocks come back as edits to make', () async {
      final checker = AppToolChecker(diagrams: _FakeRenderer());
      const content =
          r'Energy $E=mc^2$ and $\frac{1}{$.'
          '\n\n```mermaid\ngraph TD; A-->B\n```\n\n```mermaid\nnope\n```\n';
      final result = await checker.check(
        'create_artifact',
        jsonEncode({'id': 'notes', 'title': 'Notes', 'kind': 'markdown', 'content': content}),
      );
      expect(result.isError, isTrue);
      expect(result.text, contains('Shown to the user: markdown artifact "Notes" (id "notes")'));
      expect(result.text, contains(r'- Math `\frac{1}{`'));
      expect(result.text, contains('- Mermaid block 2: Parse error'));
      expect(result.text, contains('edit_artifact (id "notes")'));
      final clean = await checker.check(
        'create_artifact',
        jsonEncode({'id': 'n', 'title': 'N', 'kind': 'markdown', 'content': r'$x$'}),
      );
      expect(clean.isError, isFalse);
    });
  });

  group('bundled Mermaid', () {
    test('pages ask for the bundled script, not a CDN', () {
      final page = mermaidPage('graph TD; A-->B', dark: false);
      expect(page, contains(mermaidScriptMarker));
      expect(page, isNot(contains('cdn.jsdelivr.net')));
      expect(page, contains('securityLevel:"strict"'));
    });
  });
}
