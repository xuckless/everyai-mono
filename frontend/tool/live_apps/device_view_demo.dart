// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

// Dev only: the Preview's device view alone, to see the live picture and drive it by hand.
//   flutter run -d macos -t tool/live_apps/device_view_demo.dart --dart-define=DEVICE=android:emulator-5554
//   (or DEVICE=ios:<udid>)
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/live/android_device_io.dart';
import 'package:every_ai/features/code/live/ios_simulator_io.dart';
import 'package:every_ai/features/code/ui/panes/preview_apps.dart';
import 'package:flutter/material.dart';

const _device = String.fromEnvironment('DEVICE', defaultValue: 'android:emulator-5554');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final theme = EveryTheme.resolve(DesignLanguage.macos, Brightness.dark);
  final (kind, id) = (_device.split(':').first, _device.substring(_device.indexOf(':') + 1));
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: EveryThemeScope(
        theme: theme,
        child: ColoredBox(
          color: theme.background,
          child: kind == 'ios'
              ? IosSimulatorView(sim: IosSimulators.driver(id), visible: true)
              : AndroidDeviceView(device: AndroidDevices.driver(id), visible: true),
        ),
      ),
    ),
  );
}
