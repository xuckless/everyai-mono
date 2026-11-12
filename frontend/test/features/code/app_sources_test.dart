// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';
import 'dart:typed_data';

import 'package:every_ai/features/code/harness/everyai/app_tools_io.dart';
import 'package:every_ai/features/code/live/app_endpoints.dart';
import 'package:every_ai/features/code/live/app_sources.dart';
import 'package:every_ai/features/code/live/flutter_app_io.dart';
import 'package:every_ai/features/code/shells/shell_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('finding apps in shell output', () {
    test('the session\'s shells are scanned; source picks among the apps', () {
      final e = _shell('pick', 'bg_3', 'flutter run -d macos');
      e.emit(_bytes('A Dart VM Service on macOS is available at: http://127.0.0.1:50000/t=/\r\n'));
      final other = _shell('pick', 'bg_4', 'npx react-native start');
      other.emit(_bytes('Welcome to Metro v0.80\r\n'));
      addTearDown(() => ShellRegistry.instance.forget('pick'));
      final apps = AppSources.running(['pick']);
      expect([for (final a in apps) a.kind], [AppKind.flutter, AppKind.reactNative]);
      expect(pickApp(apps, '')!.kind, AppKind.reactNative, reason: 'the newest');
      expect(pickApp(apps, 'flutter')!.shell!.id, 'bg_3');
      expect(pickApp(apps, 'bg_4')!.kind, AppKind.reactNative);
      expect(pickApp(apps, 'electron'), isNull);
      expect(appListText(apps), contains('flutter: Flutter app (bg_3: flutter run -d macos)'));
      expect(noAppText(const [], ''), contains('run_in_background'));
      expect(AppSources.running(['someone-else']), isEmpty);
    });
  });

  group('element lists', () {
    List<String> row(String id, String flags, String actions, {String label = '', String value = ''}) => [
      id,
      '30', '60', '330', '120', // physical pixels at 3×
      label, value, '', '', flags, actions,
    ];

    test('Flutter semantics rows become roles, states and logical places', () {
      final button = flutterNode(row('9', 'isButton,hasEnabledState,isEnabled', 'tap,focus', label: 'Add'), 3)!;
      expect(button.element(800, 600).line, '[s9] button "Add"');
      expect((button.left, button.top, button.right, button.bottom), (10.0, 20.0, 110.0, 40.0));
      final field = flutterNode(
        row('6', 'isTextField,isFocused,isFocusable', 'tap,setText', label: 'Name', value: 'Ada'),
        3,
      )!;
      expect(field.element(800, 600).line, '[s6] textbox "Name" value="Ada" (focused)');
      final pw = flutterNode(row('7', 'isTextField,isObscured', 'tap', label: 'Password', value: 'hunter2'), 3)!;
      expect(pw.element(800, 600).line, '[s7] textbox "Password" (password)');
      expect(pw.element(800, 600).line, isNot(contains('hunter2')));
      expect(
        flutterNode(row('10', 'hasCheckedState,isChecked,hasEnabledState', 'tap'), 3)!.element(800, 600).line,
        '[s10] checkbox (checked, disabled)',
      );
      expect(flutterNode(row('5', '', '', label: 'Count: 1'), 3)!.element(800, 600).line, 'text "Count: 1"');
      expect(
        flutterNode(row('8', 'hasEnabledState', '', label: 'Archived 0'), 3)!.element(800, 600).line,
        'text "Archived 0 (disabled)"',
      );
      expect(flutterNode(row('3', 'scopesRoute', ''), 3), isNull, reason: 'a container with nothing to show');
      expect(flutterNode(row('4', 'isHidden', 'tap', label: 'x'), 3), isNull);
      expect(
        flutterNode(row('22', 'hasImplicitScrolling', 'scrollUp,scrollToOffset'), 3)!.element(800, 600).line,
        '[s22] scrollable',
      );
    });
  });
}

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

ShellEntry _shell(String session, String id, String command) {
  final e = ShellEntry(
    key: '$session/$id',
    id: id,
    session: session,
    command: command,
    cwd: '/tmp',
    origin: ShellOrigin.agent,
    background: true,
  );
  ShellRegistry.instance.add(e);
  return e;
}
