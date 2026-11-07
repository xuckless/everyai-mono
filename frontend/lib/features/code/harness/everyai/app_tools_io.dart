// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io';
import 'dart:isolate';

import '../../../../core/security/untrusted.dart';
import '../../live/app_endpoints.dart';
import '../../live/app_sources.dart';
import '../../live/app_view.dart';
import '../../live/flutter_app_io.dart';
import '../../live/frames.dart';
import '../../live/adb_io.dart';
import '../../live/android_device_io.dart';
import '../../live/device_screen.dart';
import '../../live/ios_simulator_io.dart';
import '../../live/live_session.dart';
import '../../live/react_native_io.dart';
import 'screen_tools_io.dart' show runBrowser;
import 'tools_io.dart' show ToolOutput, imageDataUrl;

// The `app` tool's work (see `app_tool_spec.dart`), shared by the EveryAI harness and the app's MCP host.

const _app = 'app';

/// Runs one `app` tool call ([args]) on an app running in [sessions]' shells (the first one is the caller's own).
/// Screenshots go under [root]'s `.everyai/scratch/screenshots/`; [fit] cuts a long eval result; [scrub] hides
/// secrets in what the app printed or returned.
Future<ToolOutput> runAppTool(
  Map<String, Object?> args, {
  required List<String> sessions,
  required String root,
  required bool vision,
  required String Function(String text, String name) fit,
  String Function(String text)? scrub,
}) async {
  final action = (args['action'] as String?)?.trim().isNotEmpty ?? false ? args['action']! as String : 'look';
  if (action == 'devices' || action == 'boot') return _devices(action, args, sessions.first);
  await Future.wait([IosSimulators.refresh(), AndroidDevices.refresh()]);
  final apps = AppSources.running(sessions);
  if (action == 'list') return ToolOutput(appListText(apps));
  final source = (args['source'] as String?)?.trim() ?? '';
  final SessionApp app;
  if (source.contains('://')) {
    final ep = endpointFromUrl(source);
    if (ep == null) {
      return ToolOutput(
        'Error: $source is not the address of a Flutter VM service, an Electron DevTools socket or Metro on this '
        'machine.',
        isError: true,
      );
    }
    AppSources.point(sessions.first, ep);
    app = SessionApp(ep);
  } else {
    final picked = pickApp(apps, source);
    if (picked == null) return ToolOutput(noAppText(apps, source), isError: true);
    app = picked;
  }
  final others = apps.where((a) => a.endpoint != app.endpoint).toList();
  final also = source.isEmpty && others.isNotEmpty
      ? '(Also running: ${others.map((a) => a.label).join('; ')}. Pick one with source.)\n'
      : '';
  final out = switch (app.kind) {
    AppKind.flutter => await _flutter(AppSources.flutter(app.endpoint.uri), action, args, root, vision, fit, scrub),
    AppKind.reactNative => await _reactNative(AppSources.reactNative(app.endpoint.uri), action, args, fit, scrub),
    AppKind.ios => await _device(
      IosSimulators.driver(app.endpoint.uri.path),
      IosSimulators.holds,
      app.endpoint.uri.path,
      action,
      args,
      sessions.first,
      root,
      vision,
      scrub,
    ),
    AppKind.android => await _device(
      AndroidDevices.driver(app.endpoint.uri.path),
      AndroidDevices.holds,
      app.endpoint.uri.path,
      action,
      args,
      sessions.first,
      root,
      vision,
      scrub,
    ),
    AppKind.electron => await runBrowser(
      AppSources.electron(app.endpoint.uri),
      electronArgs(action, args, vision: vision),
      root: root,
      vision: vision,
      fit: fit,
      scrub: scrub,
    ),
  };
  if (also.isEmpty) return out;
  return ToolOutput('$also${out.text}', isError: out.isError, images: out.images);
}

