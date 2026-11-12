// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import '../../../core/process/supervisor.dart';
import '../harness/everyai/browser_io.dart';
import '../shells/shell_log.dart';
import '../shells/shell_registry.dart';
import 'app_endpoints.dart';
import 'flutter_app_io.dart';
import 'android_device_io.dart';
import 'desktop_window_io.dart';
import 'ios_simulator_io.dart';
import 'react_native_io.dart';

/// An app running in one of a session's shells (or one the agent pointed at), and the shell it runs in.
final class SessionApp {
  const SessionApp(this.endpoint, {this.shell});
  final AppEndpoint endpoint;

  /// Where it runs; null for an app reached by its address only.
  final ShellEntry? shell;

  AppKind get kind => endpoint.kind;

  /// `Flutter app (bg_2: flutter run -d macos)`.
  String get label {
    if (kind == AppKind.ios) {
      final udid = endpoint.uri.path;
      return IosSimulators.booted.where((d) => d.udid == udid).firstOrNull?.name ?? 'iOS Simulator';
    }
    if (kind == AppKind.android) return AndroidDevices.driver(endpoint.uri.path).label;
    if (kind == AppKind.desktop) return DesktopWindows.driver(int.parse(endpoint.uri.path)).label;
    final where = shell == null ? endpoint.uri.toString() : '${shell!.id}: ${shell!.title}';
    return '${kind.label} app ($where)';
  }
}

/// The apps EveryAI can see into (Flutter, React Native, Electron), found in the output of the sessions' shells
/// (the agent's background commands and app_run's app), and one driver per app shared by the agent and the
/// Preview.
abstract final class AppSources {
  static final _scanned = <String, ({int logged, List<AppEndpoint> found})>{};
  static final _flutter = <Uri, FlutterApp>{};
  static final _rn = <Uri, ReactNativeApp>{};
  static final _electron = <Uri, HeadlessBrowser>{};

  /// Apps the agent reached by address, per session.
  static final _pointed = <String, List<AppEndpoint>>{};

  static final _changes = StreamController<void>.broadcast();

  /// Something may have started or stopped (a shell changed): the Preview looks again.
  static Stream<void> get changes => _changes.stream;

  /// The apps running in [sessions]' shells now (newest last), plus those the agent pointed at. A simulator counts
  /// when it is booted and a shell names it (or the session holds it), and no other session holds it.
  static List<SessionApp> running(Iterable<String> sessions) {
    final out = <SessionApp>[];
    final seen = <AppEndpoint>{};
    final ids = sessions.toList();
    void add(AppEndpoint ep, ShellEntry? shell) {
      final resolved = switch (ep.kind) {
        AppKind.ios => _bootedSimulator(ep, ids),
        AppKind.android => _readyAndroid(ep, ids),
        // A desktop app's process that has ended has no windows to drive.
        AppKind.desktop => _alive(int.tryParse(ep.uri.path) ?? -1) ? ep : null,
        _ => ep,
      };
      if (resolved != null && seen.add(resolved)) out.add(SessionApp(resolved, shell: shell));
    }

    for (final session in ids) {
      for (final e in ShellRegistry.instance.of(session)) {
        // A simulator the app was started on stays the session's after the build command ends.
        for (final found in _scan(e)) {
          if (e.running || found.kind == AppKind.ios || found.kind == AppKind.android) add(found, e);
        }
      }
      for (final p in _pointed[session] ?? const <AppEndpoint>[]) {
        add(p, null);
      }
      for (final udid in IosSimulators.heldBy(session)) {
        add(AppEndpoint(AppKind.ios, Uri.parse('simulator:$udid')), null);
      }
      for (final serial in AndroidDevices.holds.heldBy(session)) {
        add(AppEndpoint(AppKind.android, Uri.parse('android:$serial')), null);
      }
    }
    return out;
  }

  /// [ep] (an Android mention) as `android:<serial>` of a ready device no rival of [sessions] holds.
  /// Whether process [pid] still runs, from the process supervisor's last table (read again at most every 2 s, in
  /// the background; [changes] fires when an answer changes). A pid is the process first seen with it: one with
  /// another start time later is another program. Nothing is signalled. Before the first table, true.
  static bool _alive(int pid) {
    if (pid <= 0) return false;
    _refreshTable();
    final answer = _aliveIn(_table, pid);
    _answers[pid] = answer;
    return answer;
  }

