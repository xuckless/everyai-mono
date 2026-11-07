// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

// Dev check of the app tool on an iOS Simulator: EVERYAI_SIM=<simulator name> [EVERYAI_AXE=<axe>] flutter test
// tool/live_apps/simulator_probe_test.dart (boots it if needed; AXe is downloaded when missing).
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:every_ai/features/code/harness/everyai/app_tools_io.dart';
import 'package:every_ai/features/code/live/ios_simulator_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final sim = Platform.environment['EVERYAI_SIM'] ?? '';
  test(
    'simulator',
    () async {
      final tmp = Directory.systemTemp.createTempSync('everyai-sim');
      Future<String> call(Map<String, Object?> args, {bool vision = true}) async {
        final t = DateTime.now();
        final out = await runAppTool(args, sessions: ['s'], root: tmp.path, vision: vision, fit: (t, _) => t);
        final text = out.text.replaceAll(RegExp(r'</?untrusted-content[^>]*>\n?'), '');
        print(
          '=== $args (${DateTime.now().difference(t).inMilliseconds} ms)${out.isError ? ' ERROR' : ''}'
          '${out.images.isEmpty ? '' : ' +image'}\n$text',
        );
        return text;
      }

      String ref(String text, String pattern) => RegExp(r'\[(i\d+)\] ' + pattern).firstMatch(text)!.group(1)!;
      await call({'action': 'devices'});
      await call({'action': 'boot', 'device': sim});
      await call({'action': 'list'});
      await call({'action': 'home', 'source': 'ios'});
      var t = await call({'action': 'snapshot', 'source': 'ios'});
      await call({'action': 'tap', 'source': 'ios', 'ref': ref(t, 'button "Settings"')});
      t = await call({'action': 'snapshot', 'source': 'ios'});
      if (t.contains('] heading "General"')) {
        await call({'action': 'back', 'source': 'ios'});
        t = await call({'action': 'snapshot', 'source': 'ios'});
      }
      if (t.contains('] button "Cancel"')) {
        await call({'action': 'tap', 'source': 'ios', 'ref': ref(t, 'button "Cancel"')});
        t = await call({'action': 'snapshot', 'source': 'ios'});
      }
      await call({'action': 'tap', 'source': 'ios', 'ref': ref(t, 'button "General"')});
      await call({'action': 'back', 'source': 'ios'});
      t = await call({'action': 'snapshot', 'source': 'ios'});
      await call({'action': 'type', 'source': 'ios', 'ref': ref(t, 'textbox'), 'text': 'wifi'});
      await call({'action': 'screenshot', 'source': 'ios'});
      await call({'action': 'zoom', 'source': 'ios', 'x': 0, 'y': 0, 'width': 300, 'height': 200});
      await call({'action': 'scroll', 'source': 'ios', 'dy': 300});
      await call({'action': 'launch', 'source': 'ios', 'bundle': 'com.apple.Preferences'});
      t = await call({'action': 'snapshot', 'source': 'ios'});
      await call({'action': 'tap', 'source': 'ios', 'ref': ref(t, 'button "General"')});
      t = await call({'action': 'snapshot', 'source': 'ios'});
      await call({'action': 'tap', 'source': 'ios', 'ref': ref(t, 'text "About"')});
      await call({'action': 'look', 'source': 'ios'}, vision: false);
      await call({'action': 'eval', 'source': 'ios', 'script': '1'});
      final udid = IosSimulators.booted.first.udid;
      var n = 0, bytes = 0;
      final sub = IosSimulators.driver(udid).stream().listen((f) {
        n++;
        bytes = f.length;
      });
      await Future<void>.delayed(const Duration(seconds: 4));
      await sub.cancel();
      print('=== stream: $n frames in 4 s, last $bytes bytes');
      IosSimulators.release('s');
    },
    skip: sim.isEmpty ? 'set EVERYAI_SIM' : null,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
