// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:every_ai/features/code/live/android_device_io.dart';
import 'package:flutter_test/flutter_test.dart';

String _node(
  String cls, {
  String text = '',
  String desc = '',
  String bounds = '[0,0][100,100]',
  bool clickable = false,
  bool checkable = false,
  bool checked = false,
  bool password = false,
  bool focused = false,
  String pkg = 'com.example',
  String children = '',
}) =>
    '<node text="$text" resource-id="com.example:id/x" class="android.widget.$cls" package="$pkg" '
    'content-desc="$desc" checkable="$checkable" checked="$checked" clickable="$clickable" enabled="true" '
    'focusable="false" focused="$focused" scrollable="false" long-clickable="false" password="$password" '
    'selected="false" bounds="$bounds" hint="">$children</node>';

void main() {
  test('uiautomator tree: roles, names from children, secrets, toggles, reading order, the app in front', () {
    final xml =
        '<?xml version="1.0"?><hierarchy rotation="0">'
        '${_node(
          'FrameLayout',
          bounds: '[0,0][1080,2400]',
          children: [
            _node('TextView', text: 'Title', bounds: '[0,100][1080,200]'),
            _node('EditText', text: 'ada@example.com', bounds: '[0,300][1080,400]', focused: true),
            _node('EditText', text: '••••', bounds: '[0,450][1080,550]', password: true),
            _node('Switch', text: 'Pin', bounds: '[0,600][1080,700]', checkable: true, checked: true),
            // A Compose-style clickable row: its name comes from its texts, which aren't listed again.
            _node(
              'View',
              bounds: '[0,800][1080,900]',
              clickable: true,
              children: [_node('TextView', text: 'Wi-Fi', bounds: '[10,800][500,850]'), _node('TextView', text: 'Connected', bounds: '[10,850][500,900]')].join(),
            ),
            _node('ImageView', desc: 'Back', bounds: '[0,0][100,100]', clickable: true),
            _node('TextView', text: 'clock', pkg: 'com.android.systemui', bounds: '[900,0][1080,50]'),
          ].join(),
        )}'
        '</hierarchy>';
    final r = parseUiAutomator(xml);
    expect(r.width, 1080);
    expect(r.height, 2400);
    expect(r.package, 'com.example');
    final lines = [for (final n in r.nodes) '${n.role} ${n.name} ${n.value} ${n.state}'];
    expect(lines.first, startsWith('button Back'));
    expect(lines, contains('textbox  ada@example.com [focused]'));
    final pw = r.nodes.firstWhere((n) => n.secret);
    expect(pw.value, isNull);
    expect(lines, contains('switch Pin null [checked]'));
    expect(lines, contains('button Wi-Fi Connected null []'));
    expect(lines.where((l) => l.startsWith('text Wi-Fi')), isEmpty);
    expect(parseUiAutomator('not xml').nodes, isEmpty);
  });
}
