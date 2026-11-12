// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import 'app_view.dart';
import 'axe_install.dart';
import 'device_screen.dart';
import 'frames.dart';
import 'live_session.dart';
import 'supervised_stream_io.dart';
import '../../../core/process/supervisor.dart';
import '../git/git_service.dart';

/// `xcrun simctl args`, bounded: a run past [timeout] is killed (verified). [AppError] when it can't run or times out.
Future<Finished> _simctl(
  List<String> args, {
  Duration timeout = const Duration(seconds: 60),
  bool duringQuit = false,
}) async {
  final r = await ProcessSupervisor.instance.runBounded(
    'xcrun',
    ['simctl', ...args],
    timeout: timeout,
    owner: const ProbeOwner('simctl'),
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
    duringQuit: duringQuit,
    label: 'simctl ${args.take(2).join(' ')}',
  );
  return switch (r) {
    Finished() => r,
    TimedOut(:final kill) || Cancelled(:final kill) => throw AppError(
      'simctl ${args.first} took longer than ${timeout.inSeconds} s and was '
      '${kill is Ended ? 'stopped' : 'NOT closed ($kill)'}.',
    ),
    StartFailed(:final error) => throw AppError("simctl couldn't run: $error"),
    Refused(:final reason) => throw AppError("simctl wasn't run: $reason"),
  };
}

/// A simulator `xcrun simctl` knows.
final class SimDevice {
  const SimDevice({required this.udid, required this.name, required this.runtime, required this.booted});
  final String udid;
  final String name;

  /// `iOS 26.1`.
  final String runtime;
  final bool booted;

  @override
  String toString() => '$name ($runtime${booted ? ', booted' : ''}) $udid';
}

/// The iOS Simulators on this Mac, and which session holds each (one session drives a simulator at a time).
abstract final class IosSimulators {
  static List<SimDevice> _booted = const [];
  static DateTime _readAt = DateTime.fromMillisecondsSinceEpoch(0);
  static final holds = DeviceHolds();
  static final _drivers = <String, IosSimulator>{};

  /// The booted simulators as last read (see [refresh]).
  static List<SimDevice> get booted => _booted;

  /// Reads the simulators again (at most every [every]); the booted ones are kept for [booted].
  static Future<List<SimDevice>> refresh({Duration every = const Duration(seconds: 2)}) async {
    if (DateTime.now().difference(_readAt) < every) return _booted;
    _readAt = DateTime.now();
    _booted = [
      for (final d in await list())
        if (d.booted) d,
    ];
    return _booted;
  }

  /// Drops the simulators EveryAI booted that [all] (a full listing) shows not booted: EveryAI's watch of each ended
  /// there, so a later boot of that udid (by the user) is never EveryAI's to shut down.
  static void _watch(List<SimDevice> all) {
    if (_ours.isEmpty || all.isEmpty) return;
    final up = {
      for (final d in all)
        if (d.booted) d.udid,
    };
    final gone = _ours.where((u) => !up.contains(u)).toList();
    for (final u in gone) {
      _ours.remove(u);
      debugPrint('Simulator $u, booted by EveryAI, was shut down elsewhere: no longer EveryAI\'s.');
    }
    if (gone.isNotEmpty) unawaited(_save());
  }

  /// Every available iPhone and iPad simulator.
  static Future<List<SimDevice>> list() async {
    if (!Platform.isMacOS) return const [];
    final Finished r;
    try {
      r = await _simctl(const ['list', 'devices', 'available', '-j'], timeout: const Duration(seconds: 30));
    } on AppError catch (e) {
      debugPrint('Simulators could not be listed: ${e.message}');
      return const [];
    }
    if (r.code != 0) return const [];
    final all = parseSimctlDevices(r.stdout);
    _watch(all);
    return all;
  }

  /// The simulator [device] names among [all]: a udid, or a name, with its runtime ("iPhone 16e (iOS 18.6)") when
  /// the name is on several runtimes and none of them is booted.
  @visibleForTesting
  static SimDevice pickSimulator(List<SimDevice> all, String device) {
    final m = RegExp(r'^(.*?)\s*\((i(?:Pad)?OS [\d.]+)\)$').firstMatch(device.trim());
    final name = (m?.group(1) ?? device).trim().toLowerCase();
    final runtime = m?.group(2)?.toLowerCase();
    final named = [
      for (final x in all)
        if (x.name.toLowerCase() == name && (runtime == null || x.runtime.toLowerCase() == runtime)) x,
    ];
    final d =
        all.where((x) => x.udid == device).firstOrNull ??
        (named.length == 1 ? named.first : named.where((x) => x.booted).firstOrNull);
    if (d == null && named.length > 1) {
      throw AppError(
        '"$device" is on ${named.map((x) => x.runtime).join(' and ')}: pass "${named.first.name} '
        '(${named.first.runtime})" or a udid.',
      );
    }
    if (d == null) {
      throw AppError('No simulator called "$device". Simulators: ${all.map((x) => x.name).toSet().join(', ')}.');
    }
    return d;
  }

