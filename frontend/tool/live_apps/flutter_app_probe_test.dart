// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

// Dev check of the Flutter driver against a running app: EVERYAI_FLUTTER_VM=<the VM service URL flutter run
// printed> flutter test tool/live_apps/flutter_app_probe_test.dart
// ignore_for_file: avoid_print

import 'dart:io';

import 'dart:convert';
import 'dart:typed_data';

import 'package:every_ai/features/code/harness/everyai/app_tools_io.dart';
import 'package:every_ai/features/code/harness/everyai/tools_io.dart' show ToolOutput;
import 'package:every_ai/features/code/live/app_sources.dart';
import 'package:every_ai/features/code/live/flutter_app_io.dart';
import 'package:every_ai/features/code/shells/shell_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final url = Platform.environment['EVERYAI_FLUTTER_VM'];
  toolProbe(url ?? '');
  test(
    'drives a running Flutter app',
    () async {
      final app = FlutterApp(Uri.parse(url!));
      print(await app.snapshot());
      final before = app.lastTree;
      final add = before.firstWhere((n) => n.name == 'Add');
      print(await app.tap(add.ref));
      await app.settle();
      await app.tree();
      print('changed: ${app.changedSince(before)}');
      final name = app.lastTree.firstWhere((n) => n.role == 'textbox');
      final b2 = app.lastTree;
      print(await app.type(name.ref, 'Grace', submit: true));
      await app.settle();
      await app.tree();
      print('changed: ${app.changedSince(b2)}');
      print(await app.scroll(400));
      await app.settle();
      print(await app.snapshot());
      final (png, f) = await app.frameShot();
      File('${Directory.systemTemp.path}/everyai-flutter-shot.png').writeAsBytesSync(png);
      print('frame ${f.id} ${f.imageWidth}x${f.imageHeight} ${png.length} bytes');
      final (zpng, zf) = await app.frameShot(region: (left: 0.0, top: 0.0, width: 200.0, height: 150.0));
      File('${Directory.systemTemp.path}/everyai-flutter-zoom.png').writeAsBytesSync(zpng);
      print('zoom ${zf.imageWidth}x${zf.imageHeight}');
      print(await app.tapAt(400, 300));
      print('eval: ${await app.evaluate('1 + 2')}');
      print(await app.reload());
      print('log: ${app.takeLog()}');
      await app.close();
    },
    skip: url == null ? 'set EVERYAI_FLUTTER_VM' : null,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

/// The `app` tool as the agent calls it, finding the app in a shell's output.
void toolProbe(String url) {
  test(
    'the app tool finds and drives it',
    () async {
      final tmp = Directory.systemTemp.createTempSync('everyai-app-tool');
      final e = ShellEntry(
        key: 's/bg_1',
        id: 'bg_1',
        session: 'probe',
        command: 'flutter run -d flutter-tester',
        cwd: tmp.path,
        origin: ShellOrigin.agent,
        background: true,
      );
      ShellRegistry.instance.add(e);
      e.emit(
        Uint8List.fromList(
          utf8.encode('Launching…\r\nA Dart VM Service on Flutter test device is available at: $url\r\n'),
        ),
      );
      Future<ToolOutput> call(Map<String, Object?> args, {bool vision = true}) =>
          runAppTool(args, sessions: ['probe'], root: tmp.path, vision: vision, fit: (t, _) => t);
      for (final args in [
        {'action': 'list'},
        {'action': 'look'},
        {'action': 'snapshot'},
        {'action': 'tap', 'ref': 's9'},
        {'action': 'tap', 'x': 400, 'y': 150, 'frame': 'f_1'},
        {'action': 'type', 'ref': 's6', 'text': 'Linus', 'submit': true},
        {'action': 'zoom', 'x': 0, 'y': 0, 'width': 400, 'height': 300},
        {'action': 'eval', 'script': 'DateTime(2026).year'},
        {'action': 'logs'},
        {'action': 'tap', 'ref': 's999'},
      ]) {
        final out = await call(args);
        print('=== $args → ${out.isError ? 'ERROR ' : ''}${out.images.length} image(s)\n${out.text}');
      }
      print('=== non-vision look\n${(await call({'action': 'look'}, vision: false)).text}');
      ShellRegistry.instance.forget('probe');
      await AppSources.stopAll();
    },
    skip: url.isEmpty ? 'set EVERYAI_FLUTTER_VM' : null,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