/// `devices` (iOS Simulators, Android devices and virtual devices here) and `boot {device}` (starts one and holds it
/// for [session]).
Future<ToolOutput> _devices(String action, Map<String, Object?> args, String session) async {
  try {
    if (action == 'devices') {
      final lines = <String>[];
      if (Platform.isMacOS) {
        final all = await IosSimulators.list();
        // One line per OS version; the booted ones first.
        final byRuntime = <String, List<String>>{};
        for (final d in all.where((d) => !d.booted)) {
          (byRuntime[d.runtime] ??= []).add(d.name);
        }
        if (all.isNotEmpty) lines.add('iOS Simulators (source "ios"):');
        for (final d in all.where((d) => d.booted)) {
          lines.add('- booted: ${d.name} (${d.runtime})${_heldText(IosSimulators.holds, d.udid, session)}');
        }
        for (final e in byRuntime.entries) {
          lines.add('- ${e.key}: ${e.value.join(', ')}');
        }
      }
      if (AndroidSdk.adb != null) {
        final running = await AndroidDevices.list();
        final avds = await AndroidDevices.avds();
        final up = {for (final d in running) d.avd};
        lines.add('Android (source "android"):');
        for (final d in running) {
          lines.add(
            '- ${d.ready ? 'running' : d.state}: ${d.name} (${d.serial})${_heldText(AndroidDevices.holds, d.serial, session)}',
          );
        }
        final off = avds.where((a) => !up.contains(a)).toList();
        if (off.isNotEmpty) lines.add('- virtual devices: ${off.join(', ')}');
        if (running.isEmpty && off.isEmpty) lines.add('- none (make a virtual device in Android Studio)');
      }
      if (lines.isEmpty) return const ToolOutput('No iOS Simulators or Android devices here.');
      return ToolOutput(['Boot one with action boot and its name.', ...lines].join('\n'));
    }
    final device = (args['device'] as String?)?.trim() ?? '';
    if (device.isEmpty) return const ToolOutput('Error: boot needs a device (a name from devices).', isError: true);
    final sims = Platform.isMacOS ? await IosSimulators.list() : const <SimDevice>[];
    final isSim = sims.any((d) => d.udid == device || d.name.toLowerCase() == device.toLowerCase());
    if (isSim) {
      final d = await IosSimulators.boot(device);
      if (IosSimulators.claim(d.udid, session) case final other?) {
        return ToolOutput('Error: ${d.name} is booted, but another session ($other) is using it.', isError: true);
      }
      return ToolOutput(
        'Booted ${d.name} (${d.runtime}, udid ${d.udid}); this session holds it. Build for it (xcodebuild '
        '-destination "id=${d.udid}", `flutter run -d ${d.udid}`, `npx expo run:ios --device ${d.udid}`), or use '
        'install {path: the built .app} and launch {bundle}; then act with source: "ios".',
      );
    }
    if (AndroidSdk.adb == null) {
      return ToolOutput('Error: no simulator or device called "$device" (devices lists them).', isError: true);
    }
    final d = await AndroidDevices.boot(device);
    if (AndroidDevices.holds.claim(d.serial, session) case final other?) {
      return ToolOutput('Error: ${d.name} is running, but another session ($other) is using it.', isError: true);
    }
    return ToolOutput(
      'Started ${d.name} (${d.serial}); this session holds it. Run the app on it (`flutter run -d ${d.serial}`, '
      '`npx expo run:android`, `./gradlew installDebug`), or use install {path: an .apk} and launch {bundle: the '
      'package}; then act with source: "android".',
    );
  } on AppError catch (e) {
    return ToolOutput('Error: ${e.message}', isError: true);
  }
}

String _heldText(DeviceHolds holds, String id, String session) {
  final h = holds.holder(id);
  return h == null ? '' : (h == session ? ', held by this session' : ', in use by another session');
}

/// The `list` action's text.
String appListText(List<SessionApp> apps) {
  if (apps.isEmpty) return noAppText(apps, '');
  return ['Apps this session runs:', for (final a in apps) '- ${a.kind.id}: ${a.label}'].join('\n');
}

/// Why no app was picked: none found, or none matching [source].
String noAppText(List<SessionApp> apps, String source) {
  if (apps.isNotEmpty) {
    return 'Error: no app matches "$source". Running: ${apps.map((a) => '${a.kind.id} (${a.label})').join('; ')}.';
  }
  return 'Error: no Flutter, React Native or Electron app is running in this session yet. Start it in the '
      'background (bash with run_in_background: `flutter run -d <device>`, `npx expo start` / `npx react-native '
      'start`, or Electron with --remote-debugging-port=0) and call app again once it printed its address. For an '
      'app started elsewhere, pass the address it printed as source. An iOS Simulator: devices lists them, boot '
      'starts one. Web pages: use browser.';
}

