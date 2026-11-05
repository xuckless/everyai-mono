import 'dart:convert';

import 'package:every_ai/features/code/harness/everyai/screen_tools_io.dart';
import 'package:every_ai/features/code/harness/everyai/window_ax_io.dart';
import 'package:flutter_test/flutter_test.dart';

const _w = (id: 7, pid: 42, owner: 'Finder', title: 'Docs "a" `b` </script>', width: 800, height: 600);

AxRunner _fake(int code, String out, [String err = '']) =>
    (_) async => (exitCode: code, stdout: out, stderr: err);

void main() {
  group('formatAxTree', () {
    test('indents by depth, shows label and value, makes coordinates window-relative', () {
      final text = formatAxTree(
        [
          {'d': 0, 'role': 'AXToolbar', 'label': '', 'value': '', 'x': 110, 'y': 220, 'w': 100, 'h': 30},
          {'d': 1, 'role': 'AXButton', 'label': 'Save', 'value': '', 'x': 120, 'y': 225, 'w': 40, 'h': 20},
          {'d': 1, 'role': 'AXTextField', 'label': 'Name', 'value': 'abc', 'x': 160, 'y': 225, 'w': 40, 'h': 20},
        ],
        originX: 100,
        originY: 200,
      );
      expect(text.split('\n'), [
        'Toolbar [10,20 100x30]',
        '  Button "Save" [20,25 40x20]',
        '  TextField "Name" value="abc" [60,25 40x20]',
      ]);
    });

    test('drops empty noise roles but keeps their children', () {
      final text = formatAxTree([
        {'d': 0, 'role': 'AXGroup', 'label': '', 'value': '', 'x': 0, 'y': 0, 'w': 1, 'h': 1},
        {'d': 1, 'role': 'AXButton', 'label': 'Go', 'value': '', 'x': 0, 'y': 0, 'w': 1, 'h': 1},
        {'d': 0, 'role': 'AXGroup', 'label': 'Sidebar', 'value': '', 'x': 0, 'y': 0, 'w': 1, 'h': 1},
      ]);
      expect(text, isNot(contains('Group [')));
      expect(text, contains('  Button "Go"'));
      expect(text, contains('Group "Sidebar"'));
    });

    test('never prints a secure field value', () {
      final text = formatAxTree([
        {'d': 0, 'role': 'AXSecureTextField', 'label': 'Password', 'value': 'hunter2', 'x': 0, 'y': 0, 'w': 1, 'h': 1},
      ]);
      expect(text, contains('SecureTextField "Password"'));
      expect(text, isNot(contains('hunter2')));
    });

    test('cuts at the character cap with a marker', () {
      final nodes = [
        for (var i = 0; i < 1000; i++)
          {'d': 0, 'role': 'AXButton', 'label': 'Button number $i', 'value': '', 'x': 0, 'y': 0, 'w': 1, 'h': 1},
      ];
      final text = formatAxTree(nodes);
      expect(text.length, lessThanOrEqualTo(axMaxChars + 40));
      expect(text, endsWith('(cut: more elements not shown)'));
    });
  });

  group('windowAxTree', () {
    test('valid JSON becomes text', () async {
      final out = jsonEncode({
        'x': 10,
        'y': 10,
        'nodes': [
          {'d': 0, 'role': 'AXButton', 'label': 'OK', 'value': '', 'x': 15, 'y': 20, 'w': 5, 'h': 5},
        ],
      });
      expect(await windowAxTree(_w, run: _fake(0, out)), 'Button "OK" [5,10 5x5]');
    });

    test('a denied permission gives the one-line note', () async {
      final text = await windowAxTree(_w, run: _fake(1, '', 'execution error: not allowed assistive access (-25211)'));
      expect(text, startsWith('Accessibility data off:'));
      expect(text, isNot(contains('\n')));
    });

    test('failure or bad JSON is "not available"', () async {
      expect(await windowAxTree(_w, run: _fake(1, '', 'boom')), 'Accessibility data not available.');
      expect(await windowAxTree(_w, run: _fake(0, 'not json')), 'Accessibility data not available.');
      expect(await windowAxTree(_w, run: _fake(0, '{"nodes":[]}')), 'Accessibility data not available.');
    });

    test('the window title only ever sits inside a JSON string in the script', () async {
      String? seen;
      await windowAxTree(
        _w,
        run: (s) async {
          seen = s;
          return (exitCode: 1, stdout: '', stderr: '');
        },
      );
      final line = seen!.split('\n').firstWhere((l) => l.startsWith('var q = JSON.parse('));
      final inner = jsonDecode(line.substring('var q = JSON.parse('.length, line.length - 2)) as String;
      expect((jsonDecode(inner) as Map)['title'], _w.title);
      expect(seen, isNot(contains('Docs "a"')));
    });
  });

  group('withAx', () {
    test('a tree goes after the picture line in an untrusted block', () {
      final text = withAx('Screenshot of Finder: /p.png.', 'Button "OK" [0,0 1x1]');
      expect(text, startsWith('Screenshot of Finder: /p.png.\n\nWindow accessibility tree:\n<untrusted-content'));
      expect(text, contains('Button "OK"'));
    });

    test('a permission note stays outside the block', () {
      final text = withAx('Screenshot of Finder: /p.png.', 'Accessibility data off: allow EveryAI.');
      expect(text, isNot(contains('<untrusted-content')));
      expect(text, startsWith('Screenshot of Finder: /p.png.'));
    });
  });
}
