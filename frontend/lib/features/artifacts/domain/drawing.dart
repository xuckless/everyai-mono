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

/// Element fields the editor regenerates or that only matter to it (render
/// seeds, versions, ordering keys, cached text metrics, back-references).
const _volatileFields = {
  'seed',
  'version',
  'versionNonce',
  'updated',
  'index',
  'boundElements',
  'isDeleted',
  'originalText',
  'lineHeight',
  'baseline',
  'autoResize',
  'pressures',
  'simulatePressure',
  'lastCommittedPoint',
  'status',
  'scale',
  'crop',
  'customData',
};

/// Element fields left out when they hold Excalidraw's default.
const _defaultFields = <String, Object?>{
  'angle': 0,
  'opacity': 100,
  'roughness': 1,
  'strokeWidth': 2,
  'strokeStyle': 'solid',
  'fillStyle': 'solid',
  'strokeColor': '#1e1e1e',
  'backgroundColor': 'transparent',
  'frameId': null,
  'link': null,
  'locked': false,
  'roundness': null,
  'containerId': null,
  'startBinding': null,
  'endBinding': null,
  'startArrowhead': null,
  'elbowed': false,
};

/// The drawing as the model reads it in later turns: the visible elements
/// without volatile or default-valued fields, and without the editor's app
/// state and pasted image files (base64). A hand-edited scene is stored
/// whole, but replaying it verbatim would cost thousands of tokens a turn.
/// Past [maxChars] the remaining elements are counted, not listed.
String drawingForPrompt(String content, {int maxChars = 40000}) {
  final elements = drawingElements(content);
  if (elements == null) return content;
  final kept = <Object?>[];
  var size = 0;
  var omitted = 0;
  for (final e in elements) {
    if (e is Map && e['isDeleted'] == true) continue;
    final slim = e is Map<String, Object?>
        ? {
            for (final MapEntry(:key, :value) in e.entries)
              if (!_volatileFields.contains(key) &&
                  !(_defaultFields.containsKey(key) && _defaultFields[key] == value) &&
                  !(value is List && value.isEmpty))
                key: value,
          }
        : e;
    final json = jsonEncode(slim);
    if (size + json.length > maxChars) {
      omitted++;
      continue;
    }
    size += json.length + 1;
    kept.add(slim);
  }
  return jsonEncode({'type': 'excalidraw', 'elements': kept, if (omitted > 0) 'omitted_elements': omitted});
}
