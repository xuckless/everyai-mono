import 'dart:io';

import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/ui/list_editor.dart';
import 'package:every_ai/features/code/drivers/event_journal.dart';
import 'package:every_ai/features/code/ui/research_sites_editor.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../layout/layout_host.dart';

// The Login Items-style list: + types a row in place, Return keeps it, − or Delete removes the selected row.

void main() {
  Future<List<List<String>>> pump(WidgetTester tester, List<String> items, {String? Function(String)? validate}) async {
    final changes = <List<String>>[];
    var current = items;
    await tester.pumpWidget(
      LayoutHost(
        language: DesignLanguage.material,
        child: StatefulBuilder(
          builder: (context, setState) => Padding(
            padding: const EdgeInsets.all(20),
            child: KitListEditor(
              items: current,
              kindLabel: 'Kind',
              kindOf: (s) => s.startsWith('*.') ? 'Subdomains' : 'Site',
              validate: validate,
              onChanged: (next) => setState(() {
                changes.add(next);
                current = next;
              }),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return changes;
  }

  testWidgets('adds a typed row, refuses duplicates and bad input', (tester) async {
    final changes = await pump(tester, ['a.com'], validate: researchSiteProblem);
    expect(find.text('Site'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('list-editor.add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('list-editor.input')), 'a.com');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Already in the list'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('list-editor.input')), 'not a site');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('A domain, like docs.python.org'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('list-editor.input')), '*.b.org');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(changes.last, ['a.com', '*.b.org']);
    expect(find.text('Subdomains'), findsOneWidget);
  });

  testWidgets('− removes the selected row; nothing selected, nothing removed', (tester) async {
    final changes = await pump(tester, ['a.com', 'b.com']);
    await tester.tap(find.byKey(const ValueKey('list-editor.remove')));
    await tester.pumpAndSettle();
    expect(changes, isEmpty);
    await tester.tap(find.text('b.com'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('list-editor.remove')));
    await tester.pumpAndSettle();
    expect(changes.single, ['a.com']);
    // The next row is selected now; Delete removes it too.
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();
    expect(changes.last, isEmpty);
  });

  test('a pasted URL becomes its host', () {
    expect(siteOf('https://Docs.Python.org/3/library'), 'docs.python.org');
    expect(researchSiteProblem('https://docs.python.org/3'), isNull);
  });

  test('the event tail skips a cut first line and keeps the latest events', () async {
    final dir = await Directory.systemTemp.createTemp('tail');
    addTearDown(() => dir.delete(recursive: true));
    final lines = [
      for (var i = 0; i < 50; i++)
        '{"kind":"MessageEvent","id":"m$i","source":"agent","llm_message":{"role":"assistant","content":[{"type":"text","text":"step $i"}]}}',
    ];
    final path = '${dir.path}/events.jsonl';
    await File(path).writeAsString('${lines.join('\n')}\n');
    final all = await readEventTail(path);
    expect(all, hasLength(50));
    final tail = await readEventTail(path, maxBytes: 600);
    expect(tail.length, lessThan(50));
    expect(tail.last.id, 'm49');
    expect(await readEventTail('${dir.path}/missing.jsonl'), isEmpty);
  });
}
