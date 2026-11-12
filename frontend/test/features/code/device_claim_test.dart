// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:every_ai/features/code/harness/everyai/app_tools_io.dart';
import 'package:every_ai/features/code/live/android_device_io.dart';
import 'package:every_ai/features/code/live/app_sources.dart';
import 'package:every_ai/features/code/live/app_endpoints.dart';
import 'package:every_ai/features/code/live/ios_simulator_io.dart';
import 'package:flutter_test/flutter_test.dart';

// Issue #31: an emulator started outside the session's shells (an outside lead, `npx expo run:android`) was listed by
// devices but `source: "android"` found no app.
void main() {
  const pixel = AdbDevice(serial: 'emulator-5554', model: 'sdk_gphone64_arm64', state: 'device', avd: 'Pixel_7_API35');
  tearDown(() {
    AndroidDevices.ready = const [];
    for (final s in ['a', 'b']) {
      AndroidDevices.holds.release(s);
      IosSimulators.holds.release(s);
    }
  });

  test('naming android takes the one free emulator for the session', () {
    AndroidDevices.ready = [pixel];
    expect(claimNamedDevice('android', const {}, ['a'], android: [pixel]), isNull);
    expect(AndroidDevices.holds.holder('emulator-5554'), 'a');
    expect(AppSources.running(['a']).map((a) => a.kind), contains(AppKind.android));
  });

  test("another session's emulator isn't taken", () {
    AndroidDevices.holds.claim('emulator-5554', 'b');
    expect(claimNamedDevice('android', const {}, ['a'], android: [pixel]), contains('in use by another session'));
  });
}
