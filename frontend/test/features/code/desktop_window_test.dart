// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io';

import 'package:every_ai/features/code/harness/everyai/shell_io.dart' show withNestedDisplay;
import 'package:every_ai/features/code/live/app_view.dart';
import 'package:every_ai/features/code/live/desktop_window_io.dart';
import 'package:every_ai/features/code/live/device_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the helper tree: roles, window-relative places, chrome left out, secrets, refs only where acting', () {
    Map<String, Object?> n(
      String path,
      String role, {
      String? sub,
      String? title,
      String? value,
      String? desc,
      List<String> actions = const [],
      bool enabled = true,
      double x = 110,
      double y = 220,
    }) => {
      'path': path,
      'role': role,
      'subrole': ?sub,
      'title': ?title,
      'value': ?value,
      'desc': ?desc,
      'actions': actions,
      'enabled': enabled,
      'x': x,
      'y': y,
      'w': 80,
      'h': 20,
    };
    final out = flattenAxHelperTree(
      {
        'nodes': [
          n('0', 'AXWindow', title: 'Main'),
          n('0.0', 'AXButton', sub: 'AXCloseButton', actions: ['AXPress']),
          n('0.1', 'AXButton', title: 'Save', actions: ['AXPress']),
          n('0.2', 'AXTextField', desc: 'Name', value: 'Ada'),
          n('0.3', 'AXTextField', sub: 'AXSecureTextField', desc: 'Password', value: '••••'),
          n('0.4', 'AXCheckBox', title: 'Remember', value: '1', actions: ['AXPress']),
          n('0.5', 'AXStaticText', value: 'Ready'),
          n('0.6', 'AXImage', desc: 'logo'),
          n('0.7', 'AXButton', title: 'Off', enabled: false, actions: ['AXPress']),
        ],
      },
      left: 100,
      top: 200,
    );
    final lines = [
      for (final (node, path, _) in out)
        '$path ${node.ref.isEmpty ? '-' : 'ref'} ${node.role} ${node.name} '
            '${node.value} ${node.state} ${node.left},${node.top}',
    ];
    expect(lines, [
      '0.1 ref button Save null [] 10.0,20.0',
      '0.2 ref textbox Name Ada [] 10.0,20.0',
      '0.3 ref textbox Password null [] 10.0,20.0',
      '0.4 ref checkbox Remember null [checked] 10.0,20.0',
      '0.5 - text Ready null [] 10.0,20.0',
      '0.7 ref button Off null [disabled] 10.0,20.0',
    ]);
    expect(out[2].$1.secret, isTrue);
  });

  test('a list entry belongs to its row', () {
    final rows = axRowPaths({
      'nodes': [
        {'path': '0', 'role': 'AXWindow'},
        {'path': '0.3.1', 'role': 'AXRow'},
        {'path': '0.3.1.0.0', 'role': 'AXTextField'},
      ],
    });
    expect(rowOf('0.3.1.0.0', rows), '0.3.1');
    expect(rowOf('0.3.1', rows), '0.3.1');
    expect(rowOf('0.2', rows), isNull);
  });

  test('key types text unless a password field may have the focus', () {
    expect(keyTypesText('hello'), isTrue);
    expect(keyTypesText('a'), isTrue);
    expect(keyTypesText('Enter'), isFalse);
    expect(keyTypesText('cmd+s'), isFalse);
    const user = AppNode(ref: 'w1', role: 'textbox', name: 'User', state: ['focused']);
    const pass = AppNode(ref: 'w2', role: 'textbox', name: 'Password', secret: true);
    const passFocused = AppNode(ref: 'w2', role: 'textbox', name: 'Password', secret: true, state: ['focused']);
    expect(secretFocusRefusal([user, pass], focusKnown: true), isNull);
    expect(secretFocusRefusal([user, passFocused], focusKnown: true), contains('has the focus'));
    expect(
      secretFocusRefusal([const AppNode(ref: 'w1', role: 'textbox', name: 'User'), pass], focusKnown: false),
      contains("can't be seen"),
    );
    expect(secretFocusRefusal([user, pass], focusKnown: false), isNull, reason: 'the tree shows another field focused');
    expect(secretFocusRefusal([const AppNode(ref: 'w1', role: 'textbox', name: 'User')], focusKnown: false), isNull);
  });

  test("a session's own display goes on top of its shells' environment; empty values remove", () {
    final base = {'DISPLAY': ':0', 'WAYLAND_DISPLAY': 'wayland-0', 'HOME': '/home/a'};
    expect(withNestedDisplay(base, const {}), same(base));
    expect(withNestedDisplay(base, const {'DISPLAY': ':7', 'GDK_BACKEND': 'x11', 'WAYLAND_DISPLAY': ''}), {
      'DISPLAY': ':7',
      'HOME': '/home/a',
      'GDK_BACKEND': 'x11',
    });
  });

  test('the helpers ship as assets, and the Linux one is valid Python', () async {
    expect(File('assets/helpers/everyai_win.cs').readAsStringSync(), contains('static int Main(string[] argv)'));
    final py = File('assets/helpers/everyai_x11.py');
    expect(py.existsSync(), isTrue);
    final r = await Process.run('python3', ['-c', 'import ast,sys; ast.parse(open(sys.argv[1]).read())', py.path]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
  }, skip: Platform.isWindows ? 'python3' : null);

  test('key combos', () {
    final c = splitKeyCombo('cmd+Shift+S');
    expect(c.mods, ['cmd', 'shift']);
    expect(c.key, 's');
    expect(splitKeyCombo('Enter').mods, isEmpty);
    expect(splitKeyCombo('Enter').key, 'enter');
  });
}
