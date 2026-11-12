// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../../../core/process/supervisor.dart';
import '../../../../core/security/untrusted.dart';
import '../../live/app_endpoints.dart';
import '../../live/app_sources.dart';
import '../../live/app_view.dart';
import '../../live/flutter_app_io.dart';
import '../../live/frames.dart';
import '../../live/adb_io.dart';
import '../../live/agent_logins.dart';
import '../../live/android_device_io.dart';
import '../../live/desktop_window_io.dart';
import '../../live/device_screen.dart';
import '../../live/ios_simulator_io.dart';
import '../../live/live_session.dart';
import '../../live/nested_display_io.dart';
import '../../live/react_native_io.dart';
import 'screen_tools_io.dart' show fillTurnRefusal, runBrowser;
import 'screen_windows.dart' show sensitiveWindow;
import 'tools_io.dart' show ToolOutput, imageDataUrl;
import 'window_capture_io.dart' show executableOf;

// The `app` tool's work (see `app_tool_spec.dart`), shared by the EveryAI harness and the app's MCP host.

const _app = 'app';

/// Runs one `app` tool call ([args]) on an app running in [sessions]' shells (the first one is the caller's own).
/// Screenshots go under [root]'s `.everyai/scratch/screenshots/`; [fit] cuts a long eval result; [scrub] hides
/// secrets in what the app printed or returned. [logins]: the saved logins the agent may fill and the user's
/// switches for them (null: none to fill, the switches as they are by default).
Future<ToolOutput> runAppTool(
  Map<String, Object?> args, {
  required List<String> sessions,
  required String root,
  required bool vision,
  required String Function(String text, String name) fit,
  String Function(String text)? scrub,
  Future<Set<int>> Function()? windowPids,
  LoginAccess? logins,
}) async {
  final out = await _runAppTool(args, sessions, root, vision, fit, scrub, windowPids, logins);
  // Values filled this session never come back, whatever the app did with them.
  if (logins == null) return out;
  final text = logins.redact(out.text);
  return text == out.text
      ? out
      : ToolOutput(text, isError: out.isError, observation: out.observation, images: out.images);
}

Future<ToolOutput> _runAppTool(
  Map<String, Object?> args,
  List<String> sessions,
  String root,
  bool vision,
  String Function(String text, String name) fit,
  String Function(String text)? scrub,
  Future<Set<int>> Function()? windowPids,
  LoginAccess? logins,
) async {
  final action = (args['action'] as String?)?.trim().isNotEmpty ?? false ? args['action']! as String : 'look';
  if (action == 'logins') {
    return ToolOutput(loginsListText(await logins?.usable() ?? const [], policy: logins?.policy ?? LoginPolicy.open));
  }
  if (action == 'devices' || action == 'boot') return _devices(action, args, sessions.first);
  await Future.wait([IosSimulators.refresh(), AndroidDevices.refresh()]);
  final source = (args['source'] as String?)?.trim() ?? '';
  // Metro started where this session can't see it: its usual address answers for "react-native".
  if (source == 'react-native' || source == 'rn' || (action == 'list' && source.isEmpty)) {
    if (!AppSources.running(sessions).any((a) => a.kind == AppKind.reactNative) && await _metroAt(_defaultMetro)) {
      AppSources.point(sessions.first, AppEndpoint(AppKind.reactNative, _defaultMetro));
    }
  }
  // Desktop apps the session started (or built in its folder) that have a window now.
  if (windowPids != null) {
    await _findWindows(sessions, windowPids, root);
  } else if (NestedDisplays.displayOf(sessions) != null) {
    await _findWindows(sessions, () async => const {}, root);
  }
  if (action == 'list' && source.contains('://')) {
    if (endpointFromUrl(source) case final ep?) {
      if (await _foreignDevTools(ep, windowPids, root) case final why?) return ToolOutput('Error: $why', isError: true);
      AppSources.point(sessions.first, ep);
    }
  }
  if (action != 'list') {
    if (claimNamedDevice(source, args, sessions) case final why?) return ToolOutput('Error: $why', isError: true);
  }
  final apps = AppSources.running(sessions);
  if (action == 'list') {
    final rn = apps.where((a) => a.kind == AppKind.reactNative).toList();
    final notes = [for (final a in rn) await _metroNote(a.endpoint.uri)];
    return ToolOutput([appListText(apps), ...notes.nonNulls].join('\n'));
  }
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
    if (await _foreignDevTools(ep, windowPids, root) case final why?) return ToolOutput('Error: $why', isError: true);
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
    AppKind.flutter => await _flutter(
      AppSources.flutter(app.endpoint.uri),
      action,
      args,
      root,
      vision,
      fit,
      scrub,
      logins,
    ),
    AppKind.reactNative => await _reactNative(
      AppSources.reactNative(app.endpoint.uri),
      action,
      args,
      fit,
      scrub,
      logins,
    ),
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
      logins,
    ),
    AppKind.desktop => await _device(
      DesktopWindows.driver(int.parse(app.endpoint.uri.path))
        ..window = (args['window'] as String?)?.trim()
        ..clicks = ((args['count'] as num?)?.toInt() ?? 1).clamp(1, 3),
      DesktopWindows.holds,
      app.endpoint.uri.path,
      action,
      args,
      sessions.first,
      root,
      vision,
      scrub,
      logins,
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
      logins,
    ),
    AppKind.electron => await runBrowser(
      AppSources.electron(app.endpoint.uri),
      electronArgs(action, args, vision: vision),
      root: root,
      vision: vision,
      fit: fit,
      scrub: scrub,
      logins: logins,
    ),
  };
  if (also.isEmpty) return out;
  return ToolOutput('$also${out.text}', isError: out.isError, images: out.images);
}

