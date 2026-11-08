import 'dart:convert';
import 'dart:math';

// Jupyter notebooks (.ipynb, nbformat 4): the cells as the agent's tools and the Files tab see them, and cell edits
// that keep the file valid. Pure, for the web build and tests.

bool isNotebookPath(String path) => path.toLowerCase().endsWith('.ipynb');

/// One output of a code cell: its text (streams, plain results, errors), or a picture (base64 PNG or JPEG).
typedef NotebookOutput = ({String text, String? image, String? mime, bool error});

/// A cell: its id (nbformat 4.5; `cell-N` by position in older files), kind, source and saved outputs.
typedef NotebookCell = ({String id, String type, String source, List<NotebookOutput> outputs, int? count});

/// A notebook's cells and its kernel's language, or null when [text] isn't a notebook.
({List<NotebookCell> cells, String language})? parseNotebook(String text) {
  final Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException {
    return null;
  }
  if (json is! Map || json['cells'] is! List) return null;
  final meta = json['metadata'] as Map? ?? const {};
  final language =
      '${(meta['language_info'] as Map?)?['name'] ?? (meta['kernelspec'] as Map?)?['language'] ?? 'python'}';
  final cells = <NotebookCell>[];
  for (final (i, c) in (json['cells'] as List).indexed) {
    if (c is! Map) continue;
    cells.add((
      id: c['id'] is String ? c['id']! as String : 'cell-$i',
      type: '${c['cell_type'] ?? 'code'}',
      source: _joined(c['source']),
      outputs: [for (final o in c['outputs'] as List? ?? const []) ?_output(o)],
      count: (c['execution_count'] as num?)?.toInt(),
    ));
  }
  return (cells: cells, language: language);
}

String _joined(Object? s) => s is List ? s.map((e) => '$e').join() : '${s ?? ''}';

NotebookOutput? _output(Object? o) {
  if (o is! Map) return null;
  switch (o['output_type']) {
    case 'stream':
      return (text: _joined(o['text']), image: null, mime: null, error: o['name'] == 'stderr');
    case 'error':
      final trace = [for (final l in o['traceback'] as List? ?? const []) _plain('$l')].join('\n');
      return (text: trace.isNotEmpty ? trace : '${o['ename']}: ${o['evalue']}', image: null, mime: null, error: true);
    case 'execute_result' || 'display_data':
      final data = o['data'] as Map? ?? const {};
      for (final mime in const ['image/png', 'image/jpeg']) {
        if (data[mime] != null) {
          return (
            text: _joined(data['text/plain']),
            image: _joined(data[mime]).replaceAll('\n', ''),
            mime: mime,
            error: false,
          );
        }
      }
      return (
        text: _joined(data['text/plain'] ?? data['text/markdown'] ?? data['text/html']),
        image: null,
        mime: null,
        error: false,
      );
  }
  return null;
}

/// Terminal colour codes out of a traceback line.
String _plain(String s) => s.replaceAll(RegExp(r'\x1b\[[0-9;]*m'), '');

/// [text] (a notebook) as `read` shows it to the model: each cell with its id and kind, its source, and its saved
/// outputs cut to [outputChars] each (pictures named, not shown).
String notebookForModel(String text, {int outputChars = 2000}) {
  final nb = parseNotebook(text);
  if (nb == null) return text;
  final b = StringBuffer(
    'Notebook (${nb.language}), ${nb.cells.length} cells. Edit it with notebook_edit by cell id.\n',
  );
  for (final c in nb.cells) {
    b.writeln('\n<cell id="${c.id}" type="${c.type}"${c.count == null ? '' : ' run="${c.count}"'}>');
    b.writeln(c.source.trimRight());
    for (final o in c.outputs) {
      final body = o.image != null ? '[a picture, ${o.mime}]${o.text.isEmpty ? '' : ' ${o.text}'}' : o.text.trimRight();
      final cut = body.length > outputChars ? '${body.substring(0, outputChars)}… (cut)' : body;
      b.writeln('<output${o.error ? ' error="true"' : ''}>\n$cut\n</output>');
    }
    b.writeln('</cell>');
  }
  return b.toString();
}

