import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/domain/message.dart';
import '../domain/artifact.dart';
import '../domain/drawing.dart';
import '../export/doc_model.dart';
import 'diagram_render.dart';
import 'math_check.dart';
import 'webview_diagram_renderer.dart';

/// The app's answer to a checked tool call: the text the model reads, and
/// whether it reports a problem to fix.
typedef ToolCheck = ({String text, bool isError});

/// The most Mermaid blocks of one artifact that get drawn for a check.
const _maxDiagramsPerArtifact = 6;

/// Checks UI tool calls before the model hears back, so it fixes what the
/// app can't draw: Mermaid (in a hidden webview, where there is one) and the
/// TeX in Markdown artifacts (with flutter_math, everywhere). The chat sends
/// [tools] as `client_tools` and answers each call with [check].
class AppToolChecker {
  const AppToolChecker({this.diagrams});

  /// Draws Mermaid; null where the platform has no webview.
  final DiagramRenderer? diagrams;

  Set<String> get tools => {'create_artifact', 'update_artifact', if (diagrams != null) 'render_diagram'};

  bool handles(String name) => tools.contains(name);

  /// Checks one call ([argumentsJson] as the model sent it); [history] gives
  /// the kind of an artifact an update revises. Never throws: a check that
  /// can't run lets the turn go on.
  Future<ToolCheck> check(String name, String argumentsJson, {Iterable<Message> history = const []}) async {
    final Map<String, Object?> args;
    try {
      args = switch (jsonDecode(argumentsJson)) {
        final Map<String, Object?> m => m,
        _ => const {},
      };
    } on FormatException {
      return (text: 'Error: the arguments were not valid JSON.', isError: true);
    }
    final title = switch (args['title']) {
      final String t when t.trim().isNotEmpty => ' "${t.trim()}"',
      _ => '',
    };
    switch (name) {
      case 'render_diagram':
        final drawn = await _drawDiagram(args['mermaid'] as String? ?? '');
        if (drawn.error case final error?) {
          return (
            text:
                'Error: Mermaid could not draw this diagram, so the user sees an error instead of it.\n$error\n'
                'Fix the source and call render_diagram again.',
            isError: true,
          );
        }
        return (
          text: 'Shown to the user: Mermaid diagram$title.${drawn.checked ? ' It rendered cleanly.' : ''}',
          isError: false,
        );
      case 'create_artifact' || 'update_artifact':
        final id = args['id'] as String? ?? '';
        final content = args['content'] as String? ?? '';
        final kind = switch (args['kind']) {
          'mermaid' => VisualKind.diagram,
          'code' => VisualKind.code,
          'html' => VisualKind.html,
          'svg' => VisualKind.svg,
          'drawing' => VisualKind.drawing,
          final String _ => VisualKind.document,
          _ => artifactsIn(history).where((a) => a.id == id).lastOrNull?.latest.kind ?? VisualKind.document,
        };
        final shown = name == 'create_artifact'
            ? 'Shown to the user: ${args['kind'] ?? 'markdown'} artifact$title (id "$id") in the side panel.'
            : 'Shown to the user: a new version of artifact "$id" in the side panel.';
        final problems = switch (kind) {
          VisualKind.diagram => [?(await _drawDiagram(content)).error],
          VisualKind.document => await _documentProblems(content),
          VisualKind.drawing => drawingProblems(content),
          _ => const <String>[],
        };
        if (problems.isEmpty) return (text: shown, isError: false);
        return (
          text:
              'Error: $shown, but parts of it can\'t be drawn:\n${problems.map((p) => '- $p').join('\n')}\n'
              'Fix them with edit_artifact (id "$id"); do not create the artifact again.',
          isError: true,
        );
      default:
        return (text: 'Shown to the user.', isError: false);
    }
  }

  Future<List<String>> _documentProblems(String markdown) async {
    final out = [for (final p in mathProblems(markdown)) 'Math $p'];
    if (diagrams == null) return out;
    for (final (i, source) in diagramSourcesIn(markdown).take(_maxDiagramsPerArtifact).indexed) {
      if ((await _drawDiagram(source)).error case final error?) out.add('Mermaid block ${i + 1}: $error');
    }
    return out;
  }

  /// Mermaid's error for [source], if any; [checked] is false when nothing
  /// could draw it (no webview, or it failed to start).
  Future<({String? error, bool checked})> _drawDiagram(String source) async {
    final renderer = diagrams;
    if (renderer == null) return (error: null, checked: false);
    if (source.trim().isEmpty) return (error: 'the Mermaid source is empty.', checked: true);
    try {
      return switch (await renderer.render(source)) {
        DiagramDrawn() => (error: null, checked: true),
        DiagramFailed(:final message) => (error: message, checked: true),
      };
    } on DiagramUnavailable {
      return (error: null, checked: false);
    }
  }
}

/// The checker the chat uses: Mermaid where a hidden webview can draw it.
final appToolCheckerProvider = Provider<AppToolChecker>((ref) => AppToolChecker(diagrams: appDiagramRenderer));