/// The app [source] names among [apps] (a kind, a shell id), or the newest when [source] is empty.
SessionApp? pickApp(List<SessionApp> apps, String source) {
  if (source.isEmpty) return apps.lastOrNull;
  final s = source.toLowerCase().replaceAll('_', '-');
  return apps.where((a) => a.kind.id == s || (s == 'rn' && a.kind == AppKind.reactNative)).lastOrNull ??
      apps.where((a) => a.shell?.id == source).lastOrNull;
}

/// The browser tool's arguments for an `app` call on an Electron window.
Map<String, Object?> electronArgs(String action, Map<String, Object?> args, {required bool vision}) => {
  ...args,
  'action': switch (action) {
    'look' => vision ? 'screenshot' : 'snapshot',
    'tap' => 'click',
    'logs' => 'console',
    'submit' => 'press',
    _ => action,
  },
  if (action == 'submit') 'key': 'Enter',
};

/// Actions whose own line carries no app text.
const _ours = {
  'home',
  'install',
  'launch',
  'look',
  'snapshot',
  'screenshot',
  'zoom',
  'submit',
  'scroll',
  'back',
  'drag',
  'reload',
  'restart',
};

/// Actions that change what the app shows: their result says what changed.
const _acting = {'tap', 'type', 'submit', 'scroll', 'back', 'adjust', 'long_press', 'drag'};

Future<ToolOutput> _flutter(
  FlutterApp a,
  String action,
  Map<String, Object?> args,
  String root,
  bool vision,
  String Function(String text, String name) fit,
  String Function(String text)? scrub,
) async {
  String? str(String k) => (args[k] as String?)?.trim().isEmpty ?? true ? null : (args[k] as String).trim();
  double? at(String k) => (args[k] as num?)?.toDouble();
  if (!await a.control.agentTurn()) return ToolOutput(userDrivingText(a.control.hold), isError: true);
  final gaveBack = a.control.takeGiveBack();
  var shot = args['screenshot'] == true, list = args['snapshot'] == true || gaveBack;
  ViewRect? zoom;
  String? note;
  try {
    final before = _acting.contains(action) ? await a.tree() : null;
    final String did;
    switch (action) {
      case 'look':
        if (vision) {
          shot = true;
        } else {
          list = true;
        }
        did = '';
      case 'snapshot':
        list = true;
        did = '';
      case 'screenshot':
        shot = true;
        did = '';
      case 'zoom':
        final x = at('x'), y = at('y'), w = at('width'), h = at('height');
        if (x == null || y == null || w == null || h == null || w <= 0 || h <= 0) {
          return const ToolOutput('Error: zoom needs x, y, width and height (in the frame\'s pixels).', isError: true);
        }
        if (a.width <= 0) await a.tree();
        final from = _point(a, str('frame'), x, y), to = _point(a, str('frame'), x + w, y + h);
        if (from.refusal ?? to.refusal case final why?) return ToolOutput('Error: $why', isError: true);
        zoom = (left: from.x, top: from.y, width: to.x - from.x, height: to.y - from.y);
        shot = true;
        did =
            'Zoomed into (${from.x.round()}, ${from.y.round()}) ${zoom.width.round()}×${zoom.height.round()} of the app.';
      case 'tap':
        if (str('ref') case final ref?) {
          did = await a.tap(ref);
        } else if (at('x') != null && at('y') != null) {
          final p = _point(a, str('frame'), at('x')!, at('y')!);
          if (p.refusal case final why?) return ToolOutput('Error: $why', isError: true);
          note = p.warning;
          did = await a.tapAt(p.x, p.y);
        } else {
          return const ToolOutput('Error: tap needs a ref, or x and y.', isError: true);
        }
      case 'type':
        final ref = str('ref'), text = args['text'] as String?;
        if (ref == null || text == null) return const ToolOutput('Error: type needs a ref and text.', isError: true);
        did = await a.type(ref, text, submit: args['submit'] == true);
      case 'submit':
        did = await a.submit();
      case 'adjust':
        final ref = str('ref');
        if (ref == null) return const ToolOutput('Error: adjust needs the ref of a slider.', isError: true);
        did = await a.adjust(ref, (args['steps'] as num?)?.round() ?? 1);
      case 'long_press':
        final ref = str('ref');
        if (ref == null) return const ToolOutput('Error: long_press needs a ref.', isError: true);
        did = await a.longPress(ref);
      case 'drag':
        final x = at('x'), y = at('y'), tx = at('to_x'), ty = at('to_y');
        if (x == null || y == null || tx == null || ty == null) {
          return const ToolOutput('Error: drag needs x, y, to_x and to_y.', isError: true);
        }
        final from = _point(a, str('frame'), x, y), to = _point(a, str('frame'), tx, ty);
        if (from.refusal ?? to.refusal case final why?) return ToolOutput('Error: $why', isError: true);
        did = await a.drag(from.x, from.y, to.x, to.y);
      case 'scroll':
        did = await a.scroll(at('dy') ?? 300, ref: str('ref'));
      case 'back':
        did = await a.back();
      case 'reload' || 'restart':
        did = await a.reload(restart: action == 'restart');
        list = list || !vision;
      case 'logs':
        final old = a.history;
        did = old.isEmpty
            ? 'App log:'
            : 'App log (the last ${old.length} lines, oldest first; new ones below):\n${old.join('\n')}';
      case 'eval':
        final script = args['script'] as String?;
        if (script == null || script.trim().isEmpty) {
          return const ToolOutput('Error: eval needs a script.', isError: true);
        }
        final value = await a.evaluate(script);
        did = 'Result: ${fit(scrub == null ? value : scrub(value), 'app-eval')}';
      default:
        return ToolOutput('Error: unknown app action "$action".', isError: true);
    }
    String? changed;
    if (before != null) {
      // type reads the screen itself to check the field.
      if (action != 'type') {
        await a.settle();
        await a.tree();
      }
      changed = a.changedSince(before);
      if (changed == null) {
        // Some changes come a moment later (a gesture decided on a timer, an animation's end): look again.
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await a.settle();
        await a.tree();
        changed = a.changedSince(before) ?? 'Nothing visible changed on screen.';
      }
    }
    final listed = list ? await a.snapshot() : null;
    final body = _body(
      did,
      changed: changed,
      listed: listed,
      log: a.takeLog(),
      action: action,
      scrub: scrub,
      ours: _ours.contains(action),
    );
    final notes = [if (gaveBack) gaveBackText, ?note].join('\n');
    final text = notes.isEmpty ? body : '$notes\n$body';
    if (!shot) return ToolOutput(text);
    return await _picture(a, text, zoom, root: root, vision: vision);
  } on AppError catch (e) {
    final log = a.takeLog();
    return ToolOutput(_errorText(e, log, scrub), isError: true);
  }
}