  static bool _aliveIn(ProcessList? table, int pid) {
    if (table == null) return true;
    final row = table.rows[pid];
    if (row == null || row.zombie) return false;
    return _starts.putIfAbsent(pid, () => row.start) == row.start;
  }

  static ProcessList? _table;
  static var _tableAt = DateTime.fromMillisecondsSinceEpoch(0);
  static Future<void>? _reading;
  static final _starts = <int, String>{};
  static final _answers = <int, bool>{};

  static void _refreshTable() {
    if (_reading != null || DateTime.now().difference(_tableAt) < const Duration(seconds: 2)) return;
    _tableAt = DateTime.now();
    _reading = ProcessSupervisor.instance
        .scan()
        .then((scan) {
          switch (scan) {
            case ScanFailed(:final why):
              debugPrint('App sources: the process table could not be read ($why); desktop apps stay as they were.');
            case Listed(:final table):
              _table = table;
              final changed = _answers.entries.any((e) => _aliveIn(table, e.key) != e.value);
              _starts.removeWhere((p, _) => !table.rows.containsKey(p));
              if (changed) _changes.add(null);
          }
        })
        .whenComplete(() => _reading = null);
  }

  static AppEndpoint? _readyAndroid(AppEndpoint ep, List<String> sessions) {
    final ready = AndroidDevices.ready;
    String norm(String s) => s.toLowerCase().replaceAll(RegExp('[_ ]+'), ' ').trim();
    final want = Uri.decodeComponent(ep.uri.path);
    final d = ep.uri.scheme == 'android'
        ? ready.where((d) => d.serial == want).firstOrNull
        : ready.where((d) => norm(d.model) == norm(want) || norm(d.name) == norm(want)).firstOrNull;
    if (d == null) return null;
    final holder = AndroidDevices.holds.holder(d.serial);
    if (holder != null && !sessions.contains(holder)) return null;
    return AppEndpoint(AppKind.android, Uri.parse('android:${d.serial}'));
  }

  /// [ep] (a simulator mention) as `simulator:<udid>` of a booted simulator no other of [sessions]' rivals holds.
  static AppEndpoint? _bootedSimulator(AppEndpoint ep, List<String> sessions) {
    final booted = IosSimulators.booted;
    final want = Uri.decodeComponent(ep.uri.path).toLowerCase();
    final d = ep.uri.scheme == 'simulator'
        ? booted.where((b) => b.udid.toLowerCase() == want).firstOrNull
        : booted.where((b) => b.name.toLowerCase() == want).firstOrNull;
    if (d == null) return null;
    final holder = IosSimulators.holder(d.udid);
    if (holder != null && !sessions.contains(holder)) return null;
    return AppEndpoint(AppKind.ios, Uri.parse('simulator:${d.udid}'));
  }

  /// Notes that [session]'s agent pointed at the app at [endpoint] (started outside our shells).
  static void point(String session, AppEndpoint endpoint) {
    final list = _pointed.putIfAbsent(session, () => []);
    if (list.contains(endpoint)) return;
    list.add(endpoint);
    _changes.add(null);
  }

  /// The endpoints shell [e]'s output shows; read again only when it printed more.
  static List<AppEndpoint> _scan(ShellEntry e) {
    final was = _scanned[e.key];
    if (was != null && was.logged == e.logged) return was.found;
    final Uint8List bytes;
    try {
      bytes = e.logPath != null ? readShellLogSync(e.logPath!) : e.memory;
    } on Object {
      return was?.found ?? const [];
    }
    final found = detectAppEndpoints(_text(bytes));
    _scanned[e.key] = (logged: e.logged, found: found);
    if (was == null || !_same(was.found, found)) _changes.add(null);
    return found;
  }

  static final _files = <String, ({int length, List<AppEndpoint> found})>{};

  /// The apps a process we didn't start (an outside lead's background command) shows in [path], the file its
  /// output goes to, noted as session [session]'s.
  static void scanOutputFile(String session, String path) {
    final List<AppEndpoint> found;
    try {
      final f = File(path);
      final length = f.lengthSync();
      final was = _files[path];
      if (was != null && was.length == length) {
        found = was.found;
      } else {
        found = detectAppEndpoints(_text(f.readAsBytesSync()));
        _files[path] = (length: length, found: found);
      }
    } on FileSystemException {
      return;
    }
    for (final ep in found) {
      point(session, ep);
    }
  }