final _defaultMetro = Uri.parse('http://127.0.0.1:8081');

/// Points [session] at the desktop windows of processes it started ([windowPids]) or whose program is inside
/// [root] (an app built in the project); on Linux every window on the session's own headless display is its own.
Future<void> _findWindows(List<String> sessions, Future<Set<int>> Function() windowPids, String root) async {
  if (!(Platform.isMacOS || Platform.isLinux || Platform.isWindows)) return;
  try {
    final nested = NestedDisplays.displayOf(sessions);
    final pids = nested == null ? await windowPids() : const <int>{};
    final mine = <int>{};
    for (final w in await helperWindows(const [], display: nested)) {
      final exe = w.exe.isNotEmpty ? w.exe : await executableOf(w.pid);
      final norm = Platform.isWindows ? exe.replaceAll('\\', '/').toLowerCase() : exe;
      final under = Platform.isWindows ? '${root.replaceAll('\\', '/').toLowerCase()}/' : '$root/';
      if (nested == null && !pids.contains(w.pid) && !norm.startsWith(under)) continue;
      // Never a password manager, even one the session started.
      final asScreen = (id: w.id, pid: w.pid, owner: w.app, title: w.title, width: w.w.round(), height: w.h.round());
      if (sensitiveWindow(asScreen, own: true, exe: exe) != null) continue;
      if (w.pid <= 0) continue;
      mine.add(w.pid);
      DesktopWindows.driver(w.pid, display: nested, nested: nested != null).known(w);
    }
    for (final pid in mine) {
      AppSources.point(sessions.first, AppEndpoint(AppKind.desktop, Uri.parse('window:$pid')));
    }
  } on Object {
    // No windows to add (no helper here): the other sources still work.
  }
}

/// Why a DevTools address the agent named ([ep], an Electron app's) can't be driven: the process listening there isn't
/// one of this session's (or a program built in [root]). A browser the user runs with remote debugging holds their
/// signed-in pages. Null when it is the session's, or when the session's processes aren't known.
Future<String?> _foreignDevTools(AppEndpoint ep, Future<Set<int>> Function()? sessionPids, String root) async {
  if (ep.kind != AppKind.electron || sessionPids == null || Platform.isWindows) return null;
  final port = ep.uri.hasPort ? ep.uri.port : null;
  if (port == null) return null;
  final r = await ProcessSupervisor.instance.runBounded(
    'lsof',
    ['-nP', '-iTCP:$port', '-sTCP:LISTEN', '-t'],
    timeout: const Duration(seconds: 10),
    owner: const ProbeOwner('devtools-check'),
    maxOutputBytes: 64 * 1024,
  );
  final Set<int> listeners;
  switch (r) {
    // 1: nothing listens there (nothing to attach to; the attach itself then fails).
    case Finished(:final code, :final stdout) when code == 0 || code == 1:
      listeners = {for (final l in stdout.split('\n')) ?int.tryParse(l.trim())};
    default:
      // Who listens is unknown: refused, never read as allowed.
      return "EveryAI couldn't check who listens on port $port ($r), so it won't attach to it.";
  }
  if (listeners.isEmpty) return null;
  final mine = await sessionPids();
  for (final pid in listeners) {
    if (mine.contains(pid) || (await executableOf(pid)).startsWith('$root/')) return null;
  }
  return 'port $port belongs to a program this session didn\'t start (perhaps the user\'s own browser, with their '
      'signed-in pages), so EveryAI won\'t attach to it. Start the app from this session (bash run_in_background), '
      'then use its address.';
}

