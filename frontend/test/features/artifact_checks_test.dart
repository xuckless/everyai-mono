import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:every_ai/features/artifacts/checks/diagram_render.dart';
import 'package:every_ai/features/artifacts/checks/math_check.dart';
import 'package:every_ai/features/artifacts/checks/math_raster.dart';
import 'package:every_ai/features/artifacts/checks/tool_checks.dart';
import 'package:every_ai/features/artifacts/checks/web_scripts.dart';
import 'package:every_ai/features/artifacts/export/doc_model.dart';
import 'package:every_ai/features/artifacts/export/docx_writer.dart';
import 'package:every_ai/features/artifacts/export/downloads.dart';
import 'package:every_ai/features/artifacts/export/svg_raster.dart';
import 'package:every_ai/features/artifacts/ui/renderers/web_view.dart';
import 'package:every_ai/features/chat/domain/message.dart';
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

final RasterFigure _figure = (png: Uint8List.fromList([137, 80, 78, 71]), width: 100.0, height: 40.0);

Message _assistant(List<ToolCallPart> parts) =>
    Message(id: 'm', conversationId: 'c', role: Role.assistant, parts: parts, createdAt: DateTime(2026));

void main() {
  group('math', () {
    test('finds every delimiter outside code, and math fences', () {
      const md = r'''Inline $a+b$ and \(c\), display $$x^2$$ and \[y\].
Costs $5 and $10 are not math. `$code$` is not math.

```python
cost = "$x$"
```

```math
\frac{1}{2}
```
''';
      expect(mathIn(md).map((m) => (m.tex, m.display)), [
        ('a+b', false),
        ('c', false),
        ('x^2', true),
        ('y', true),
        (r'\frac{1}{2}', true),
      ]);
    });

    test('reports TeX the renderer cannot parse', () {
      expect(texError(r'\frac{1}{2}'), isNull);
      expect(texError(r'\frac{1}{'), isNotNull);
      expect(texError(r'\notacommand x'), isNotNull);
      final problems = mathProblems(r'Fine $x$, broken $\frac{1}{$ here, and $$\sqrt{2}$$.');
      expect(problems, hasLength(1));
      expect(problems.single, startsWith(r'`\frac{1}{`: '));
    });
  });

  group('diagram renders', () {
    test('decode what the page returns', () {
      final drawn = diagramRenderFromJs({
        'ok': true,
        'svg': '<svg/>',
        'width': 300,
        'height': 100.5,
        'png': base64Encode([1, 2]),
      });
      expect(drawn, isA<DiagramDrawn>());
      drawn as DiagramDrawn;
      expect((drawn.width, drawn.height), (300.0, 100.5));
      expect(drawn.png, [1, 2]);
      final failed = diagramRenderFromJs(jsonEncode({'ok': false, 'error': 'Parse error'}));
      expect((failed as DiagramFailed).message, 'Parse error');
      expect(() => diagramRenderFromJs(null), throwsA(isA<DiagramUnavailable>()));
      expect(() => diagramRenderFromJs({'ok': true}), throwsA(isA<DiagramUnavailable>()));
    });

    test('a figure fits the page width; without a PNG the SVG is drawn instead', () async {
      final wide = DiagramDrawn(svg: '<svg/>', width: 960, height: 200, png: Uint8List(3));
      final f = await wide.figure(maxWidth: 480);
      expect((f!.width, f.height), (480.0, 100.0));
      const noPng = DiagramDrawn(svg: '<svg/>', width: 10, height: 10);
      expect(await noPng.figure(fallback: (_) async => _figure), same(_figure));
    });

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
    test('declares render_diagram only with a renderer', () {
      expect(const AppToolChecker().tools, {'create_artifact', 'update_artifact'});
      expect(AppToolChecker(diagrams: _FakeRenderer()).tools, contains('render_diagram'));
    });

    test('render_diagram: clean, broken, and unchecked', () async {
      final fake = _FakeRenderer();
      final checker = AppToolChecker(diagrams: fake);
      final ok = await checker.check('render_diagram', jsonEncode({'title': 'Flow', 'mermaid': 'graph TD; A-->B'}));
      expect(ok, (text: 'Shown to the user: Mermaid diagram "Flow". It rendered cleanly.', isError: false));
      final bad = await checker.check('render_diagram', jsonEncode({'mermaid': 'flowchart oops'}));
      expect(bad.isError, isTrue);
      expect(bad.text, contains('Parse error on line 1'));
      expect(bad.text, contains('call render_diagram again'));
      fake.available = false;
      final unchecked = await checker.check('render_diagram', jsonEncode({'mermaid': 'x'}));
      expect(unchecked, (text: 'Shown to the user: Mermaid diagram.', isError: false));
    });

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

    test('updates take the kind of the artifact they revise', () async {
      final checker = AppToolChecker(diagrams: _FakeRenderer());
      final history = [
        _assistant([
          ToolCallPart(
            toolName: 'create_artifact',
            argumentsJson: jsonEncode({'id': 'sh', 'title': 'Script', 'kind': 'code', 'content': 'echo'}),
            callId: 't1',
          ),
        ]),
      ];
      // Shell code full of dollars isn't checked as math.
      final code = await checker.check(
        'update_artifact',
        jsonEncode({'id': 'sh', 'content': r'echo $\frac{$ $HOME'}),
        history: history,
      );
      expect(code, (text: 'Shown to the user: a new version of artifact "sh" in the side panel.', isError: false));
      final unknown = await checker.check('update_artifact', jsonEncode({'id': 'new', 'content': r'$\frac{$'}));
      expect(unknown.isError, isTrue);
    });

    test('mermaid artifacts are drawn as a whole', () async {
      final checker = AppToolChecker(diagrams: _FakeRenderer());
      final bad = await checker.check(
        'create_artifact',
        jsonEncode({'id': 'd', 'title': 'D', 'kind': 'mermaid', 'content': 'nope'}),
      );
      expect(bad.isError, isTrue);
      expect(bad.text, contains('- Parse error'));
    });
  });

  group('exports', () {
    const doc = '# Doc\n\n```mermaid\ngraph TD; A-->B\n```\n\n\$\$E = mc^2\$\$\n\n```mermaid\nbroken\n```\n';

    test('word embeds diagram and equation images, and keeps the source of the rest', () async {
      final bytes = buildDocx(
        title: 'Doc',
        blocks: parseDoc(doc),
        diagrams: {'graph TD; A-->B': _figure},
        equations: {'E = mc^2': _figure},
      );
      final zip = ZipDecoder().decodeBytes(bytes);
      expect(zip.files.where((f) => f.name.startsWith('word/media/')), hasLength(2));
      final xml = utf8.decode(zip.findFile('word/document.xml')!.content);
      expect(xml, contains('broken'));
      expect(xml, isNot(contains('A--&gt;B')));
    });

    test('pdf and word downloads ask for every diagram and equation', () async {
      final asked = <String>[];
      Future<RasterFigure?> draw(String s) async {
        asked.add(s);
        return s.startsWith('graph') || s.startsWith('E') ? _figure : null;
      }

      final pdf = await pdfOf('Doc', doc, drawDiagram: draw, drawMath: draw);
      expect(String.fromCharCodes(pdf.take(5)), '%PDF-');
      expect(asked, ['graph TD; A-->B', 'broken', 'E = mc^2']);
      final docx = await docxOf('Doc', doc, drawDiagram: draw, drawMath: draw);
      expect(ZipDecoder().decodeBytes(docx).files.where((f) => f.name.startsWith('word/media/')), hasLength(2));
    });

    testWidgets('display math rasterizes with flutter_math', (tester) async {
      final figure = await tester.runAsync(() => rasterizeTex(r'\frac{a}{b} + \sqrt{2}'));
      expect(figure, isNotNull);
      expect(figure!.width, greaterThan(0));
      expect(figure.height, greaterThan(0));
      expect(figure.png.take(4), [137, 80, 78, 71]);
      expect(await tester.runAsync(() => rasterizeTex(r'\frac{')), isNull);
    });
  });

  group('bundled Mermaid', () {
    test('pages ask for the bundled script, not a CDN', () {
      final page = mermaidPage('graph TD; A-->B', dark: false);
      expect(page, contains(mermaidScriptMarker));
      expect(page, isNot(contains('cdn.jsdelivr.net')));
      expect(page, contains('securityLevel:"strict"'));
    });

    test('inlining escapes a closing script tag', () {
      expect(inlineScript('<p>M</p>', 'M', 'a("</script>")'), r'<p><script>a("<\/script>")</script></p>');
    });

    test('the bundled assets load and inline', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final html = await withBundledScripts('<body>$mermaidScriptMarker</body>');
      expect(html, isNot(contains(mermaidScriptMarker)));
      expect(html.length, greaterThan(1000000));
      expect(await bundledScript(mermaidExportAsset), contains('everyaiRenderMermaid'));
    });
  });
}