  /// Boots [device] (a name or udid) without opening Simulator.app, and waits until it is up. A simulator EveryAI
  /// boots is EveryAI's for [shutdownBooted] while every listing since shows it booted; one not up within 3 minutes
  /// is shut down again.
  static Future<SimDevice> boot(String device) async {
    final d = pickSimulator(await list(), device);
    if (!d.booted) {
      final r = await _simctl(['boot', d.udid]);
      if (r.code != 0 && !r.stderr.contains('current state: Booted')) {
        throw AppError("Couldn't boot ${d.name}: ${r.stderr.trim()}");
      }
      if (r.code == 0) await _remember(d.udid, add: true);
      _readAt = DateTime.fromMillisecondsSinceEpoch(0);
      try {
        await _simctl(['bootstatus', d.udid, '-b'], timeout: const Duration(minutes: 3));
      } on AppError catch (e) {
        final shut = await _shutdown(d.udid);
        throw AppError('${d.name} did not finish booting: ${e.message} ${shut ?? 'It was shut down again.'}');
      }
    }
    _readAt = DateTime.fromMillisecondsSinceEpoch(0);
    await refresh();
    return SimDevice(udid: d.udid, name: d.name, runtime: d.runtime, booted: true);
  }

  /// The simulators this run booted and has seen booted in every listing since ([_watch]). In memory: a new run
  /// never inherits them.
  static final _ours = <String>{};

  /// Whether [_forgetLastRun] ran this run.
  static var _lastRunForgotten = false;

  /// The simulators EveryAI booted in this run and still owns.
  static Future<Set<String>> bootedByEveryAI() async {
    await _forgetLastRun();
    return {..._ours};
  }

  /// App data `simulators-booted.json`: this run's [_ours], written so a crash leaves a record of what it booted.
  static Future<File> _file() async => File('${await GitService.dataDir()}/simulators-booted.json');

  /// Entries a previous run left (it crashed, or a shutdown at its quit failed). A dead run's watch can't vouch that
  /// the simulator still is the one it booted (the user may have shut it down and booted it again), so they are
  /// dropped without shutting anything down: the user's simulators are never touched. Once per run, at first use.
  static Future<void> _forgetLastRun() async {
    if (_lastRunForgotten) return;
    _lastRunForgotten = true;
    try {
      final f = await _file();
      if (!f.existsSync()) return;
      final j = jsonDecode(await f.readAsString());
      final left = [
        if (j is List)
          for (final x in j)
            if (x is String && !_ours.contains(x)) x,
      ];
      if (left.isNotEmpty) {
        debugPrint(
          'Simulators a previous run booted (${left.join(', ')}) are left as they are: '
          "that run ended without shutting them down, and EveryAI can't tell they are still its own.",
        );
      }
      await _save();
    } on Object catch (e) {
      debugPrint('The list of simulators a previous run booted could not be read: $e');
    }
  }

  static Future<void> _remember(String udid, {required bool add}) async {
    await _forgetLastRun();
    if (add ? !_ours.add(udid) : !_ours.remove(udid)) return;
    await _save();
  }