/// Whether Metro answers at [metro].
Future<bool> _metroAt(Uri metro) async {
  final client = HttpClient()..connectionTimeout = const Duration(milliseconds: 600);
  try {
    final res = await (await client.getUrl(metro.replace(path: '/status'))).close().timeout(const Duration(seconds: 2));
    return (await res.transform(const SystemEncoding().decoder).join()).contains('packager-status:running');
  } on Object {
    return false;
  } finally {
    client.close(force: true);
  }
}

/// Whether an app is connected to Metro at [metro], for `list`.
Future<String?> _metroNote(Uri metro) async {
  final client = HttpClient()..connectionTimeout = const Duration(milliseconds: 600);
  try {
    final res = await (await client.getUrl(metro.replace(path: '/json/list')))
        .close()
        .timeout(const Duration(seconds: 2));
    final body = await res.transform(const SystemEncoding().decoder).join();
    final targets = body.trim().startsWith('[') ? body.split('"webSocketDebuggerUrl"').length - 1 : 0;
    return targets == 0
        ? 'Metro at $metro is running, but no app is connected to it yet: open the app on the simulator or emulator '
              '(pointed at this Metro), then use source "react-native".'
        : 'Metro at $metro has $targets app connection${targets == 1 ? '' : 's'}.';
  } on Object {
    return "Metro at $metro doesn't answer (is the dev server running?).";
  } finally {
    client.close(force: true);
  }
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
      return ToolOutput(
        [
          'Boot one with action boot and its name (a simulator name on several iOS versions: "iPhone 16e (iOS 18.6)").',
          ...lines,
        ].join('\n'),
      );
    }
    final device = (args['device'] as String?)?.trim() ?? '';
    if (device.isEmpty) return const ToolOutput('Error: boot needs a device (a name from devices).', isError: true);
    final sims = Platform.isMacOS ? await IosSimulators.list() : const <SimDevice>[];
    final base = device.replaceFirst(RegExp(r'\s*\(i(?:Pad)?OS [\d.]+\)$'), '').toLowerCase();
    final isSim = sims.any((d) => d.udid == device || d.name.toLowerCase() == base);
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

/// `source: "android"` or `"ios"` while this session has no such device yet (an outside lead, or an emulator started
/// where its shells don't show): takes the running device no other session holds, or the one `device` names. Why
/// none could be taken, or null (taken, or nothing to do).
String? claimNamedDevice(
  String source,
  Map<String, Object?> args,
  List<String> sessions, {
  @visibleForTesting List<AdbDevice>? android,
  @visibleForTesting List<SimDevice>? simulators,
}) {
  final s = source.toLowerCase();
  final kind = switch (s) {
    'android' => AppKind.android,
    'ios' => AppKind.ios,
    _ => null,
  };
  if (kind == null || AppSources.running(sessions).any((a) => a.kind == kind)) return null;
  final isAndroid = kind == AppKind.android;
  final want = ((args['device'] as String?) ?? '').trim().toLowerCase().replaceAll('_', ' ');
  bool named(List<String> names) => want.isEmpty || names.any((n) => n.toLowerCase().replaceAll('_', ' ') == want);
  final DeviceHolds holds = isAndroid ? AndroidDevices.holds : IosSimulators.holds;
  final all = isAndroid
      ? [
          for (final d in android ?? AndroidDevices.ready)
            if (named([d.serial, d.model, d.name, ?d.avd])) (d.serial, '${d.name} (${d.serial})'),
        ]
      : [
          for (final d in simulators ?? IosSimulators.booted)
            if (named([d.udid, d.name])) (d.udid, '${d.name} (${d.runtime})'),
        ];
  final free = all.where((d) => holds.holder(d.$1) == null || sessions.contains(holds.holder(d.$1))).toList();
  final what = isAndroid ? 'Android emulator or device' : 'iOS Simulator';
  final up = isAndroid ? 'running' : 'booted';
  if (free.length == 1) {
    holds.claim(free.single.$1, sessions.first);
    return null;
  }
  if (free.length > 1) {
    return 'several ${what}s are $up: ${free.map((d) => d.$2).join('; ')}. Pass device with the one to use.';
  }
  if (all.isNotEmpty) {
    return '${all.map((d) => d.$2).join('; ')} ${all.length == 1 ? 'is' : 'are'} in use by another session.';
  }
  return want.isEmpty
      ? 'no $up $what (devices lists them; boot starts one).'
      : 'no $up $what called "${args['device']}" (devices lists them).';
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
  return 'Error: no app found in this session\'s commands. Started it yourself in a shell this tool can\'t see, or '
      'elsewhere? Pass the address it printed as source (Electron: the ws://…/devtools/browser/… line; Flutter: the '
      'VM service http://… URL; React Native: Metro\'s http://localhost:8081). Not started yet: run it in the '
      'background (`flutter run -d <device>`, `npx expo start`, Electron with --remote-debugging-port=<a free port>) '
      '(bash with run_in_background) and call app again once it printed its address. Phones and tablets: devices lists simulators and emulators, '
      'boot starts one. Web pages: use browser.';
}

