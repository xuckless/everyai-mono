// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

// Dev check of the app tool on the notes demo (see the tester rig): EVERYAI_FLUTTER_VM=<url> flutter test
// tool/live_apps/notes_probe_test.dart
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:every_ai/features/code/harness/everyai/app_tools_io.dart';
import 'package:every_ai/features/code/live/app_sources.dart';
import 'package:every_ai/features/code/shells/shell_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final url = Platform.environment['EVERYAI_FLUTTER_VM'] ?? '';
  test('notes demo', () async {
    final tmp = Directory.systemTemp.createTempSync('everyai-notes');
    final e = ShellEntry(
      key: 'n/bg_1',
      id: 'bg_1',
      session: 'n',
      command: 'flutter run',
      cwd: tmp.path,
      origin: ShellOrigin.agent,
      background: true,
    );
    ShellRegistry.instance.add(e);
    e.emit(Uint8List.fromList(utf8.encode('A Dart VM Service on X is available at: $url\r\n')));
    Future<String> call(Map<String, Object?> args) async {
      final out = await runAppTool(args, sessions: ['n'], root: tmp.path, vision: true, fit: (t, _) => t);
      final text = out.text.replaceAll(RegExp(r'</?untrusted-content[^>]*>\n?'), '');
      print('=== $args${out.isError ? ' ERROR' : ''}${out.images.isEmpty ? '' : ' +image'}\n$text');
      return text;
    }

    String ref(String text, String pattern) => RegExp(r'\[(s\d+)\] ' + pattern).firstMatch(text)!.group(1)!;
    await call({'action': 'restart'});
    var t = await call({'action': 'snapshot'});
    await call({'action': 'type', 'ref': ref(t, 'textbox "Email"'), 'text': 'a@b.co'});
    await call({'action': 'type', 'ref': ref(t, 'textbox "Password"'), 'text': 'x'});
    await call({'action': 'tap', 'ref': ref(t, 'button "Continue')});
    t = await call({'action': 'snapshot'});
    await call({'action': 'type', 'ref': ref(t, 'textbox "New note"'), 'text': 'Buy milk'});
    await call({'action': 'tap', 'ref': ref(t, 'button "Add note"')});
    t = await call({'action': 'snapshot'});
    await call({'action': 'adjust', 'ref': ref(t, 'slider'), 'steps': 3});
    await call({'action': 'tap', 'ref': ref(t, 'switch "Pin new notes"')});
    await call({'action': 'screenshot'});
    await call({'action': 'tap', 'x': 400, 'y': 28, 'frame': 'f_1'});
    await call({'action': 'drag', 'x': 300, 'y': 500, 'to_x': 300, 'to_y': 150});
    await call({'action': 'scroll', 'dy': -2000});
    t = await call({'action': 'snapshot'});
    final del = ref(t, 'button "Delete Call Ada"');
    await call({'action': 'tap', 'ref': del});
    await call({'action': 'tap', 'ref': del});
    await call({'action': 'snapshot'});
    await call({'action': 'logs'});
    ShellRegistry.instance.forget('n');
    await AppSources.stopAll();
  }, skip: url.isEmpty ? 'set EVERYAI_FLUTTER_VM' : null, timeout: const Timeout(Duration(minutes: 3)));
}