/// Where the model's ([x], [y]) in frame [frame] lands in the app's view (logical pixels). Before any screenshot
/// they are taken as logical pixels, as the element list's places are.
FramePoint _point(FlutterApp a, String? frame, double x, double y) {
  if (a.frames.latest == null && (frame == null || frame.isEmpty)) return FramePoint(x, y);
  return a.frames.map(frame, x, y, a.geometry);
}

Future<ToolOutput> _picture(
  FlutterApp a,
  String text,
  ViewRect? zoom, {
  required String root,
  required bool vision,
}) async {
  a.control.report(const LiveActivity('look', caption: 'Looking'));
  final (png, frame) = await a.frameShot(region: zoom);
  final dir = Directory('$root/.everyai/scratch/screenshots')..createSync(recursive: true);
  final path = '${dir.path}/app-${DateTime.now().millisecondsSinceEpoch}.png';
  File(path).writeAsBytesSync(png);
  final shown = path.startsWith('$root/') ? path.substring(root.length + 1) : path;
  final url = vision ? await Isolate.run(() => imageDataUrl(png, 'png')) : null;
  if (url == null) {
    return ToolOutput(
      "${text.isEmpty ? '' : '$text\n'}Saved a screenshot to $shown (this model can't view images: use snapshot, and "
      'tap by ref).',
    );
  }
  final where = frame.zoomed
      ? 'a zoom of part of the app at ${frame.imageWidth}×${frame.imageHeight}'
      : 'the app at ${frame.imageWidth}×${frame.imageHeight}';
  return ToolOutput(
    [
      if (text.isNotEmpty) text,
      'Frame ${frame.id}: $where ($shown). To tap something in it, pass frame: "${frame.id}" with x and y in this '
          "picture's pixels; snapshot lists its elements to tap by ref.",
    ].join('\n'),
    images: [(label: path, dataUrl: url)],
  );
}