  static Future<void> _save() async {
    try {
      final f = await _file();
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode([..._ours]));
    } on Object catch (e) {
      debugPrint('The list of simulators EveryAI booted could not be written: $e');
    }
  }

  /// `simctl shutdown` [udid], then a check that it is no longer booted: null when it is shut down, else why not.
  static Future<String?> _shutdown(String udid) async {
    try {
      final r = await _simctl(['shutdown', udid], duringQuit: true);
      if (r.code != 0 && !r.stderr.contains('current state: Shutdown')) {
        return 'simctl shutdown failed: ${r.stderr.trim()}';
      }
    } on AppError catch (e) {
      return e.message;
    }
    final Finished r;
    try {
      r = await _simctl(const ['list', 'devices', '-j'], timeout: const Duration(seconds: 30), duringQuit: true);
    } on AppError catch (e) {
      return "Couldn't check it shut down: ${e.message}";
    }
    if (r.code != 0) return "Couldn't check it shut down (simctl list exit ${r.code}).";
    if (parseSimctlDevices(r.stdout).any((x) => x.udid == udid && x.booted)) return 'It is still booted.';
    await _remember(udid, add: false);
    _readAt = DateTime.fromMillisecondsSinceEpoch(0);
    return null;
  }

  /// Shuts down every simulator EveryAI booted (verified: no longer listed as booted), or those of [only]: phase 3
  /// calls this at session delete and quit. The user's own simulators are never touched. [Ended] when all are shut
  /// down; a [Survived] (no pids: simulators aren't our processes) naming those still booted.
  static Future<KillOutcome> shutdownBooted({Iterable<String>? only}) async {
    await _forgetLastRun();
    // A fresh listing first: one shut down (and maybe booted again) by someone else since is no longer ours.
    if (_ours.isNotEmpty) {
      try {
        final r = await _simctl(
          const ['list', 'devices', '-j'],
          timeout: const Duration(seconds: 30),
          duringQuit: true,
        );
        if (r.code == 0) _watch(parseSimctlDevices(r.stdout));
      } on AppError catch (e) {
        debugPrint('Simulators could not be listed before shutting down EveryAI\'s: ${e.message}');
      }
    }
    final ours = [..._ours];
    final targets = only == null
        ? ours
        : [
            for (final u in only)
              if (ours.contains(u)) u,
          ];
    final problems = <String>[];
    for (final udid in targets) {
      final why = await _shutdown(udid);
      if (why != null) problems.add('$udid: $why');
    }
    if (problems.isEmpty) return const Ended([]);
    final reason = 'simulators not shut down: ${problems.join('; ')}';
    debugPrint('NOT CLOSED: $reason');
    return Survived(const [], reason);
  }

  /// The session holding simulator [udid], if any.
  static String? holder(String udid) => holds.holder(udid);

  /// Lets [session] drive [udid]; the holding session's id when another one holds it.
  static String? claim(String udid, String session) => holds.claim(udid, session);

  /// The simulators [session] holds.
  static Iterable<String> heldBy(String session) => holds.heldBy(session);

  /// Gives back what [session] holds (the session was removed or stopped).
  static void release(String session) => holds.release(session);

  /// The driver of simulator [udid] (one per simulator).
  static IosSimulator driver(String udid) => _drivers.putIfAbsent(udid, () => IosSimulator(udid));
}

/// [json] from `xcrun simctl list devices -j` as iPhone and iPad simulators.
List<SimDevice> parseSimctlDevices(String json) {
  final out = <SimDevice>[];
  final Object? data;
  try {
    data = jsonDecode(json);
  } on FormatException {
    return out;
  }
  final devices = data is Map ? data['devices'] : null;
  if (devices is! Map) return out;
  for (final e in devices.entries) {
    // com.apple.CoreSimulator.SimRuntime.iOS-26-1 → iOS 26.1
    final m = RegExp(r'SimRuntime\.([A-Za-z]+)-([\d-]+)$').firstMatch('${e.key}');
    if (m == null || !const {'iOS', 'iPadOS'}.contains(m.group(1))) continue;
    final runtime = '${m.group(1)} ${m.group(2)!.replaceAll('-', '.')}';
    for (final d in (e.value as List?) ?? const []) {
      if (d is! Map || d['isAvailable'] == false) continue;
      out.add(SimDevice(udid: '${d['udid']}', name: '${d['name']}', runtime: runtime, booted: d['state'] == 'Booted'));
    }
  }
  return out;
}

/// A booted iOS Simulator, driven through AXe: its accessibility tree (points), taps, typing and gestures as
/// touches, and pictures of its screen. Nothing needs Simulator.app or the Screen Recording permission.
final class IosSimulator implements DeviceScreen {
  IosSimulator(this.udid);

  final String udid;

  /// Who drives it, and the agent's actions for the Preview.
  @override
  final control = LiveControl();
  @override
  final frames = FrameBook();

  /// The screen in points, as of the last tree.
  @override
  var width = 0.0;
  @override
  var height = 0.0;
  List<AppNode> _last = const [];
  var _nodes = <String, AppNode>{};
  var _treeAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// The tree, read again unless it was read just now (the tool reads one before each action).
  Future<List<AppNode>> _fresh() async =>
      DateTime.now().difference(_treeAt) < const Duration(milliseconds: 1500) ? _last : tree();

  /// Identity (type, label, id, occurrence) to ref: a ref names one element while it is there.
  final _refs = <String, String>{};
  var _next = 0;