/// The app [source] names among [apps] (a kind, a shell id), or the newest when [source] is empty.
SessionApp? pickApp(List<SessionApp> apps, String source) {
  // With nothing named, a framework source (richer) wins over the same app's bare window.
  if (source.isEmpty) return apps.where((a) => a.kind != AppKind.desktop).lastOrNull ?? apps.lastOrNull;
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
  'fill_login',
};

/// Actions that change what the app shows: their result says what changed.
const _acting = {'tap', 'type', 'submit', 'scroll', 'back', 'adjust', 'long_press', 'drag', 'fill_login'};

/// fill_login on an app screen: the login named in [args] typed into field `ref` by [type] (which may type into a
/// password field). What the result says ([did]) or why it couldn't ([error]); never the value. App screens have no
/// site: [appScreenFillVerdict] decides what the "fill on any site" switch means here. [control]: the screen's driving
/// lock, checked again after a wait for the user's Allow.
Future<({String? did, String? error})> appFill(
  Map<String, Object?> args,
  LoginAccess? logins,
  Future<void> Function(String ref, String value, bool submit) type, {
  LiveControl? control,
}) async {
  final name = (args['login'] as String?)?.trim() ?? '';
  final ref = (args['ref'] as String?)?.trim() ?? '';
  final field = LoginField.parse(args['field'] ?? 'password');
  if (field == null) return (did: null, error: 'fill_login field is "username", "password" or "code".');
  if (ref.isEmpty) return (did: null, error: 'fill_login needs the ref of the field (snapshot lists them).');
  final all = await logins?.usable() ?? const <LoginEntry>[];
  if (logins == null || all.isEmpty) {
    return (
      did: null,
      error: 'there are no saved logins for this project. The user adds them in Settings > Code > Logins; ask them.',
    );
  }
  final e = all.where((l) => l.name == name.toLowerCase()).firstOrNull;
  if (e == null) {
    return (
      did: null,
      error:
          '${name.isEmpty ? 'fill_login needs login' : 'no saved login is called "$name"'}. Saved logins: '
          '${all.map((l) => '${l.name} (${l.site})').join(', ')}.',
    );
  }
  if (fillRefusal(e, field, policy: logins.policy) ?? appScreenFillVerdict(e, logins.policy) case final why?) {
    return (did: null, error: why);
  }
  if (await logins.consent(e) case final why?) return (did: null, error: why);
  // The wait for Allow may have lasted minutes: the user may have taken the screen meanwhile.
  if (control != null) {
    if (await fillTurnRefusal(control) case final why?) return (did: null, error: why);
  }
  final String value;
  try {
    value = await logins.valueOf(e, field);
  } on StateError catch (err) {
    return (did: null, error: err.message);
  }
  final submit = args['submit'] == true;
  try {
    await type(ref, value, submit);
  } on AppError catch (err) {
    // A driver's message may quote what the field shows (or the expression it ran): never the value, in any form.
    var said = err.message;
    for (final f in secretForms(value)) {
      if (f.isNotEmpty) said = said.replaceAll(f, '[the value]');
    }
    return (did: null, error: logins.redact(said));
  }
  return (
    did: filledText(e, field, into: ref, submitted: submit).replaceFirst('pressed Enter', 'submitted'),
    error: null,
  );
}