Future<ToolOutput> _reactNative(
  ReactNativeApp a,
  String action,
  Map<String, Object?> args,
  String Function(String text, String name) fit,
  String Function(String text)? scrub,
) async {
  String? str(String k) => (args[k] as String?)?.trim().isEmpty ?? true ? null : (args[k] as String).trim();
  if (!await a.control.agentTurn()) return ToolOutput(userDrivingText(a.control.hold), isError: true);
  final gaveBack = a.control.takeGiveBack();
  var list = args['snapshot'] == true || gaveBack;
  try {
    final before = const {'tap', 'type', 'submit', 'long_press'}.contains(action) ? await a.tree() : null;
    final String did;
    switch (action) {
      case 'look' || 'snapshot':
        list = true;
        did = action == 'look'
            ? '(React Native draws in its simulator or emulator, so its element list stands in for a picture here.)'
            : '';
      case 'screenshot' || 'zoom':
        return const ToolOutput(
          'Error: a React Native app draws in its simulator or emulator, not here: use snapshot for its elements.',
          isError: true,
        );
      case 'tap':
        final ref = str('ref');
        if (ref == null) {
          return const ToolOutput('Error: tap needs a ref (React Native elements have no places here).', isError: true);
        }
        did = await a.tap(ref);
      case 'type':
        final ref = str('ref'), text = args['text'] as String?;
        if (ref == null || text == null) return const ToolOutput('Error: type needs a ref and text.', isError: true);
        did = await a.type(ref, text, submit: args['submit'] == true);
      case 'submit':
        final ref = str('ref');
        if (ref == null) return const ToolOutput('Error: submit needs the ref of the text input.', isError: true);
        did = await a.type(ref, args['text'] as String? ?? '', submit: true);
      case 'long_press':
        final ref = str('ref');
        if (ref == null) return const ToolOutput('Error: long_press needs a ref.', isError: true);
        did = await a.longPress(ref);
      case 'scroll' || 'back' || 'adjust' || 'drag':
        return ToolOutput(
          'Error: $action needs the simulator or emulator the app runs in; not available here yet.',
          isError: true,
        );
      case 'reload' || 'restart':
        did = await a.reload();
      case 'logs':
        final old = a.history;
        did = old.isEmpty
            ? 'App log:'
            : 'App log (the last ${old.length} lines, oldest first; new ones below):\n${old.join('\n')}';
      case 'eval':
        final script = args['script'] as String?;
        if (script == null || script.trim().isEmpty) {
          return const ToolOutput('Error: eval needs a script.', isError: true);
        }
        final value = await a.evaluate(script);
        did = 'Result: ${fit(scrub == null ? value : scrub(value), 'app-eval')}';
      default:
        return ToolOutput('Error: unknown app action "$action".', isError: true);
    }
    String? changed;
    if (before != null) {
      await a.settle();
      await a.tree();
      changed = a.changedSince(before) ?? 'Nothing visible changed in its elements.';
    }
    final listed = list ? await a.snapshot() : null;
    final body = _body(
      did,
      changed: changed,
      listed: listed,
      log: a.takeLog(),
      action: action,
      scrub: scrub,
      ours: _ours.contains(action),
    );
    return ToolOutput(gaveBack ? '$gaveBackText\n$body' : body);
  } on AppError catch (e) {
    return ToolOutput(_errorText(e, a.takeLog(), scrub), isError: true);
  }
}

/// A result's text: what was done, what changed, the element list and the app's log. What comes from the app
/// (names, values, logs, an eval result) goes in its untrusted block; [ours] marks [did] as our own words.
String _body(
  String did, {
  String? changed,
  String? listed,
  required List<String> log,
  required String action,
  String Function(String text)? scrub,
  bool ours = false,
}) {
  final logText = log.isEmpty ? (action == 'logs' ? '(nothing new)' : null) : 'App log:\n${log.join('\n')}';
  final fromApp = [
    if (!ours && did.isNotEmpty) did,
    ?changed,
    ?listed,
    if (logText != null) scrub == null ? logText : scrub(logText),
  ].join('\n');
  final head = ours && did.isNotEmpty ? did : null;
  if (fromApp.isEmpty) return head ?? '';
  return [?head, untrusted(fromApp, source: _app)].join('\n');
}