  @override
  String get label => IosSimulators.booted.where((d) => d.udid == udid).firstOrNull?.name ?? 'iOS Simulator';
  @override
  String get installs => 'a built .app';
  @override
  String get launches => 'bundle id';

  @override
  Future<List<String>?> logs() async => null;

  @override
  ViewGeometry get geometry => ViewGeometry(width.round(), height.round());
  List<AppNode> get lastTree => _last;

  Future<String> _axe(List<String> args, {String? stdin}) async {
    final exe = await ensureAxe();
    final r = await ProcessSupervisor.instance.runBounded(
      exe,
      [...args, '--udid', udid],
      timeout: const Duration(seconds: 60),
      owner: const ProbeOwner('axe'),
      stdin: stdin,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
      label: 'axe ${args.first}',
    );
    switch (r) {
      case Finished(:final code, :final stdout, :final stderr):
        if (code != 0) {
          final why = stderr.trim().split('\n').where((l) => l.trim().isNotEmpty).lastOrNull ?? 'exit $code';
          throw AppError('The simulator action failed: ${why.replaceFirst(RegExp(r'^Error:\s*'), '')}');
        }
        return stdout;
      case TimedOut(:final kill) || Cancelled(:final kill):
        throw AppError(
          'The simulator action took over 60 s and was ${kill is Ended ? 'stopped' : 'NOT closed ($kill)'}.',
        );
      case StartFailed(:final error):
        throw AppError("The simulator action couldn't start: $error");
      case Refused(:final reason):
        throw AppError("The simulator action couldn't start: $reason");
    }
  }

  /// The screen's element list now.
  @override
  Future<List<AppNode>> tree() async {
    final raw = await _axe(['describe-ui']);
    final Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException {
      throw const AppError("The simulator's accessibility tree couldn't be read.");
    }
    final flat = flattenAxTree(json);
    width = flat.width > 0 ? flat.width : width;
    height = flat.height > 0 ? flat.height : height;
    final seen = <String, int>{};
    final nodes = <AppNode>[];
    for (final n in flat.nodes) {
      if (n.ref.isEmpty) {
        nodes.add(n);
        continue;
      }
      // n.ref holds the identity here; same-looking elements count up.
      final count = seen[n.ref] = (seen[n.ref] ?? 0) + 1;
      final identity = '${n.ref}\u0001$count';
      final ref = _refs[identity] ??= 'i${++_next}';
      nodes.add(n.withRef(ref));
    }
    _last = nodes;
    _nodes = {for (final n in nodes) n.ref: n};
    _treeAt = DateTime.now();
    return nodes;
  }

  @override
  Future<String> snapshot() async {
    final nodes = await tree();
    return appTreeText('$label (screen ${width.round()}×${height.round()} pt)', nodes, width: width, height: height);
  }

  AppNode _node(String ref) {
    final n = _nodes[ref];
    if (n == null) throw AppError('No element $ref on the simulator now: take a new snapshot.');
    if (!n.placed) throw AppError('$ref has no place on screen.');
    return n;
  }

  static String _n(double v) => v.toStringAsFixed(1);

  @override
  Future<String> tap(String ref) async {
    await _fresh();
    final n = _node(ref);
    _report('click', n, 'Tapping');
    await _axe(['tap', '-x', _n(n.centreX), '-y', _n(n.centreY)]);
    return 'Tapped $ref ${n.role}${n.name.isEmpty ? '' : ' "${n.name}"'}.';
  }

  @override
  Future<String> tapAt(double x, double y) async {
    final hit = hitNode(await _fresh(), x, y);
    control.report(LiveActivity('click', x: x, y: y, caption: 'Tapping'));
    await _axe(['tap', '-x', _n(x), '-y', _n(y)]);
    final on = hit == null
        ? ''
        : ' on ${hit.ref.isEmpty ? '' : '${hit.ref} '}${hit.role}${hit.name.isEmpty ? '' : ' "${hit.name}"'}';
    return 'Tapped at (${x.round()}, ${y.round()})$on.';
  }

  @override
  Future<String> longPress(String ref) async {
    await _fresh();
    final n = _node(ref);
    _report('click', n, 'Long-pressing');
    await _axe(['touch', '-x', _n(n.centreX), '-y', _n(n.centreY), '--down', '--up', '--delay', '1.0']);
    return 'Long-pressed $ref ${n.role}${n.name.isEmpty ? '' : ' "${n.name}"'}.';
  }

