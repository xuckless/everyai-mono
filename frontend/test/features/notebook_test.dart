import 'dart:convert';

import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/domain/notebook.dart';
import 'package:every_ai/features/code/ui/console/notebook_view.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

// A one-pixel PNG.
const _png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

String notebook() =>
    '${const JsonEncoder.withIndent(' ').convert({
      'nbformat': 4,
      'nbformat_minor': 5,
      'metadata': {
        'kernelspec': {'name': 'python3', 'language': 'python'},
        'language_info': {'name': 'python'},
        'custom': {'kept': true},
      },
      'cells': [
        {
          'cell_type': 'markdown',
          'id': 'intro',
          'metadata': <String, Object?>{},
          'source': ['# Sales\n', 'By month.'],
        },
        {
          'cell_type': 'code',
          'id': 'load',
          'metadata': <String, Object?>{},
          'execution_count': 3,
          'source': ['import pandas as pd\n', 'df = pd.read_csv("s.csv")'],
          'outputs': [
            {
              'output_type': 'stream',
              'name': 'stdout',
              'text': ['loaded 12 rows\n'],
            },
            {
              'output_type': 'display_data',
              'data': {
                'image/png': '$_png\n',
                'text/plain': ['<Figure>'],
              },
              'metadata': <String, Object?>{},
            },
            {
              'output_type': 'error',
              'ename': 'KeyError',
              'evalue': "'x'",
              'traceback': ['\u001b[31mKeyError\u001b[0m: \'x\''],
            },
          ],
        },
      ],
    })}\n';

void main() {
  test('cells with ids, sources and outputs; the model sees them as tagged cells', () {
    final nb = parseNotebook(notebook())!;
    expect(nb.language, 'python');
    expect([for (final c in nb.cells) (c.id, c.type)], [('intro', 'markdown'), ('load', 'code')]);
    expect(nb.cells[1].source, 'import pandas as pd\ndf = pd.read_csv("s.csv")');
    expect(nb.cells[1].outputs.map((o) => o.error), [false, false, true]);
    expect(nb.cells[1].outputs[1].image, _png);
    expect(nb.cells[1].outputs[2].text, "KeyError: 'x'", reason: 'colour codes out');
    final shown = notebookForModel(notebook());
    expect(shown, startsWith('Notebook (python), 2 cells. Edit it with notebook_edit by cell id.'));
    expect(shown, contains('<cell id="load" type="code" run="3">\nimport pandas as pd'));
    expect(shown, contains('[a picture, image/png] <Figure>'));
    expect(shown, contains('<output error="true">'));
    expect(parseNotebook('{"not": "a notebook"}'), isNull);
  });

  test('replace, insert and delete keep the file a valid notebook, and only the cell changes', () {
    final replaced = editNotebook(notebook(), mode: 'replace', cellId: 'load', source: 'df = load()\nprint(df)');
    expect(replaced.error, isNull);
    final j = jsonDecode(replaced.text!) as Map;
    final load = (j['cells'] as List)[1] as Map;
    expect(load['source'], ['df = load()\n', 'print(df)']);
    expect(load['outputs'], isEmpty, reason: "old outputs don't match the new code");
    expect(load['execution_count'], isNull);
    expect((j['metadata'] as Map)['custom'], {'kept': true});
    expect(replaced.text, endsWith('}\n'));

    final inserted = editNotebook(notebook(), mode: 'insert', cellId: 'intro', cellType: 'markdown', source: 'Note');
    final cells = (jsonDecode(inserted.text!) as Map)['cells'] as List;
    expect(cells, hasLength(3));
    expect((cells[1] as Map)['id'], inserted.cellId);
    expect((cells[1] as Map).containsKey('outputs'), isFalse);
    expect(editNotebook(notebook(), mode: 'insert', source: 'x = 1').text, contains('"x = 1"'));

    final deleted = editNotebook(notebook(), mode: 'delete', cellId: 'intro');
    expect(((jsonDecode(deleted.text!) as Map)['cells'] as List).single, containsPair('id', 'load'));

    // A markdown cell turned into code drops its attachments (code cells may not have them).
    final withAttachment = notebook().replaceFirst('"id": "intro",', '"id": "intro", "attachments": {"a.png": {}},');
    final asCode = editNotebook(withAttachment, mode: 'replace', cellId: 'intro', cellType: 'code', source: 'x');
    expect(((jsonDecode(asCode.text!) as Map)['cells'] as List).first, isNot(contains('attachments')));
    expect(notebookIdsArePositions(notebook()), isFalse);
    expect(notebookIdsArePositions('{"cells": [{"cell_type": "code", "source": ""}]}'), isTrue);

    expect(editNotebook(notebook(), mode: 'replace', cellId: 'nope', source: '').error, contains('no cell has id'));
    expect(editNotebook('not json', mode: 'delete', cellId: 'a').error, contains('not valid JSON'));
    expect(editNotebook(notebook(), mode: 'move', cellId: 'load').error, contains('edit_mode'));
  });

  testWidgets('the Files tab shows the cells, their outputs and pictures', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: m.MaterialApp(
          builder: (context, child) =>
              EveryThemeScope(theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light), child: child!),
          home: m.Material(child: NotebookView(text: notebook())),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('import pandas as pd'), findsOneWidget);
    expect(find.text('[3]'), findsOneWidget);
    expect(find.textContaining('loaded 12 rows'), findsOneWidget);
    expect(find.textContaining('KeyError'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
  });
}