String _errorText(AppError e, List<String> log, String Function(String text)? scrub) {
  final logText = log.isEmpty ? '' : 'App log:\n${log.join('\n')}';
  final shown = scrub == null ? logText : scrub(logText);
  if (e.fromApp) {
    return 'Error: the app action failed.\n${untrusted([e.message, if (shown.isNotEmpty) shown].join('\n'), source: _app)}';
  }
  return 'Error: ${stripHidden(e.message)}${shown.isEmpty ? '' : '\n${untrusted(shown, source: _app)}'}';
}

/// One `app` call on a phone or tablet screen ([a], an iOS Simulator or an Android device), held for [session]
/// while it drives it.
Future<ToolOutput> _device(
  DeviceScreen a,
  DeviceHolds holds,
  String id,
  String action,
  Map<String, Object?> args,
  String session,
  String root,
  bool vision,
  String Function(String text)? scrub,
) async {
  String? str(String k) => (args[k] as String?)?.trim().isEmpty ?? true ? null : (args[k] as String).trim();
  double? at(String k) => (args[k] as num?)?.toDouble();
  if (holds.claim(id, session) case final other?) {
    return ToolOutput('Error: this device is in use by another session ($other).', isError: true);
  }
  final name = a.label;
  final android = a is AndroidDevice;
  if (!await a.control.agentTurn()) return ToolOutput(userDrivingText(a.control.hold), isError: true);
  final gaveBack = a.control.takeGiveBack();
  var shot = args['screenshot'] == true, list = args['snapshot'] == true || gaveBack;
  ViewRect? zoom;
  String? note;
  FramePoint point(double x, double y) =>
      a.frames.latest == null && str('frame') == null ? FramePoint(x, y) : a.frames.map(str('frame'), x, y, a.geometry);
  try {
    final before =
        const {'tap', 'type', 'submit', 'scroll', 'back', 'home', 'long_press', 'drag', 'launch'}.contains(action)
        ? await a.tree()
        : null;
    final String did;
    switch (action) {
      case 'look':
        if (vision) {
          shot = true;
        } else {
          list = true;
        }
        did = '';
      case 'snapshot':
        list = true;
        did = '';
      case 'screenshot':
        shot = true;
        did = '';
      case 'zoom':
        final x = at('x'), y = at('y'), w = at('width'), h = at('height');
        if (x == null || y == null || w == null || h == null || w <= 0 || h <= 0) {
          return const ToolOutput("Error: zoom needs x, y, width and height (in the frame's pixels).", isError: true);
        }
        if (a.width <= 0) await a.tree();
        final from = point(x, y), to = point(x + w, y + h);
        if (from.refusal ?? to.refusal case final why?) return ToolOutput('Error: $why', isError: true);
        zoom = (left: from.x, top: from.y, width: to.x - from.x, height: to.y - from.y);
        shot = true;
        did = 'Zoomed into (${from.x.round()}, ${from.y.round()}) ${zoom.width.round()}×${zoom.height.round()} pt.';
      case 'tap':
        if (str('ref') case final ref?) {
          did = await a.tap(ref);
        } else if (at('x') != null && at('y') != null) {
          if (a.width <= 0) await a.tree();
          final p = point(at('x')!, at('y')!);
          if (p.refusal case final why?) return ToolOutput('Error: $why', isError: true);
          note = p.warning;
          did = await a.tapAt(p.x, p.y);
        } else {
          return const ToolOutput('Error: tap needs a ref, or x and y.', isError: true);
        }
      case 'long_press':
        final ref = str('ref');
        if (ref == null) return const ToolOutput('Error: long_press needs a ref.', isError: true);
        did = await a.longPress(ref);
      case 'type':
        final ref = str('ref'), text = args['text'] as String?;
        if (ref == null || text == null) return const ToolOutput('Error: type needs a ref and text.', isError: true);
        did = await a.type(ref, text, submit: args['submit'] == true);
      case 'submit':
        did = await a.submit();
      case 'scroll':
        did = await a.scroll(at('dy') ?? 300, ref: str('ref'));
      case 'drag':
        final x = at('x'), y = at('y'), tx = at('to_x'), ty = at('to_y');
        if (x == null || y == null || tx == null || ty == null) {
          return const ToolOutput('Error: drag needs x, y, to_x and to_y.', isError: true);
        }
        if (a.width <= 0) await a.tree();
        final from = point(x, y), to = point(tx, ty);
        if (from.refusal ?? to.refusal case final why?) return ToolOutput('Error: $why', isError: true);
        did = await a.drag(from.x, from.y, to.x, to.y);
      case 'back':
        did = await a.back();
      case 'home':
        did = await a.home();
      case 'install':
        final path = str('path');
        if (path == null) return ToolOutput('Error: install needs a path (${a.installs}).', isError: true);
        final full = path.startsWith('/') ? path : '$root/$path';
        final fits = android
            ? full.endsWith('.apk') && File(full).existsSync()
            : full.endsWith('.app') && Directory(full).existsSync();
        if (!fits) return ToolOutput('Error: $path is not ${a.installs} here.', isError: true);
        did = await a.install(full);
      case 'launch':
        final bundle = str('bundle');
        if (bundle == null) {
          return ToolOutput('Error: launch needs bundle: the app\'s ${a.launches} (com.example.app).', isError: true);
        }
        did = await a.launch(bundle);
      case 'adjust':
        return const ToolOutput(
          'Error: on a device screen, move a slider with drag (from its thumb), or tap where it should go.',
          isError: true,
        );
      case 'logs':
        final lines = await a.logs();
        if (lines == null) {
          return const ToolOutput(
            'Error: the simulator has no app log here: run the app with a framework source (flutter, react-native) or '
            'read its output with bash_output.',
            isError: true,
          );
        }
        final text = lines.isEmpty ? '(nothing new)' : lines.join('\n');
        return ToolOutput(
          'Log of ${(a as AndroidDevice).package ?? 'the app in front'} (logcat, since the last call):\n'
          '${untrusted(scrub == null ? text : scrub(text), source: _app)}',
        );
      case 'reload' || 'restart' || 'eval':
        return ToolOutput(
          'Error: $action works on the app\'s framework source, not the device screen: use source "flutter" or '
          '"react-native" (list shows them).',
          isError: true,
        );
      default:
        return ToolOutput('Error: unknown app action "$action".', isError: true);
    }
    String? changed;
    if (before != null) {
      // type reads the screen itself to check the field.
      if (action != 'type') {
        await a.settle();
        await a.tree();
      }
      changed = a.changedSince(before);
      if (changed == null) {
        await Future<void>.delayed(const Duration(milliseconds: 700));
        await a.tree();
        changed = a.changedSince(before) ?? 'Nothing visible changed on screen.';
      }
    }
    final listed = list ? await a.snapshot() : null;
    final body = _body(
      did,
      changed: changed,
      listed: listed,
      log: const [],
      action: action,
      ours: _ours.contains(action),
    );
    final notes = [if (gaveBack) gaveBackText, ?note].join('\n');
    final text = notes.isEmpty ? body : '$notes\n$body';
    if (!shot) return ToolOutput(text);
    a.control.report(const LiveActivity('look', caption: 'Looking'));
    final (png, frame) = await a.frameShot(region: zoom);
    final dir = Directory('$root/.everyai/scratch/screenshots')..createSync(recursive: true);
    final path = '${dir.path}/${android ? 'android' : 'sim'}-${DateTime.now().millisecondsSinceEpoch}.png';
    File(path).writeAsBytesSync(png);
    final shown = path.startsWith('$root/') ? path.substring(root.length + 1) : path;
    final url = vision ? await Isolate.run(() => imageDataUrl(png, 'png')) : null;
    if (url == null) {
      return ToolOutput(
        "${text.isEmpty ? '' : '$text\n'}Saved a screenshot to $shown (this model can't view images: use snapshot, "
        'and tap by ref).',
      );
    }
    final where = frame.zoomed
        ? 'a zoom of part of $name at ${frame.imageWidth}×${frame.imageHeight}'
        : '$name at ${frame.imageWidth}×${frame.imageHeight}';
    return ToolOutput(
      [
        if (text.isNotEmpty) text,
        'Frame ${frame.id}: $where ($shown). To tap something in it, pass frame: "${frame.id}" with x and y in this '
            "picture's pixels; snapshot lists its elements to tap by ref.",
      ].join('\n'),
      images: [(label: path, dataUrl: url)],
    );
  } on AppError catch (e) {
    return ToolOutput('Error: ${stripHidden(e.message)}', isError: true);
  } on Object catch (e) {
    // AXe missing and its download failed, or simctl gone.
    return ToolOutput("Error: the device couldn't be driven: $e", isError: true);
  }
}