Future<ToolOutput> _flutter(
  FlutterApp a,
  String action,
  Map<String, Object?> args,
  String root,
  bool vision,
  String Function(String text, String name) fit,
  String Function(String text)? scrub,
  LoginAccess? logins,
) async {
  String? str(String k) => (args[k] as String?)?.trim().isEmpty ?? true ? null : (args[k] as String).trim();
  double? at(String k) => (args[k] as num?)?.toDouble();
  final secretOk = (logins?.policy ?? LoginPolicy.open).secretFields;
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
        did = await a.type(ref, text, submit: args['submit'] == true, secretOk: secretOk);
      case 'fill_login':
        final f = await appFill(
          args,
          logins,
          (ref, v, submit) => a.type(ref, v, submit: submit, secretOk: true),
          control: a.control,
        );
        if (f.error case final why?) return ToolOutput('Error: $why', isError: true);
        did = f.did!;
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
      if (action != 'type' && action != 'fill_login') {
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
  LoginAccess? logins,
) async {
  String? str(String k) => (args[k] as String?)?.trim().isEmpty ?? true ? null : (args[k] as String).trim();
  final secretOk = (logins?.policy ?? LoginPolicy.open).secretFields;
  if (!await a.control.agentTurn()) return ToolOutput(userDrivingText(a.control.hold), isError: true);
  final gaveBack = a.control.takeGiveBack();
  var list = args['snapshot'] == true || gaveBack;
  try {
    final before = const {'tap', 'type', 'submit', 'long_press', 'fill_login'}.contains(action) ? await a.tree() : null;
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
        did = await a.type(ref, text, submit: args['submit'] == true, secretOk: secretOk);
      case 'fill_login':
        final f = await appFill(
          args,
          logins,
          (ref, v, submit) => a.type(ref, v, submit: submit, secretOk: true),
          control: a.control,
        );
        if (f.error case final why?) return ToolOutput('Error: $why', isError: true);
        did = f.did!;
      case 'submit':
        final ref = str('ref');
        if (ref == null) return const ToolOutput('Error: submit needs the ref of the text input.', isError: true);
        did = await a.type(ref, args['text'] as String? ?? '', submit: true, secretOk: secretOk);
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
  LoginAccess? logins,
) async {
  String? str(String k) => (args[k] as String?)?.trim().isEmpty ?? true ? null : (args[k] as String).trim();
  double? at(String k) => (args[k] as num?)?.toDouble();
  final secretOk = (logins?.policy ?? LoginPolicy.open).secretFields;
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
        const {
          'tap',
          'type',
          'submit',
          'key',
          'scroll',
          'back',
          'home',
          'long_press',
          'drag',
          'launch',
          'fill_login',
        }.contains(action)
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
        if (((args['count'] as num?) ?? 1) > 1 && a is! DesktopWindow) {
          return const ToolOutput('Error: count (double and triple clicks) is for desktop windows.', isError: true);
        }
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
        did = await a.type(ref, text, submit: args['submit'] == true, secretOk: secretOk);
      case 'fill_login':
        final f = await appFill(
          args,
          logins,
          (ref, v, submit) => a.type(ref, v, submit: submit, secretOk: true, hidden: true),
          control: a.control,
        );
        if (f.error case final why?) return ToolOutput('Error: $why', isError: true);
        did = f.did!;
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
      case 'key':
        final k = str('key') ?? str('text');
        if (k == null) return const ToolOutput('Error: key needs key ("Enter", "Escape", "cmd+s").', isError: true);
        if (keyTypesText(k) && !secretOk) {
          // Desktop trees mark focus; the simulator's and some apps' don't.
          final why = secretFocusRefusal(await a.tree(), focusKnown: a is DesktopWindow);
          if (why != null) return ToolOutput('Error: $why', isError: true);
        }
        did = await a.key(k);
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
      if (action != 'type' && action != 'fill_login') {
        await a.settle();
        await a.tree();
      }
      changed = a.changedSince(before);
      if (changed == null) {
        await Future<void>.delayed(const Duration(milliseconds: 700));
        await a.tree();
        changed = a.changedSince(before) ?? 'Nothing visible changed on screen.';
      }
      // A window with no accessibility elements can't say what changed: show it instead.
      if (a is DesktopWindow && !a.hasElements && changed == 'Nothing visible changed on screen.') {
        changed = 'This window has no accessibility elements to compare, so here is how it looks now.';
        shot = vision;
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
    final path =
        '${dir.path}/${a is DesktopWindow ? 'window' : (android ? 'android' : 'sim')}-${DateTime.now().millisecondsSinceEpoch}.png';
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
