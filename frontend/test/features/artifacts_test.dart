import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/artifacts/domain/artifact.dart';
import 'package:every_ai/features/artifacts/ui/artifact_panel.dart';
import 'package:every_ai/features/artifacts/ui/renderers/quiz_view.dart';
import 'package:every_ai/features/artifacts/ui/renderers/svg_view.dart';
import 'package:every_ai/features/chat/domain/message.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

Message _assistant(String id, List<ToolCallPart> calls) =>
    Message(id: id, conversationId: 'c', role: Role.assistant, parts: calls, createdAt: DateTime(2026));

ToolCallPart _call(String tool, Map<String, Object?> args, String id) =>
    ToolCallPart(toolName: tool, argumentsJson: jsonEncode(args), callId: id);

void main() {
  test('artifacts collect their versions across messages; updates keep kind and language', () {
    final artifacts = artifactsIn([
      _assistant('m1', [
        _call('create_artifact', {
          'id': 'app',
          'title': 'App',
          'kind': 'code',
          'language': 'dart',
          'content': 'v1',
        }, 't1'),
        _call('make_quiz', {'title': 'Q', 'questions': []}, 't2'),
      ]),
      _assistant('m2', [
        _call('update_artifact', {'id': 'app', 'content': 'v2'}, 't3'),
        _call('create_artifact', {'id': 'notes', 'title': 'Notes', 'kind': 'markdown', 'content': '# Hi'}, 't4'),
      ]),
    ]);
    expect(artifacts.map((a) => a.id), ['app', 'notes']);
    final app = artifacts.first;
    expect(app.versions.map((v) => v.str('content')), ['v1', 'v2']);
    expect(app.latest.kind, VisualKind.code);
    expect(app.latest.str('language'), 'dart');
    expect(app.title, 'App');
    expect(artifacts.last.latest.kind, VisualKind.document);
  });

  test('visual kinds, and which open in the panel', () {
    Visual v(String tool, [Map<String, Object?> args = const {}]) => Visual.fromPart(_call(tool, args, 'x'))!;
    expect(v('render_chart').kind, VisualKind.chart);
    expect(v('make_slides').kind.opensInPanel, isTrue);
    expect(v('make_quiz').kind.opensInPanel, isFalse);
    expect(v('create_artifact', {'kind': 'mermaid'}).kind, VisualKind.diagram);
    expect(Visual.fromPart(_call('web_fetch', {}, 'x')), isNull);
    expect(Visual.fromPart(const ToolCallPart(toolName: 'make_quiz', argumentsJson: '{bad')), isNull);
  });

  test('exports: code by language, slides as markdown outline', () {
    final code = Visual.fromPart(
      _call('create_artifact', {'title': 'Fib Sequence!', 'kind': 'code', 'language': 'python', 'content': 'x'}, 'a'),
    )!;
    expect(exportOf(code), (text: 'x', name: 'fib-sequence', extension: 'py'));
    final deck = Visual.fromPart(
      _call('make_slides', {
        'title': 'Deck',
        'slides': [
          {
            'title': 'One',
            'bullets': ['a', 'b'],
          },
        ],
      }, 'b'),
    )!;
    expect(exportOf(deck).text, '# Deck\n\n---\n\n# One\n- a\n- b');
  });

  test('PowerPoint export is a zip with one part per slide (PPTX_OUT writes it for inspection)', () {
    final deck = Visual.fromPart(
      _call('make_slides', {
        'title': 'Riverpod & <you>',
        'subtitle': 'State, simply',
        'theme': 'navy',
        'slides': [
          {
            'title': 'Why',
            'bullets': ['Testable', 'Compile-safe "providers"'],
            'notes': 'Say hi',
          },
          {'title': 'Body', 'body': '**Bold** line\nSecond line'},
        ],
      }, 'deck'),
    )!;
    final bytes = pptxOf(deck);
    final zip = ZipDecoder().decodeBytes(bytes);
    final names = zip.files.map((f) => f.name).toSet();
    expect(names, containsAll(['ppt/presentation.xml', 'ppt/slides/slide3.xml', 'ppt/theme/theme1.xml']));
    expect(names.contains('ppt/slides/slide4.xml'), isFalse);
    final title = utf8.decode(zip.findFile('ppt/slides/slide1.xml')!.content as List<int>);
    expect(title, contains('Riverpod &amp; &lt;you&gt;'));
    final out = Platform.environment['PPTX_OUT'];
    if (out != null) File(out).writeAsBytesSync(bytes);
  });

  test('sanitizeSvg strips scripts, handlers and outside references', () {
    final clean = sanitizeSvg(
      '<svg viewBox="0 0 10 10" onload="x()"><script>alert(1)</script>'
      '<image href="https://evil.example/a.png"/><rect onclick=\'y()\' width="5" height="5"/></svg>',
    );
    expect(clean, isNot(contains('script')));
    expect(clean, isNot(contains('onload')));
    expect(clean, isNot(contains('onclick')));
    expect(clean, isNot(contains('evil.example')));
    expect(clean, contains('<rect'));
  });

  group('QuizView', () {
    Widget host(Visual visual) => ProviderScope(
      child: m.MaterialApp(
        home: m.Material(
          child: EveryThemeScope(
            theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
            child: SingleChildScrollView(
              child: QuizView(visual: visual, conversationId: 'c'),
            ),
          ),
        ),
      ),
    );

    final visual = Visual.fromPart(
      _call('make_quiz', {
        'title': 'Zig',
        'questions': [
          {
            'question': 'Which is a Zig keyword?',
            'options': ['comptime', 'goroutine'],
            'answer_index': 0,
            'explanation': 'comptime runs code at compile time.',
          },
          {
            'question': 'Which are allocators?',
            'options': ['ArenaAllocator', 'Writer', 'DebugAllocator'],
            'answer_indices': [0, 2],
            'explanation': 'Both implement std.mem.Allocator.',
          },
        ],
      }, 'quiz-1'),
    )!;

    testWidgets('single answer reveals the explanation; multi-answer needs Check; then a score', (tester) async {
      await tester.pumpWidget(host(visual));
      expect(find.text('Select all that apply'), findsOneWidget);

      await tester.tap(find.text('comptime'));
      await tester.pumpAndSettle();
      expect(find.text('Correct'), findsOneWidget);

      await tester.tap(find.text('ArenaAllocator'));
      await tester.pump();
      expect(find.text('Score: 1 / 2'), findsNothing); // not submitted yet
      await tester.tap(find.text('DebugAllocator'));
      await tester.pump();
      await tester.tap(find.text('Check'));
      await tester.pumpAndSettle();

      expect(find.text('Correct'), findsNWidgets(2));
      expect(find.text('Score: 2 / 2'), findsOneWidget);
      expect(find.text('Explain my mistakes'), findsNothing);
    });

    testWidgets('a wrong pick offers "Explain my mistakes"', (tester) async {
      await tester.pumpWidget(host(visual));
      await tester.tap(find.text('goroutine'));
      await tester.pump();
      await tester.tap(find.text('Writer'));
      await tester.pump();
      await tester.tap(find.text('Check'));
      await tester.pumpAndSettle();
      expect(find.text('Not quite'), findsNWidgets(2));
      expect(find.text('Score: 0 / 2'), findsOneWidget);
      expect(find.text('Explain my mistakes'), findsOneWidget);
    });
  });
}
