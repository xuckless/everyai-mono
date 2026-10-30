import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../chat/domain/message.dart';

/// What a UI tool call shows. Each kind has one renderer, used both inline in
/// the chat and full-size in the side panel.
enum VisualKind {
  document('Document'),
  code('Code'),
  html('Web page'),
  svg('Illustration'),
  diagram('Diagram'),
  chart('Chart'),
  quiz('Quiz'),
  flashcards('Flashcards'),
  slides('Slides');

  const VisualKind(this.label);
  final String label;

  /// Kinds that live in the side panel; the rest render inline in the chat.
  bool get opensInPanel => switch (this) {
    document || code || html || slides => true,
    _ => false,
  };
}

/// One UI tool call, decoded: what to render and with which arguments.
@immutable
final class Visual {
  const Visual({required this.callId, required this.kind, required this.title, required this.args});

  /// Decodes a tool call; null for tools that aren't visuals (or bad JSON).
  static Visual? fromPart(ToolCallPart part) {
    final Map<String, Object?> args;
    try {
      args = switch (jsonDecode(part.argumentsJson)) {
        final Map<String, Object?> m => m,
        _ => const {},
      };
    } on FormatException {
      return null;
    }
    final kind = switch (part.toolName) {
      'create_artifact' || 'update_artifact' => switch (args['kind']) {
        'code' => VisualKind.code,
        'html' => VisualKind.html,
        'svg' => VisualKind.svg,
        'mermaid' => VisualKind.diagram,
        _ => VisualKind.document,
      },
      'render_svg' => VisualKind.svg,
      'render_diagram' => VisualKind.diagram,
      'render_chart' => VisualKind.chart,
      'make_quiz' => VisualKind.quiz,
      'make_flashcards' => VisualKind.flashcards,
      'make_slides' => VisualKind.slides,
      _ => null,
    };
    if (kind == null) return null;
    return Visual(
      callId: part.callId ?? '${part.toolName}:${part.argumentsJson.hashCode}',
      kind: kind,
      title: args['title'] as String? ?? args['id'] as String? ?? kind.label,
      args: args,
    );
  }

  final String callId;
  final VisualKind kind;
  final String title;
  final Map<String, Object?> args;

  String str(String key) => args[key] as String? ?? '';
}

/// A document the model created and may revise (`create_artifact`, then
/// `update_artifact` with the same id). Versions are oldest first.
@immutable
final class Artifact {
  const Artifact({required this.id, required this.versions});

  final String id;
  final List<Visual> versions;

  Visual get latest => versions.last;
  String get title => versions.lastWhere((v) => v.str('title').isNotEmpty, orElse: () => latest).title;
}

/// The artifacts in a conversation, in creation order. An update without a
/// matching create starts its own artifact; an update without `kind` keeps the
/// previous version's kind and language.
List<Artifact> artifactsIn(Iterable<Message> messages) {
  final byId = <String, List<Visual>>{};
  for (final m in messages) {
    for (final part in m.parts.whereType<ToolCallPart>()) {
      if (part.toolName != 'create_artifact' && part.toolName != 'update_artifact') continue;
      var visual = Visual.fromPart(part);
      if (visual == null) continue;
      final id = visual.str('id').isEmpty ? visual.callId : visual.str('id');
      final previous = byId[id]?.last;
      if (previous != null && visual.args['kind'] == null) {
        visual = Visual(
          callId: visual.callId,
          kind: previous.kind,
          title: visual.str('title').isEmpty ? previous.title : visual.title,
          args: {...previous.args, ...visual.args},
        );
      }
      (byId[id] ??= []).add(visual);
    }
  }
  return [for (final e in byId.entries) Artifact(id: e.key, versions: List.unmodifiable(e.value))];
}