  /// Types [text] into field [ref], replacing what it held (select all, then the keys), and checks it.
  @override
  Future<String> type(
    String ref,
    String text, {
    bool submit = false,
    bool secretOk = false,
    bool hidden = false,
  }) async {
    await _fresh();
    final n = _node(ref);
    if (n.secret && !secretOk) {
      throw AppError(
        '$ref is a password field, and the user keeps those to saved logins: fill it with fill_login (logins lists '
        'them), or ask the user to type it.',
      );
    }
    if (n.role != 'textbox') throw AppError('$ref is a ${n.role}, not a text field.');
    _report('type', n, 'Typing into');
    if (!n.state.contains('focused')) {
      await _axe(['tap', '-x', _n(n.centreX), '-y', _n(n.centreY)]);
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    // ⌘A (HID: left GUI 227, a 4) selects what the field holds; typing replaces it, Delete (42) clears it.
    await _axe(['key-combo', '--modifiers', '227', '--key', '4']);
    if (text.isEmpty) {
      await _axe(['key', '42']);
    } else {
      await _axe(['type', '--stdin'], stdin: text);
    }
    if (submit) await _axe(['key', '40']);
    await settle();
    await tree();
    final now = _last.where((x) => x.role == 'textbox' && x.ref == ref).firstOrNull;
    final held = now?.value ?? '';
    if (now != null && !n.secret && held != text && held == (n.value ?? '')) {
      throw AppError("Typing into $ref didn't change it: it still holds \"$held\".");
    }
    // A saved login's value is never echoed, not even as the field holds it (a cut-off or changed password).
    final shown = now == null || held == text || hidden ? '' : ' (the field shows "$held": iOS or the app changed it)';
    return 'Typed into $ref${n.name.isEmpty ? '' : ' "${n.name}"'}$shown${submit ? ' and pressed Return' : ''}.';
  }

  static const _hid = <String, int>{
    'enter': 40,
    'return': 40,
    'escape': 41,
    'esc': 41,
    'backspace': 42,
    'tab': 43,
    'space': 44,
    'right': 79,
    'left': 80,
    'down': 81,
    'up': 82,
    'arrowright': 79,
    'arrowleft': 80,
    'arrowdown': 81,
    'arrowup': 82,
    'delete': 76,
    'home': 74,
    'end': 77,
    'pageup': 75,
    'pagedown': 78,
  };
  static const _hidMods = <String, int>{
    'ctrl': 224,
    'control': 224,
    'shift': 225,
    'alt': 226,
    'option': 226,
    'cmd': 227,
    'command': 227,
  };

  static int? _hidOf(String k) {
    if (_hid[k] case final c?) return c;
    if (k.length == 1) {
      final u = k.codeUnitAt(0);
      if (u >= 0x61 && u <= 0x7a) return 4 + u - 0x61;
      if (u >= 0x31 && u <= 0x39) return 30 + u - 0x31;
      if (u == 0x30) return 39;
    }
    return null;
  }

  @override
  Future<String> key(String combo) async {
    final (:mods, :key) = splitKeyCombo(combo);
    final code = _hidOf(key);
    control.report(LiveActivity('type', caption: 'Pressing $combo'));
    if (code == null || (mods.isEmpty && key.length == 1)) {
      if (mods.isNotEmpty) throw AppError('Unknown key "$key" in "$combo".');
      await _axe(['type', '--stdin'], stdin: combo);
      return 'Typed "$combo".';
    }
    if (mods.isEmpty) {
      await _axe(['key', '$code']);
    } else {
      final m = [for (final x in mods) _hidMods[x] ?? (throw AppError('Unknown modifier "$x" in "$combo".'))];
      await _axe(['key-combo', '--modifiers', m.join(','), '--key', '$code']);
    }
    return 'Pressed $combo.';
  }

  /// Presses Return (the keyboard's action key).
  @override
  Future<String> submit() async {
    await _axe(['key', '40']);
    return 'Pressed Return.';
  }

  /// Scrolls by [dy] points (positive: down, so the finger moves up) over [ref] or the screen's middle.
  @override
  Future<String> scroll(double dy, {String? ref}) async {
    await _fresh();
    var x = width / 2, y = height / 2;
    if (ref != null) {
      final n = _node(ref);
      x = n.centreX;
      y = n.centreY;
    }
    final half = (dy.abs() / 2).clamp(20.0, height * 0.4);
    final from = dy >= 0 ? y + half : y - half, to = dy >= 0 ? y - half : y + half;
    control.report(LiveActivity('scroll', x: x, y: y, caption: 'Scrolling'));
    await _axe([
      'swipe',
      '--start-x',
      _n(x),
      '--start-y',
      _n(from.clamp(4, height - 4)),
      '--end-x',
      _n(x),
      '--end-y',
      _n(to.clamp(4, height - 4)),
      '--duration',
      '0.4',
    ]);
    return 'Scrolled ${dy >= 0 ? 'down' : 'up'} about ${dy.abs().round()} pt.';
  }

  @override
  Future<String> drag(double x, double y, double toX, double toY) async {
    control.report(LiveActivity('click', x: x, y: y, caption: 'Dragging'));
    await _axe([
      'swipe',
      '--start-x',
      _n(x),
      '--start-y',
      _n(y),
      '--end-x',
      _n(toX),
      '--end-y',
      _n(toY),
      '--duration',
      '0.8',
    ]);
    return 'Dragged from (${x.round()}, ${y.round()}) to (${toX.round()}, ${toY.round()}).';
  }

  /// iOS has no system back button: the navigation bar's own back button when there is one (top left), else a
  /// swipe in from the left edge (what navigation stacks take as back).
  @override
  Future<String> back() async {
    final nodes = await _fresh();
    final bar = nodes
        .where((n) => n.role == 'button' && n.placed && n.top! < 130 && n.left! < 40 && n.right! < width * 0.5)
        .firstOrNull;
    if (bar != null) {
      _report('click', bar, 'Going back');
      await _axe(['tap', '-x', _n(bar.centreX), '-y', _n(bar.centreY)]);
      return 'Tapped the back button${bar.name.isEmpty ? '' : ' "${bar.name}"'}.';
    }
    control.report(const LiveActivity('scroll', caption: 'Swiping back'));
    final w = width > 0 ? width : 390, h = height > 0 ? height : 844;
    await _axe([
      'swipe',
      '--start-x',
      '1',
      '--start-y',
      _n(h / 2),
      '--end-x',
      _n(w * 0.8),
      '--end-y',
      _n(h / 2),
      '--duration',
      '0.5',
    ]);
    return 'Swiped in from the left edge (back).';
  }

  /// Installs the `.app` bundle at [path] on the simulator.
  @override
  Future<String> install(String path) async {
    final r = await _simctl(['install', udid, path], timeout: const Duration(minutes: 5));
    if (r.code != 0) throw AppError("Couldn't install $path: ${r.stderr.trim()}");
    return 'Installed $path.';
  }

  /// Launches the app with [bundle] id (terminating a running copy first), so it starts fresh.
  @override
  Future<String> launch(String app) async {
    final bundle = app;
    final there = await _simctl(['get_app_container', udid, bundle]);
    if (there.code != 0) {
      throw AppError(
        '$bundle is not installed on this simulator: build it for the simulator and install the .app first.',
      );
    }
    control.report(LiveActivity('look', caption: 'Launching $bundle'));
    final r = await _simctl(['launch', '--terminate-running-process', udid, bundle]);
    if (r.code != 0) throw AppError("Couldn't launch $bundle: ${r.stderr.trim()}");
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    return 'Launched $bundle.';
  }

  @override
  Future<String> home() async {
    control.report(const LiveActivity('look', caption: 'Going home'));
    await _axe(['button', 'home']);
    return 'Pressed Home.';
  }

  /// Gives the app time to answer a touch (the simulator reports no frames).
  @override
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 500));

  @override
  String? changedSince(List<AppNode> before) => appTreeChange(before, _last, width: width, height: height);

  /// A picture of [region] (points; null: the whole screen), sized for the model, and its frame.
  @override
  Future<(List<int>, AgentFrame)> frameShot({ViewRect? region}) async {
    await tree();
    final png = await _screenshot();
    final r = region ?? (left: 0.0, top: 0.0, width: width, height: height);
    final size = agentImageSize(r.width, r.height, scale: region == null ? 1.0 : 2.0);
    final f = frames.record(imageWidth: size.width, imageHeight: size.height, geometry: geometry, region: region);
    final out = await cropForModel(png, width, r, size);
    return (out, f);
  }

  Future<Uint8List> _screenshot() async {
    final dir = Directory.systemTemp.createTempSync('everyai-sim');
    try {
      await _axe(['screenshot', '--output', '${dir.path}/s.png']);
      return File('${dir.path}/s.png').readAsBytesSync();
    } finally {
      dir.deleteSync(recursive: true);
    }
  }

  /// The screen as JPEG frames for the Preview ([fps], at [scale] of its pixels), while listened to: `axe
  /// stream-video`, a supervised child stopped (verified) when the listener cancels, even mid-start.
  Stream<Uint8List> stream({int fps = 10, double scale = 0.5}) => supervisedFrames(
    'Simulator stream ($udid)',
    () async => ProcessSupervisor.instance.spawn(
      SpawnSpec(
        owner: const AppOwner(),
        kind: ProcessKind.stream,
        exe: await ensureAxe(),
        args: [
          'stream-video',
          '--udid',
          udid,
          '--format',
          'mjpeg',
          '--fps',
          '$fps',
          '--quality',
          '70',
          '--scale',
          '$scale',
        ],
        label: 'Simulator stream ($udid)',
        detail: 'udid $udid',
      ),
    ),
    MjpegFrames(),
  );

  /// The user's tap in the Preview, in points.
  Future<void> userTap(double x, double y) => _axe(['tap', '-x', _n(x), '-y', _n(y)]);

  /// The user's wheel in the Preview: a short swipe.
  Future<void> userScroll(double x, double y, double dy) {
    final half = (dy.abs() / 2).clamp(20.0, height * 0.4);
    return _axe([
      'swipe',
      '--start-x',
      _n(x),
      '--start-y',
      _n(dy >= 0 ? y + half : y - half),
      '--end-x',
      _n(x),
      '--end-y',
      _n(dy >= 0 ? y - half : y + half),
      '--duration',
      '0.25',
    ]);
  }

  void _report(String kind, AppNode n, String verb) => control.report(
    LiveActivity(
      kind,
      x: n.placed ? n.centreX : null,
      y: n.placed ? n.centreY : null,
      caption: '$verb ${n.name.isEmpty ? n.role : n.name}',
    ),
  );
}

