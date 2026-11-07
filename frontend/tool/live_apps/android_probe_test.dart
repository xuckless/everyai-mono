// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

// Dev check of the app tool on an Android emulator or device: EVERYAI_ANDROID=<serial or AVD name> flutter test
// tool/live_apps/android_probe_test.dart (starts the AVD if needed; the scrcpy server is downloaded when missing).
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:every_ai/features/code/harness/everyai/app_tools_io.dart';
import 'package:every_ai/features/code/live/android_device_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final device = Platform.environment['EVERYAI_ANDROID'] ?? '';
  test(
    'android',
    () async {
      final tmp = Directory.systemTemp.createTempSync('everyai-android');
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

      await call({'action': 'devices'});
      await call({'action': 'boot', 'device': device});
      await call({'action': 'list'});
      await call({'action': 'launch', 'source': 'android', 'bundle': 'com.android.settings'});
      var t = await call({'action': 'snapshot', 'source': 'android'});
      final search = RegExp(r'\[(a\d+)\] \w+ "Search[^"]*"').firstMatch(t)?.group(1);
      if (search != null) {
        await call({'action': 'tap', 'source': 'android', 'ref': search});
        t = await call({'action': 'snapshot', 'source': 'android'});
        final box = RegExp(r'\[(a\d+)\] textbox').firstMatch(t)?.group(1);
        if (box != null) {
          await call({'action': 'type', 'source': 'android', 'ref': box, 'text': 'wifi'});
          await call({'action': 'type', 'source': 'android', 'ref': box, 'text': 'Bluetooth ü'});
        }
        await call({'action': 'back', 'source': 'android'});
        await call({'action': 'back', 'source': 'android'});
      }
      t = await call({'action': 'snapshot', 'source': 'android'});
      await call({'action': 'scroll', 'source': 'android', 'dy': 800});
      await call({'action': 'screenshot', 'source': 'android'});
      await call({'action': 'tap', 'source': 'android', 'frame': 'f_1', 'x': 200, 'y': 300});
      await call({'action': 'logs', 'source': 'android'});
      await call({'action': 'home', 'source': 'android'});
      // The Preview's stream.
      final d = AndroidDevices.driver(AndroidDevices.ready.first.serial);
      final c = await d.scrcpy();
      var n = 0;
      final sub = c.packets.listen((_) => n++);
      c.touch(0, c.width / 2, c.height * 0.8);
      for (var i = 1; i <= 10; i++) {
        c.touch(2, c.width / 2, c.height * (0.8 - i * 0.04));
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
      c.touch(1, c.width / 2, c.height * 0.4);
      await Future<void>.delayed(const Duration(seconds: 2));
      await sub.cancel();
      print('=== scrcpy: ${c.width}×${c.height}, $n packets in 2 s after a swipe');
      await call({'action': 'home', 'source': 'android'});
      await d.closeScrcpy();
    },
    skip: device.isEmpty ? 'set EVERYAI_ANDROID' : null,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
