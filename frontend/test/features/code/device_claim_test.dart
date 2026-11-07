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
  const tablet = AdbDevice(serial: 'emulator-5556', model: 'sdk_gphone64_arm64', state: 'device', avd: 'Tablet_API35');
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

  test('other sources and sessions that already have a device are left alone', () {
    expect(claimNamedDevice('react-native', const {}, ['a'], android: [pixel]), isNull);
    expect(AndroidDevices.holds.holder('emulator-5554'), isNull);
    AndroidDevices.ready = [pixel, tablet];
    AndroidDevices.holds.claim('emulator-5556', 'a');
    expect(claimNamedDevice('android', const {}, ['a'], android: [pixel, tablet]), isNull);
    expect(AndroidDevices.holds.holder('emulator-5554'), isNull);
  });

  test("another session's emulator isn't taken", () {
    AndroidDevices.holds.claim('emulator-5554', 'b');
    expect(claimNamedDevice('android', const {}, ['a'], android: [pixel]), contains('in use by another session'));
  });

  test('several emulators need device, which picks by name or serial', () {
    expect(claimNamedDevice('android', const {}, ['a'], android: [pixel, tablet]), contains('Pass device'));
    expect(claimNamedDevice('android', const {'device': 'Pixel_7_API35'}, ['a'], android: [pixel, tablet]), isNull);
    expect(AndroidDevices.holds.holder('emulator-5554'), 'a');
    expect(AndroidDevices.holds.holder('emulator-5556'), isNull);
  });

  test('nothing running says how to start one', () {
    expect(claimNamedDevice('android', const {}, ['a'], android: const []), contains('boot starts one'));
    expect(claimNamedDevice('ios', const {}, ['a'], simulators: const []), contains('no booted iOS Simulator'));
  });

  test('ios takes the booted simulator', () {
    const sim = SimDevice(udid: 'U1', name: 'iPhone 16', runtime: 'iOS 18.6', booted: true);
    expect(claimNamedDevice('ios', const {}, ['a'], simulators: [sim]), isNull);
    expect(IosSimulators.holds.holder('U1'), 'a');
  });
}
