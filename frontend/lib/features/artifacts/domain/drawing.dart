import 'dart:convert';

/// Drawing artifacts (`create_artifact` kind `drawing`): an Excalidraw scene
/// as JSON, edited in the side panel.
///
/// The model may write a full scene (`{"type":"excalidraw","elements":[…]}`)
/// or just the elements, and elements may be Excalidraw's short "skeleton"
/// form (`{type, x, y, width, height, label:{text}, start:{id}, end:{id}}`);
/// the page fills in the rest. What the user saves is always a full scene.

/// The element types a scene may hold.
const drawingElementTypes = {
  'rectangle',
  'ellipse',
  'diamond',
  'arrow',
  'line',
  'text',
  'freedraw',
  'image',
  'frame',
  'magicframe',
  'embeddable',
  'iframe',
  'selection',
};

/// The most elements a drawing may hold.
const maxDrawingElements = 5000;

/// The elements of a drawing's [content] (a scene or a bare element list);
/// null when it is not one.
List<Object?>? drawingElements(String content) {
  final Object? json;
  try {
    json = jsonDecode(content);
  } on FormatException {
    return null;
  }
  return switch (json) {
    final List<Object?> list => list,
    {'elements': final List<Object?> list} => list,
    _ => null,
  };
}

/// What is wrong with a drawing's [content], for the model to fix; empty
/// when the page can draw it.
List<String> drawingProblems(String content) {
  if (content.trim().isEmpty) return const ['The drawing is empty: content must be Excalidraw scene JSON.'];
  final elements = drawingElements(content);
  if (elements == null) {
    return const ['content is not Excalidraw scene JSON: write {"type":"excalidraw","elements":[…]}.'];
  }
  if (elements.isEmpty) return const ['The scene has no elements.'];
  if (elements.length > maxDrawingElements) return ['The scene has ${elements.length} elements; keep it under 5000.'];
  final out = <String>[];
  for (final (i, e) in elements.indexed) {
    if (out.length >= 5) break;
    if (e is! Map) {
      out.add('elements[$i] is not an object.');
    } else if (e['type'] is! String || !drawingElementTypes.contains(e['type'])) {
      out.add('elements[$i].type must be one of rectangle, ellipse, diamond, arrow, line, text, freedraw.');
    } else if (e['x'] != null && e['x'] is! num || e['y'] != null && e['y'] is! num) {
      out.add('elements[$i].x and .y must be numbers.');
    } else if (e['type'] == 'text' && (e['text'] is! String || (e['text'] as String).isEmpty)) {
      out.add('elements[$i] is a text element without text.');
    }
  }
  return out;
}

/// The number of elements a user would see (not deleted), for captions.
int drawingElementCount(String content) =>
    drawingElements(content)?.where((e) => e is! Map || e['isDeleted'] != true).length ?? 0;

/// The id of the drawing made from a Mermaid diagram ("Make editable").
String drawingIdForDiagram(String diagramKey) {
  final base = diagramKey.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-');
  return '${base.length > 40 ? base.substring(0, 40) : base}-drawing';
}