/// [text] (a notebook) with one cell edit: [mode] `replace` (the source of [cellId]; [cellType] may change its kind),
/// `insert` (a new cell of [cellType] after [cellId], or first when there is none) or `delete`. A code cell whose
/// source changes loses its saved outputs, which no longer match it. The rest of the file is kept as it was. Returns
/// the new text, or an error to show the model.
({String? text, String? error, String? cellId}) editNotebook(
  String text, {
  required String mode,
  String? cellId,
  String? cellType,
  String? source,
}) {
  final Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException catch (e) {
    return (text: null, error: 'the file is not valid JSON (${e.message}).', cellId: null);
  }
  if (json is! Map<String, Object?> || json['cells'] is! List) {
    return (text: null, error: 'the file is not a Jupyter notebook (no cells).', cellId: null);
  }
  final cells = (json['cells']! as List).cast<Object?>();
  int? indexOf(String id) {
    for (final (i, c) in cells.indexed) {
      if (c is Map && (c['id'] == id || (c['id'] == null && id == 'cell-$i'))) return i;
    }
    return null;
  }

  final at = cellId == null || cellId.isEmpty ? null : indexOf(cellId);
  if (cellId != null && cellId.isNotEmpty && at == null) {
    return (text: null, error: 'no cell has id "$cellId". read the notebook to see its cell ids.', cellId: null);
  }
  if (cellType != null && cellType != 'code' && cellType != 'markdown' && cellType != 'raw') {
    return (text: null, error: 'cell_type must be code, markdown or raw.', cellId: null);
  }
  final withIds = (json['nbformat_minor'] as num? ?? 0) >= 5 || cells.any((c) => c is Map && c['id'] != null);
  String? touched;
  switch (mode) {
    case 'replace':
      if (at == null) return (text: null, error: 'replace needs the cell_id of the cell to change.', cellId: null);
      if (source == null) return (text: null, error: 'replace needs new_source.', cellId: null);
      final cell = Map<String, Object?>.of(cells[at]! as Map<String, Object?>);
      final type = cellType ?? '${cell['cell_type'] ?? 'code'}';
      cell['cell_type'] = type;
      cell['source'] = _lines(source);
      if (type == 'code') {
        cell['outputs'] = <Object?>[];
        cell['execution_count'] = null;
      } else {
        cell
          ..remove('outputs')
          ..remove('execution_count');
      }
      cells[at] = cell;
      touched = cell['id'] as String? ?? 'cell-$at';
    case 'insert':
      if (source == null) return (text: null, error: 'insert needs new_source.', cellId: null);
      final type = cellType ?? 'code';
      final id = withIds ? _newId(cells) : null;
      final cell = <String, Object?>{
        'cell_type': type,
        'id': ?id,
        'metadata': <String, Object?>{},
        'source': _lines(source),
        if (type == 'code') ...{'execution_count': null, 'outputs': <Object?>[]},
      };
      final index = at == null ? 0 : at + 1;
      cells.insert(index, cell);
      touched = id ?? 'cell-$index';
    case 'delete':
      if (at == null) return (text: null, error: 'delete needs the cell_id of the cell to remove.', cellId: null);
      cells.removeAt(at);
    default:
      return (text: null, error: 'edit_mode must be replace, insert or delete.', cellId: null);
  }
  json['cells'] = cells;
  // Jupyter writes one space of indent and a final newline.
  return (text: '${const JsonEncoder.withIndent(' ').convert(json)}\n', error: null, cellId: touched);
}

/// [s] as nbformat stores sources: lines, each with its newline but the last.
List<String> _lines(String s) {
  if (s.isEmpty) return const [];
  final parts = s.split('\n');
  return [for (final (i, l) in parts.indexed) i < parts.length - 1 ? '$l\n' : l]..removeWhere((l) => l.isEmpty);
}

String _newId(List<Object?> cells) {
  final taken = {
    for (final c in cells)
      if (c is Map) c['id'],
  };
  final r = Random();
  while (true) {
    final id = List.generate(8, (_) => r.nextInt(16).toRadixString(16)).join();
    if (!taken.contains(id)) return id;
  }
}
