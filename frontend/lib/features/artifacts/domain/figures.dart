import 'dart:convert';

import 'artifact.dart';

/// UI tools whose call becomes a figure when it carries an `id`: a versioned artifact (edit_artifact and a later
/// call with the same id revise it) that documents and slides can show by id (`figure:<id>`).
const figureTools = {'render_svg', 'render_chart', 'render_diagram'};

/// Tools whose call, with an `id`, is a versioned artifact: the figure tools and slide decks.
const versionedTools = {...figureTools, 'make_slides'};

/// A versioned call's arguments as an artifact version: `content` holds its source (SVG, chart JSON or Mermaid) and
/// `kind` says which, so edit_artifact can revise it like any artifact.
Map<String, Object?> figureArgs(String tool, Map<String, Object?> args) => switch (tool) {
  'render_svg' => {...args, 'kind': 'svg', 'content': args['svg'] as String? ?? ''},
  'render_diagram' => {...args, 'kind': 'mermaid', 'content': args['mermaid'] as String? ?? ''},
  'make_slides' => {...args, 'kind': 'slides', 'content': jsonEncode(_chartSpec(args))},
  _ => {...args, 'kind': 'chart', 'content': jsonEncode(_chartSpec(args))},
};

Map<String, Object?> _chartSpec(Map<String, Object?> args) => {
  for (final e in args.entries)
    if (e.key != 'id' && e.key != 'kind' && e.key != 'content' && e.key != 'edited_by' && e.key != 'edit_missed')
      e.key: e.value,
};

/// [previous] with its source replaced by [content] (an edit or a hand edit): the renderer's own key follows.
Map<String, Object?> withFigureContent(Map<String, Object?> previous, String content) => switch (previous['kind']) {
  'svg' when previous.containsKey('svg') => {...previous, 'content': content, 'svg': content},
  'mermaid' when previous.containsKey('mermaid') => {...previous, 'content': content, 'mermaid': content},
  'chart' || 'slides' => {...previous, ...?_decodeObject(content), 'content': content},
  _ => {...previous, 'content': content},
};

Map<String, Object?>? _decodeObject(String text) {
  try {
    return switch (jsonDecode(text)) {
      final Map<String, Object?> m => m,
      _ => null,
    };
  } on FormatException {
    return null;
  }
}

/// What a figure is drawn from.
enum FigureKind {
  svg('svg'),
  chart('chart'),
  diagram('mermaid');

  const FigureKind(this.fence);

  /// The Markdown fence language that draws it.
  final String fence;
}

/// A figure: the latest version of an SVG, chart or diagram the chat can refer to by id.
typedef Figure = ({String id, String title, FigureKind kind, String source});

/// The chat's figures by id: SVG, chart and Mermaid artifacts (figure calls with an id, and create_artifact of
/// kind svg or mermaid), at their latest version.
Map<String, Figure> figuresOf(Iterable<Artifact> artifacts) => {
  for (final a in artifacts)
    if (switch (a.latest.str('kind')) {
          'svg' => FigureKind.svg,
          'chart' => FigureKind.chart,
          'mermaid' => FigureKind.diagram,
          _ => null,
        }
        case final kind?)
      a.id: (id: a.id, title: a.title, kind: kind, source: a.latest.str('content')),
};

/// A figure reference on a line of its own: `![caption](figure:id)`.
final _figureRef = RegExp(r'^\s*!\[([^\]]*)\]\(figure:([A-Za-z0-9_.-]+)\)\s*$');

/// The ids [markdown] refers to with `figure:` (outside code fences), in order.
List<String> figureRefsIn(String markdown) {
  final ids = <String>[];
  var inFence = false;
  for (final line in markdown.split('\n')) {
    if (line.trimLeft().startsWith('```')) inFence = !inFence;
    if (inFence) continue;
    if (_figureRef.firstMatch(line) case final m?) ids.add(m.group(2)!);
  }
  return ids;
}

/// [markdown] with each `![caption](figure:id)` line replaced by the figure's latest source as a fenced block (the
/// renderers and exporters already draw ```svg, ```chart and ```mermaid) and its caption in italics. A reference to
/// no figure becomes a visible note, so a missing figure is seen rather than silently dropped. Fenced code is left
/// alone.
String expandFigureRefs(String markdown, Map<String, Figure> figures) {
  if (!markdown.contains('figure:')) return markdown;
  final out = <String>[];
  var inFence = false;
  for (final line in markdown.split('\n')) {
    if (line.trimLeft().startsWith('```')) inFence = !inFence;
    final m = inFence ? null : _figureRef.firstMatch(line);
    if (m == null) {
      out.add(line);
      continue;
    }
    final caption = m.group(1)!.trim();
    final id = m.group(2)!;
    final figure = figures[id];
    if (figure == null) {
      out.add('*[Figure "$id" is not in this chat]*');
      continue;
    }
    out
      ..add('```${figure.kind.fence}')
      ..add(figure.source.trim())
      ..add('```');
    if (caption.isNotEmpty) out.add('*${caption.replaceAll('*', r'\*')}*');
  }
  return out.join('\n');
}