/// AXe's `describe-ui` JSON as nodes in reading order, with the screen's size in points. A node's ref holds its
/// identity (type, label, id) for [IosSimulator] to turn into a ref; plain text has none.
({List<AppNode> nodes, double width, double height}) flattenAxTree(Object? json) {
  final nodes = <AppNode>[];
  var width = 0.0, height = 0.0;
  void visit(Object? n) {
    if (n is! Map) return;
    final type = '${n['type'] ?? ''}';
    final frame = n['frame'];
    double v(String k) => frame is Map ? ((frame[k] as num?)?.toDouble() ?? 0) : 0;
    final x = v('x'), y = v('y'), w = v('width'), h = v('height');
    if (type == 'Application' && w > 0) {
      width = w;
      height = h;
    }
    final label = '${n['AXLabel'] ?? ''}'.trim(), value = '${n['AXValue'] ?? ''}'.trim();
    final id = '${n['AXUniqueId'] ?? ''}'.trim();
    final node = _axNode(type, label, value, id, n['enabled'] != false, x, y, w, h);
    if (node != null) nodes.add(node);
    for (final c in (n['children'] as List?) ?? const []) {
      visit(c);
    }
  }

  if (json is List) {
    json.forEach(visit);
  } else {
    visit(json);
  }
  // The same element listed twice (AXe repeats some).
  final seen = <String>{};
  final unique = [
    for (final n in nodes)
      if (seen.add('${n.ref}|${n.role}|${n.name}|${n.value}|${n.left}|${n.top}')) n,
  ];
  final cleaned = _withoutNoise(unique, height);
  int row(AppNode n) => (n.top! / 8).round();
  cleaned.sort((a, b) => row(a) != row(b) ? row(a) - row(b) : a.left!.compareTo(b.left!));
  return (nodes: cleaned, width: width, height: height);
}