  /// The start (where servers print their address) and the newest megabyte (a restart prints a new one).
  static String _text(Uint8List bytes) {
    const head = 512 * 1024, tail = 1024 * 1024;
    return bytes.length <= head + tail
        ? utf8.decode(bytes, allowMalformed: true)
        : '${utf8.decode(bytes.sublist(0, head), allowMalformed: true)}\n'
              '${utf8.decode(bytes.sublist(bytes.length - tail), allowMalformed: true)}';
  }

  static bool _same(List<AppEndpoint> a, List<AppEndpoint> b) =>
      a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);

  /// The driver of Flutter app [uri] (one per app).
  static FlutterApp flutter(Uri uri) => _flutter.putIfAbsent(uri, () => FlutterApp(uri));

  /// The driver of the React Native app behind Metro at [uri].
  static ReactNativeApp reactNative(Uri uri) => _rn.putIfAbsent(uri, () => ReactNativeApp(uri));

  /// The window of the Electron app whose DevTools endpoint is [uri].
  static HeadlessBrowser electron(Uri uri) => _electron.putIfAbsent(uri, () => HeadlessBrowser.attached(uri));

  /// The driver of [app] if one was made (for the Preview, which doesn't connect on its own).
  static Object? driverOf(SessionApp app) => switch (app.kind) {
    AppKind.flutter => _flutter[app.endpoint.uri],
    AppKind.reactNative => _rn[app.endpoint.uri],
    AppKind.electron => _electron[app.endpoint.uri],
    AppKind.ios => IosSimulators.driver(app.endpoint.uri.path),
    AppKind.android => AndroidDevices.driver(app.endpoint.uri.path),
    AppKind.desktop => DesktopWindows.driver(int.parse(app.endpoint.uri.path)),
  };

  /// Disconnects from apps whose shells ended and forgets session [session]'s pointed apps (the session was
  /// removed). The apps themselves keep running until their shells stop.
  static Future<void> release(String session) async {
    _pointed.remove(session);
    IosSimulators.release(session);
    AndroidDevices.holds.release(session);
    DesktopWindows.holds.release(session);
    final live = {
      for (final s in ShellRegistry.instance.sessions)
        for (final a in running([s])) a.endpoint.uri,
      for (final l in _pointed.values)
        for (final p in l) p.uri,
    };
    await _dropExcept(live);
    _changes.add(null);
  }

  /// Disconnects from every app (the app quits).
  static Future<void> stopAll() async {
    _pointed.clear();
    await _dropExcept(const {});
  }

  static Future<void> _dropExcept(Set<Uri> keep) async {
    final gone = <Future<void>>[];
    for (final m in <Map<Uri, Object>>[_flutter, _rn, _electron]) {
      for (final uri in [...m.keys]) {
        if (keep.contains(uri)) continue;
        final d = m.remove(uri);
        gone.add(switch (d) {
          final FlutterApp f => f.close(),
          final ReactNativeApp r => r.close(),
          final HeadlessBrowser b => b.close(),
          _ => Future.value(),
        });
      }
    }
    await Future.wait(gone);
  }
}

/// The app at [url], an address the agent gave (a Flutter VM service, an Electron DevTools socket, or Metro), or
/// null when it isn't one of these on this machine.
AppEndpoint? endpointFromUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !uri.hasPort) return null;
  final host = uri.host.toLowerCase();
  final local = host == 'localhost' || (InternetAddress.tryParse(host)?.isLoopback ?? false);
  if (!local) return null;
  if (uri.path.contains('/devtools/browser/')) return AppEndpoint(AppKind.electron, uri);
  if (uri.path.contains('=/') || uri.path.endsWith('=') || uri.path.endsWith('/ws')) {
    final path = uri.path.endsWith('/ws') ? uri.path.substring(0, uri.path.length - 2) : uri.path;
    return AppEndpoint(AppKind.flutter, uri.replace(scheme: 'http', path: path.endsWith('/') ? path : '$path/'));
  }
  return AppEndpoint(AppKind.reactNative, uri.replace(scheme: 'http', path: ''));
}
