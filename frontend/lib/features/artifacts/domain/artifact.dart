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
  slides('Slides'),

  /// A generated raster image (`generate_image`); vector ones are [svg].
  image('Image'),

  /// A small interactive HTML widget drawn inside the message (`render_widget`).
  widget('Widget'),

  /// An Excalidraw scene the user can edit in the panel (`drawing.dart`).
  drawing('Drawing');

  const VisualKind(this.label);
  final String label;

  /// Kinds that live in the side panel; the rest render inline in the chat.
  bool get opensInPanel => switch (this) {
    document || code || html || slides || drawing => true,
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
        'drawing' => VisualKind.drawing,
        _ => VisualKind.document,
      },
      // The real kind comes from the artifact it edits (see [artifactsIn]).
      'edit_artifact' => VisualKind.document,
      'render_svg' => VisualKind.svg,
      'render_diagram' => VisualKind.diagram,
      'render_chart' => VisualKind.chart,
      'make_quiz' => VisualKind.quiz,
      'make_flashcards' => VisualKind.flashcards,
      'make_slides' => VisualKind.slides,
      'render_widget' => VisualKind.widget,
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
/// `update_artifact` or `edit_artifact` with the same id). Versions are
/// oldest first.
@immutable
final class Artifact {
  const Artifact({required this.id, required this.versions});

  final String id;
  final List<Visual> versions;

  Visual get latest => versions.last;
  String get title => versions.lastWhere((v) => v.str('title').isNotEmpty, orElse: () => latest).title;
}

/// The tools that create or revise an artifact.
const artifactTools = {'create_artifact', 'update_artifact', 'edit_artifact'};

/// The artifacts in a conversation, in creation order. Generated images are
/// artifacts too, keyed by the first image's id: an image that revises another
/// (`ImagePart.revises`) is that artifact's next version. An update without a
/// matching create starts its own artifact; an update without `kind` keeps the
/// previous version's kind and language. An edit applies its find-and-replace
/// edits to the previous version (`edit_missed` lists the ones that did not
/// match); an edit of an unknown artifact is ignored.
List<Artifact> artifactsIn(Iterable<Message> messages) {
  final byId = <String, List<Visual>>{};
  final imageRoot = <String, String>{};
  for (final m in messages) {
    for (final part in m.parts) {
      if (part case ImagePart(:final imageId?)) {
        final root = imageRoot[imageId] = imageRoot[part.revises] ?? imageId;
        (byId[root] ??= []).add(imageVisual(part));
        continue;
      }
      if (part is! ToolCallPart) continue;
      if (!artifactTools.contains(part.toolName)) continue;
      var visual = Visual.fromPart(part);
      if (visual == null) continue;
      final id = visual.str('id').isEmpty ? visual.callId : visual.str('id');
      final previous = byId[id]?.last;
      if (part.toolName == 'edit_artifact') {
        if (previous == null) continue;
        final edited = applyArtifactEdits(previous.str('content'), visual.args['edits']);
        (byId[id] ??= []).add(
          Visual(
            callId: visual.callId,
            kind: previous.kind,
            title: previous.title,
            args: {...previous.args, 'content': edited.content, 'edit_missed': edited.missed, 'edits': null},
          ),
        );
        continue;
      }
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

/// A generated image as a visual: an SVG one renders (and downloads) like
/// `render_svg`; a raster one carries its bytes.
Visual imageVisual(ImagePart image) {
  final prompt = image.prompt ?? '';
  final title = prompt.isEmpty
      ? 'Image'
      : prompt.length > 60
      ? '${prompt.substring(0, 60).trimRight()}…'
      : prompt;
  final meta = {'image_id': image.imageId, 'prompt': prompt, 'mime': image.mimeType};
  final bytes = image.bytes;
  return Visual(
    callId: image.imageId ?? image.blobRef ?? 'image:${identityHashCode(image)}',
    kind: image.isSvg ? VisualKind.svg : VisualKind.image,
    title: title,
    args: image.isSvg
        ? {...meta, 'svg': bytes == null ? '' : utf8.decode(bytes, allowMalformed: true)}
        : {...meta, 'bytes': bytes},
  );
}

/// Applies `edit_artifact` edits (`[{old_text, new_text}]`) in order. An
/// old_text matches exactly, or else ignoring differences in trailing
/// whitespace and line endings; edits that match nowhere are returned in
/// [missed] (their old_text, shortened) and skipped.
({String content, List<String> missed}) applyArtifactEdits(String content, Object? edits) {
  var out = content;
  final missed = <String>[];
  for (final e in edits is List ? edits : const []) {
    if (e case {'old_text': final String old, 'new_text': final String replacement} when old.isNotEmpty) {
      var at = out.indexOf(old);
      var length = old.length;
      if (at < 0) {
        final loose = RegExp(
          old.replaceAll('\r\n', '\n').split('\n').map((line) => RegExp.escape(line.trimRight())).join(r'[ \t]*\r?\n'),
        );
        if (loose.firstMatch(out) case final m?) {
          at = m.start;
          length = m.end - m.start;
        }
      }
      if (at < 0) {
        missed.add(old.length > 60 ? '${old.substring(0, 60)}…' : old);
        continue;
      }
      out = out.replaceRange(at, at + length, replacement);
    }
  }
  return (content: out, missed: missed);
}