const _keyNames = {
  'shift',
  'delete',
  'numbers',
  'space',
  'return',
  'search',
  'emoji',
  'dictate',
  'go',
  'done',
  'send',
  'next keyboard',
  'more',
  'next',
  'join',
};

/// [nodes] without what only repeats or clutters: a label's own text under its button, and the keyboard's keys (one
/// line says the keyboard is up instead, when it is on screen).
List<AppNode> _withoutNoise(List<AppNode> nodes, double height) {
  bool inside(AppNode t, AppNode c) =>
      t.centreX >= c.left! && t.centreX <= c.right! && t.centreY >= c.top! && t.centreY <= c.bottom!;
  final controls = [
    for (final n in nodes)
      if (n.ref.isNotEmpty && n.name.isNotEmpty && n.role != 'text' && n.role != 'img') n,
  ];
  bool isKey(AppNode n) => n.role == 'button' && (n.name.runes.length == 1 || _keyNames.contains(n.name.toLowerCase()));
  final keys = nodes.where(isKey).toList();
  final keyboard = keys.where((k) => k.name.runes.length == 1).length >= 15;
  final keyboardUp = keyboard && keys.any((k) => height <= 0 || k.top! < height);
  // The same text twice in a row (a cell's label and its text), and the disclosure chevrons cells draw.
  final kept = <AppNode>[];
  for (final n in nodes) {
    final prev = kept.lastOrNull;
    if (prev != null && n.role == 'text' && prev.role == 'text' && n.name == prev.name) continue;
    if (n.role == 'button' && n.name == 'chevron' && n.state.contains('disabled')) continue;
    kept.add(n);
  }
  return [
    for (final n in kept)
      if (!(keyboard && isKey(n)) &&
          !(n.role == 'text' && controls.any((c) => inside(n, c) && c.name.contains(n.name))))
        n,
    if (keyboardUp)
      AppNode(
        ref: '',
        role: 'text',
        name: '(the on-screen keyboard is up)',
        left: 0,
        top: height - 1,
        right: 1,
        bottom: height,
      ),
  ];
}

