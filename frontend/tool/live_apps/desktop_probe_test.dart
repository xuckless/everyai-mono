// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

// Dev check of the app tool on a desktop window (macOS): EVERYAI_DESKTOP_PID=<pid of an app with a window>
// [EVERYAI_AX_HELPER=<everyai-ax>] flutter test tool/live_apps/desktop_probe_test.dart (tool/build_ax_helper.sh
// builds the helper). It clicks at a point given in EVERYAI_DESKTOP_TAP ("x,y" in window points), if set.
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:every_ai/features/code/harness/everyai/app_tools_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final pid = int.tryParse(Platform.environment['EVERYAI_DESKTOP_PID'] ?? '');
  test('desktop window', () async {
    final tmp = Directory.systemTemp.createTempSync('everyai-desktop');
    Future<String> call(Map<String, Object?> args, {bool vision = true}) async {
      final t = DateTime.now();
      final out = await runAppTool(
        args,
        sessions: ['s'],
        root: tmp.path,
        vision: vision,
        fit: (t, _) => t,
        windowPids: () async => {pid!},
      );
      final text = out.text.replaceAll(RegExp(r'</?untrusted-content[^>]*>\n?'), '');
      print(
        '=== $args (${DateTime.now().difference(t).inMilliseconds} ms)${out.isError ? ' ERROR' : ''}'
        '${out.images.isEmpty ? '' : ' +image'}\n$text',
      );
      return text;
    }

    await call({'action': 'list'});
    await call({'action': 'snapshot', 'source': 'desktop'});
    await call({'action': 'screenshot', 'source': 'desktop'});
    await call({'action': 'look', 'source': 'desktop'}, vision: false);
    final tap = Platform.environment['EVERYAI_DESKTOP_TAP']?.split(',');
    if (tap != null && tap.length == 2) {
      await call({'action': 'tap', 'source': 'desktop', 'x': double.parse(tap[0]), 'y': double.parse(tap[1])});
      await call({'action': 'snapshot', 'source': 'desktop'});
      await call({'action': 'key', 'source': 'desktop', 'key': 'Escape'});
    }
    await call({'action': 'back', 'source': 'desktop'});
  }, skip: pid == null ? 'set EVERYAI_DESKTOP_PID' : null);
}