AppNode? _axNode(
  String type,
  String label,
  String value,
  String id,
  bool enabled,
  double x,
  double y,
  double w,
  double h,
) {
  if (w <= 0 || h <= 0) return null;
  final role = switch (type) {
    'Button' || 'Cell' || 'PopUpButton' || 'MenuItem' || 'DisclosureTriangle' => 'button',
    'Link' => 'link',
    'TextField' || 'TextView' || 'SearchField' || 'SecureTextField' || 'TextArea' => 'textbox',
    'Switch' || 'Toggle' => 'switch',
    'CheckBox' => 'checkbox',
    'RadioButton' => 'radio',
    'Slider' || 'Stepper' => 'slider',
    'Heading' => 'heading',
    'Image' => 'img',
    'Tab' || 'TabBarButton' => 'tab',
    'Picker' || 'PickerWheel' || 'ComboBox' => 'combobox',
    'StaticText' => 'text',
    'Application' => null,
    _ => label.isNotEmpty || value.isNotEmpty ? 'text' : null,
  };
  if (role == null) return null;
  if ((role == 'img' || role == 'text') && label.isEmpty && value.isEmpty) return null;
  final secret = type == 'SecureTextField';
  final toggles = role == 'switch' || role == 'checkbox' || role == 'radio';
  final state = [
    if (toggles) value == '1' || value.toLowerCase() == 'on' ? 'checked' : 'unchecked',
    if (!enabled) 'disabled',
  ];
  // Text gets a ref too: a table row's text is often the only element to tap (its cell has no label).
  final acting = role != 'img' || label.isNotEmpty;
  return AppNode(
    // The identity, made into a ref by the caller.
    ref: acting ? '$type|$label|$id' : '',
    role: role,
    name: role == 'text' && label.isEmpty ? value : label,
    value: toggles || role == 'text' || secret || value.isEmpty ? null : value,
    state: state,
    left: x,
    top: y,
    right: x + w,
    bottom: y + h,
    secret: secret,
  );
}

/// Splits an MJPEG stream (`multipart/x-mixed-replace`, as `axe stream-video` writes it) into JPEG frames, by each
/// part's Content-Length (a JPEG's own end marker can appear early, in its EXIF thumbnail).
final class MjpegFrames extends StreamTransformerBase<List<int>, Uint8List> {
  static final _length = RegExp(r'Content-Length:\s*(\d+)\r?\n\r?\n', caseSensitive: false);

  @override
  Stream<Uint8List> bind(Stream<List<int>> stream) async* {
    var data = Uint8List(0);
    await for (final chunk in stream) {
      data = Uint8List.fromList([...data, ...chunk]);
      for (;;) {
        // Headers are ASCII; latin1 keeps byte offsets.
        final head = latin1.decode(Uint8List.sublistView(data, 0, data.length < 4096 ? data.length : 4096));
        final m = _length.firstMatch(head);
        if (m == null) {
          if (data.length > 4096) data = Uint8List.sublistView(data, data.length - 1024);
          break;
        }
        final size = int.parse(m.group(1)!);
        final start = m.end;
        if (size > 32 * 1024 * 1024) {
          data = Uint8List.sublistView(data, start);
          continue;
        }
        if (data.length < start + size) break;
        yield Uint8List.fromList(Uint8List.sublistView(data, start, start + size));
        data = Uint8List.sublistView(data, start + size);
      }
    }
  }
}
