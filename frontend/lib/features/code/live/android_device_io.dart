// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:xml/xml.dart';

import 'adb_io.dart';
import 'app_view.dart';
import 'device_screen.dart';
import 'frames.dart';
import 'live_session.dart';
import 'scrcpy_io.dart';

/// A device adb sees: an emulator (`emulator-5554`) or a phone.
final class AdbDevice {
  const AdbDevice({required this.serial, required this.model, required this.state, this.avd});
  final String serial;

  /// `sdk_gphone64_arm64`, `Pixel_8`.
  final String model;

  /// `device`, `offline`, `unauthorized`.
  final String state;

  /// The emulator's virtual device name, when it is one.
  final String? avd;

  bool get ready => state == 'device';
  bool get emulator => serial.startsWith('emulator-');

  /// How the user knows it: the AVD's name with spaces, else the model.
  String get name => (avd ?? model).replaceAll('_', ' ');
}

/// [text] from `adb devices -l` as devices.
List<AdbDevice> parseAdbDevices(String text) => [
  for (final line in text.split('\n').skip(1))
    if (RegExp(r'^(\S+)\s+(device|offline|unauthorized|authorizing|recovery|sideload)\b(.*)$').firstMatch(line.trim())
        case final m?)
      AdbDevice(
        serial: m.group(1)!,
        state: m.group(2)!,
        model: RegExp(r'model:(\S+)').firstMatch(m.group(3)!)?.group(1) ?? m.group(1)!,
      ),
];

/// Android devices and emulators on this computer, and which session holds each.
abstract final class AndroidDevices {
  static List<AdbDevice> _ready = const [];
  static DateTime _readAt = DateTime.fromMillisecondsSinceEpoch(0);
  static final holds = DeviceHolds();
  static final _drivers = <String, AndroidDevice>{};
  static final _avds = <String, String>{};

  /// The devices ready to drive, as last read (see [refresh]).
  static List<AdbDevice> get ready => _ready;

  @visibleForTesting
  static set ready(List<AdbDevice> devices) => _ready = devices;

  static Future<List<AdbDevice>> refresh({Duration every = const Duration(seconds: 3)}) async {
    if (AndroidSdk.adb == null || DateTime.now().difference(_readAt) < every) return _ready;
    _readAt = DateTime.now();
    try {
      _ready = [
        for (final d in await list())
          if (d.ready) d,
      ];
    } on Object {
      _ready = const [];
    }
    return _ready;
  }

  /// The devices adb sees (emulators named by their virtual device).
  static Future<List<AdbDevice>> list() async {
    final out = <AdbDevice>[];
    for (final d in parseAdbDevices(await AndroidSdk.run(['devices', '-l'], timeout: const Duration(seconds: 15)))) {
      var avd = _avds[d.serial];
      if (d.emulator && d.ready && avd == null) {
        try {
          final said = await AndroidSdk.run(
            ['emu', 'avd', 'name'],
            serial: d.serial,
            timeout: const Duration(seconds: 5),
          );
          avd = said.split('\n').first.trim();
          if (avd.isNotEmpty) _avds[d.serial] = avd;
        } on Object {
          // An old emulator without the console command.
        }
      }
      out.add(AdbDevice(serial: d.serial, model: d.model, state: d.state, avd: avd));
    }
    return out;
  }

  /// The virtual devices the emulator can start.
  static Future<List<String>> avds() async {
    final emu = AndroidSdk.emulator;
    if (emu == null) return const [];
    final r = await Process.run(emu, ['-list-avds']);
    return [
      for (final l in '${r.stdout}'.split('\n'))
        if (l.trim().isNotEmpty && !l.startsWith('INFO')) l.trim(),
    ];
  }

  /// Starts virtual device [name] headless (or finds it running) and waits until Android is up.
  static Future<AdbDevice> boot(String name) async {
    String norm(String s) => s.toLowerCase().replaceAll(RegExp('[_ ]+'), ' ').trim();
    final running = (await list()).where((d) => d.ready && (norm(d.name) == norm(name) || d.serial == name));
    if (running.firstOrNull case final d?) return d;
    final avd = (await avds()).where((a) => norm(a) == norm(name)).firstOrNull;
    final emu = AndroidSdk.emulator;
    if (avd == null || emu == null) {
      final all = await avds();
      throw AppError(
        'No virtual device called "$name".${all.isEmpty ? ' None here (make one in Android Studio).' : ' These: ${all.join(', ')}.'}',
      );
    }
    final before = {for (final d in await list()) d.serial};
    await Process.start(emu, [
      '-avd',
      avd,
      '-no-window',
      '-no-audio',
      '-no-boot-anim',
      '-no-snapshot-save',
    ], mode: ProcessStartMode.detached);
    final until = DateTime.now().add(const Duration(minutes: 4));
    while (DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(seconds: 2));
      for (final d in await list()) {
        if (before.contains(d.serial) || !d.emulator || !d.ready) continue;
        if (d.avd != null && norm(d.avd!) != norm(avd)) continue;
        final up = await AndroidSdk.shell(d.serial, ['getprop', 'sys.boot_completed']).catchError((Object _) => '');
        if (up.trim() == '1') {
          _readAt = DateTime.fromMillisecondsSinceEpoch(0);
          await refresh();
          return d;
        }
      }
    }
    throw AppError('$avd did not finish starting in 4 minutes.');
  }

  static AndroidDevice driver(String serial) => _drivers.putIfAbsent(serial, () => AndroidDevice(serial));

  /// Closes the scrcpy sessions (app quit).
  static Future<void> stopAll() async {
    for (final d in _drivers.values) {
      await d.closeScrcpy();
    }
  }
}

/// An Android device or emulator, driven through adb: uiautomator's tree (pixels), `input` taps, swipes, keys and
/// text, screencap pictures, and logcat of the app in front. scrcpy's control socket types text adb can't (non-ASCII)
/// and serves the Preview's live picture.
final class AndroidDevice implements DeviceScreen {
  AndroidDevice(this.serial);

  final String serial;

  @override
  final control = LiveControl();
  @override
  final frames = FrameBook();
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
  final _refs = <String, String>{};
  var _next = 0;
  int? _sdk;
  String? _package;
  DateTime? _logSince;
  ScrcpyConnection? _scrcpy;
  Future<ScrcpyConnection>? _opening;

  @override
  ViewGeometry get geometry => ViewGeometry(width.round(), height.round());
  List<AppNode> get lastTree => _last;

  /// The app in front, as of the last tree.
  String? get package => _package;

  @override
  String get label => AndroidDevices.ready.where((d) => d.serial == serial).firstOrNull?.name ?? serial;
  @override
  String get installs => 'an .apk';
  @override
  String get launches => 'package';

  Future<String> _shell(List<String> args) => AndroidSdk.shell(serial, args);

  Future<int> _version() async =>
      _sdk ??= int.tryParse((await _shell(['getprop', 'ro.build.version.sdk'])).trim()) ?? 0;

  /// The scrcpy session (one per device, shared by the Preview and the agent's text).
  Future<ScrcpyConnection> scrcpy() {
    final c = _scrcpy;
    if (c != null && !c.closed) return Future.value(c);
    return _opening ??= ScrcpyConnection.open(serial)
        .then((c) {
          _scrcpy = c;
          return c;
        })
        .whenComplete(() => _opening = null);
  }

  Future<void> closeScrcpy() async {
    await _scrcpy?.close();
    _scrcpy = null;
  }

  @override
  Future<List<AppNode>> tree() async {
    String xml = '';
    for (var tries = 0; tries < 3; tries++) {
      final out = await AndroidSdk.run(['exec-out', 'uiautomator', 'dump', '/dev/tty'], serial: serial);
      final end = out.lastIndexOf('</hierarchy>');
      if (end > 0) {
        xml = out.substring(0, end + '</hierarchy>'.length);
        break;
      }
      // "ERROR: could not get idle state": the screen is animating.
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    if (xml.isEmpty) throw const AppError("The device's screen couldn't be read (it kept changing); try again.");
    final flat = parseUiAutomator(xml);
    if (flat.width > 0) {
      width = flat.width;
      height = flat.height;
    }
    _package = flat.package ?? _package;
    final seen = <String, int>{};
    final nodes = <AppNode>[];
    for (final n in flat.nodes) {
      if (n.ref.isEmpty) {
        nodes.add(n);
        continue;
      }
      final count = seen[n.ref] = (seen[n.ref] ?? 0) + 1;
      final ref = _refs['${n.ref}\u0001$count'] ??= 'a${++_next}';
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
    final app = _package == null ? '' : ', $_package in front';
    return appTreeText(
      '$label (screen ${width.round()}×${height.round()} px$app)',
      nodes,
      width: width,
      height: height,
    );
  }

  AppNode _node(String ref) {
    final n = _nodes[ref];
    if (n == null) throw AppError('No element $ref on the device now: take a new snapshot.');
    if (!n.placed) throw AppError('$ref has no place on screen.');
    return n;
  }

  static String _n(double v) => '${v.round()}';

  void _report(String kind, AppNode n, String verb) => control.report(
    LiveActivity(kind, x: n.centreX, y: n.centreY, caption: '$verb ${n.name.isEmpty ? n.role : n.name}'),
  );

  @override
  Future<String> tap(String ref) async {
    await _fresh();
    final n = _node(ref);
    _report('click', n, 'Tapping');
    await _shell(['input', 'tap', _n(n.centreX), _n(n.centreY)]);
    return 'Tapped ${nodeText(n)}.';
  }

  @override
  Future<String> tapAt(double x, double y) async {
    final hit = hitNode(await _fresh(), x, y);
    control.report(LiveActivity('click', x: x, y: y, caption: 'Tapping'));
    await _shell(['input', 'tap', _n(x), _n(y)]);
    return 'Tapped at (${x.round()}, ${y.round()})${hit == null ? '' : ' on ${nodeText(hit)}'}.';
  }

  @override
  Future<String> longPress(String ref) async {
    await _fresh();
    final n = _node(ref);
    _report('click', n, 'Long-pressing');
    final x = _n(n.centreX), y = _n(n.centreY);
    await _shell(['input', 'swipe', x, y, x, y, '900']);
    return 'Long-pressed ${nodeText(n)}.';
  }

  @override
  Future<String> type(String ref, String text, {bool submit = false, bool secretOk = false}) async {
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
      await _shell(['input', 'tap', _n(n.centreX), _n(n.centreY)]);
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    // Select what the field holds (Ctrl+A where `input keycombination` exists), so the text replaces it.
    final had = n.value ?? '';
    if (await _version() >= 33) {
      await _shell(['input', 'keycombination', '113', '29']);
    } else if (had.isNotEmpty) {
      await _shell(['input', 'keyevent', '123', for (var i = 0; i < had.length + 2; i++) '67']);
    }
    if (text.isEmpty) {
      await _shell(['input', 'keyevent', '67']);
    } else if (RegExp(r'^[\x20-\x7e]*$').hasMatch(text) && !text.contains('%')) {
      // `input text` reads %s as a space; plain spaces split nothing once quoted, but older versions drop them.
      await _shell(['input', 'text', text.replaceAll(' ', '%s')]);
    } else {
      (await scrcpy()).paste(text);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    if (submit) await _shell(['input', 'keyevent', '66']);
    await settle();
    await tree();
    final now = _last.where((x) => x.role == 'textbox' && x.ref == ref).firstOrNull;
    final held = now?.value ?? '';
    if (now != null && !n.secret && held != text && held == had && had != text) {
      throw AppError("Typing into $ref didn't change it: it still holds \"$held\".");
    }
    final shown = now == null || held == text ? '' : ' (the field shows "$held")';
    return 'Typed into $ref${n.name.isEmpty ? '' : ' "${n.name}"'}$shown${submit ? ' and pressed Enter' : ''}.';
  }

  static const _keys = <String, int>{
    'enter': 66,
    'return': 66,
    'escape': 111,
    'esc': 111,
    'backspace': 67,
    'tab': 61,
    'space': 62,
    'up': 19,
    'down': 20,
    'left': 21,
    'right': 22,
    'arrowup': 19,
    'arrowdown': 20,
    'arrowleft': 21,
    'arrowright': 22,
    'delete': 112,
    'home': 122,
    'end': 123,
    'pageup': 92,
    'pagedown': 93,
    'menu': 82,
    'search': 84,
  };
  static const _mods = <String, int>{
    'ctrl': 113,
    'control': 113,
    'shift': 59,
    'alt': 57,
    'option': 57,
    'cmd': 117,
    'meta': 117,
  };

  static int? _keyOf(String k) {
    if (_keys[k] case final c?) return c;
    if (k.length == 1) {
      final u = k.codeUnitAt(0);
      if (u >= 0x61 && u <= 0x7a) return 29 + u - 0x61;
      if (u >= 0x30 && u <= 0x39) return 7 + u - 0x30;
    }
    return null;
  }

  @override
  Future<String> key(String combo) async {
    final (:mods, :key) = splitKeyCombo(combo);
    final code = _keyOf(key);
    control.report(LiveActivity('type', caption: 'Pressing $combo'));
    if (code == null || (mods.isEmpty && key.length == 1)) {
      if (mods.isNotEmpty) throw AppError('Unknown key "$key" in "$combo".');
      if (RegExp(r'^[\x20-\x7e]*$').hasMatch(combo) && !combo.contains('%')) {
        await _shell(['input', 'text', combo.replaceAll(' ', '%s')]);
      } else {
        (await scrcpy()).paste(combo);
      }
      return 'Typed "$combo".';
    }
    if (mods.isEmpty) {
      await _shell(['input', 'keyevent', '$code']);
    } else {
      final m = [for (final x in mods) _mods[x] ?? (throw AppError('Unknown modifier "$x" in "$combo".'))];
      await _shell(['input', 'keycombination', ...m.map((c) => '$c'), '$code']);
    }
    return 'Pressed $combo.';
  }

  @override
  Future<String> submit() async {
    await _shell(['input', 'keyevent', '66']);
    return 'Pressed Enter.';
  }

  @override
  Future<String> scroll(double dy, {String? ref}) async {
    await _fresh();
    var x = width / 2, y = height / 2;
    if (ref != null) {
      final n = _node(ref);
      x = n.centreX;
      y = n.centreY;
    }
    final half = (dy.abs() / 2).clamp(40.0, height * 0.4);
    final from = (dy >= 0 ? y + half : y - half).clamp(8.0, height - 8);
    final to = (dy >= 0 ? y - half : y + half).clamp(8.0, height - 8);
    control.report(LiveActivity('scroll', x: x, y: y, caption: 'Scrolling'));
    await _shell(['input', 'swipe', _n(x), _n(from), _n(x), _n(to), '350']);
    return 'Scrolled ${dy >= 0 ? 'down' : 'up'} about ${dy.abs().round()} px.';
  }

  @override
  Future<String> drag(double x, double y, double toX, double toY) async {
    control.report(LiveActivity('click', x: x, y: y, caption: 'Dragging'));
    await _shell(['input', 'swipe', _n(x), _n(y), _n(toX), _n(toY), '700']);
    return 'Dragged from (${x.round()}, ${y.round()}) to (${toX.round()}, ${toY.round()}).';
  }

  @override
  Future<String> back() async {
    control.report(const LiveActivity('scroll', caption: 'Going back'));
    // With the keyboard up, Back only closes it: say so, or "nothing changed" misleads.
    final ime = await _shell(['dumpsys', 'input_method']).catchError((Object _) => '');
    final keyboard = ime.contains('mInputShown=true') || ime.contains('isInputViewShown=true');
    await _shell(['input', 'keyevent', '4']);
    return keyboard ? 'Pressed Back (it closed the on-screen keyboard; press again to go back).' : 'Pressed Back.';
  }

  @override
  Future<String> home() async {
    control.report(const LiveActivity('look', caption: 'Going home'));
    await _shell(['input', 'keyevent', '3']);
    return 'Pressed Home.';
  }

  @override
  Future<String> install(String path) async {
    final out = await AndroidSdk.run(['install', '-r', path], serial: serial, timeout: const Duration(minutes: 4));
    if (!out.contains('Success')) throw AppError("Couldn't install $path: ${out.trim()}");
    return 'Installed $path.';
  }

  @override
  Future<String> launch(String app) async {
    control.report(LiveActivity('look', caption: 'Launching $app'));
    final there = await _shell(['pm', 'path', app]).catchError((Object _) => '');
    if (!there.contains('package:')) throw AppError('$app is not installed on this device: install its .apk first.');
    await _shell(['am', 'force-stop', app]);
    final out = await _shell(['monkey', '-p', app, '-c', 'android.intent.category.LAUNCHER', '1']);
    if (out.contains('No activities found')) throw AppError('$app has no launcher activity on this device.');
    _logSince = DateTime.now();
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    return 'Launched $app.';
  }

  @override
  Future<List<String>?> logs() async {
    final pkg = _package;
    if (pkg == null) {
      await tree();
      if (_package == null) return null;
    }
    final pid = (await _shell(['pidof', _package!]).catchError((Object _) => '')).trim().split(' ').first;
    final since = _logSince;
    _logSince = DateTime.now();
    final args = [
      'logcat',
      '-d',
      '-v',
      'brief',
      if (pid.isNotEmpty) '--pid=$pid',
      if (since != null) ...['-T', _logTime(since.subtract(const Duration(seconds: 1)))] else ...['-t', '400'],
      // Info and up: the app's own Log.i/w/e and crashes, without the framework's debug chatter.
      '*:I',
    ];
    final out = await AndroidSdk.run(args, serial: serial);
    return trimLogcat(out.split('\n'));
  }

  static String _logTime(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}.000';
  }

  @override
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 600));

  @override
  String? changedSince(List<AppNode> before) => appTreeChange(before, _last, width: width, height: height);

  @override
  Future<(List<int>, AgentFrame)> frameShot({ViewRect? region}) async {
    if (width <= 0) await tree();
    final png = await screenshot();
    final r = region ?? (left: 0.0, top: 0.0, width: width, height: height);
    final size = agentImageSize(r.width, r.height, scale: region == null ? 1.0 : 2.0);
    final f = frames.record(imageWidth: size.width, imageHeight: size.height, geometry: geometry, region: region);
    final out = await cropForModel(png, width, r, size);
    return (out, f);
  }

  /// The screen now, as a PNG at the device's pixels.
  Future<Uint8List> screenshot() => AndroidSdk.runBytes(['exec-out', 'screencap', '-p'], serial: serial);

  /// The user's tap in the Preview when scrcpy isn't there (device pixels).
  Future<void> userTap(double x, double y) => _shell(['input', 'tap', _n(x), _n(y)]);
}

/// logcat lines for the model: stack traces folded to their first lines, at most [max] lines (the newest).
List<String> trimLogcat(List<String> lines, {int max = 60}) {
  final out = <String>[];
  var stack = 0;
  final frame = RegExp(r'^[A-Z]/[^(]*\(\s*\d+\):\s+(?:at |\.\.\. \d+ more)');
  void flush() {
    if (stack > 2) out.add('  … ${stack - 2} more stack lines');
    stack = 0;
  }

  for (final l in lines) {
    if (l.trim().isEmpty || l.startsWith('--------- beginning')) continue;
    if (frame.hasMatch(l.replaceAll('\t', ' '))) {
      stack++;
      if (stack <= 2) out.add(l.trimRight());
      continue;
    }
    flush();
    out.add(l.length > 400 ? '${l.substring(0, 397)}…' : l.trimRight());
  }
  flush();
  return out.length <= max ? out : ['… ${out.length - max} earlier lines', ...out.sublist(out.length - max)];
}

/// uiautomator's XML as nodes in reading order (pixels), with the screen's size and the app in front. A node's ref
/// holds its identity (class, text, id) for [AndroidDevice] to turn into a ref.
({List<AppNode> nodes, double width, double height, String? package}) parseUiAutomator(String xml) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(xml);
  } on XmlException {
    return (nodes: const [], width: 0, height: 0, package: null);
  }
  final nodes = <AppNode>[];
  var width = 0.0, height = 0.0;
  final packages = <String, int>{};
  final box = RegExp(r'\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]');
  // The words a container's children say, for a clickable container with no name of its own (Compose buttons).
  String said(XmlElement e) => [
    for (final c in e.descendantElements)
      if (c.name.local == 'node') ...[c.getAttribute('text') ?? '', c.getAttribute('content-desc') ?? ''],
  ].map((s) => s.trim()).where((s) => s.isNotEmpty).toSet().take(3).join(' ');
  final named = <XmlElement>{};
  void visit(XmlElement e) {
    for (final c in e.childElements.where((c) => c.name.local == 'node')) {
      final a = c.getAttribute;
      final m = box.firstMatch(a('bounds') ?? '');
      if (m == null) continue;
      final l = double.parse(m.group(1)!), t = double.parse(m.group(2)!);
      final r = double.parse(m.group(3)!), b = double.parse(m.group(4)!);
      if (r > width) width = r;
      if (b > height) height = b;
      final pkg = a('package') ?? '';
      if (pkg.isNotEmpty) packages[pkg] = (packages[pkg] ?? 0) + 1;
      final cls = (a('class') ?? '').split('.').last;
      final text = (a('text') ?? '').trim(), desc = (a('content-desc') ?? '').trim();
      final id = (a('resource-id') ?? '').split('/').last;
      bool flag(String k) => a(k) == 'true';
      final clickable = flag('clickable') || flag('long-clickable');
      final role = switch (cls) {
        'EditText' || 'AutoCompleteTextView' || 'TextInputEditText' => 'textbox',
        'CheckBox' => 'checkbox',
        'Switch' || 'SwitchCompat' || 'SwitchMaterial' || 'ToggleButton' => 'switch',
        'RadioButton' => 'radio',
        'SeekBar' || 'RatingBar' => 'slider',
        'Button' || 'ImageButton' || 'MaterialButton' || 'FloatingActionButton' => 'button',
        'Spinner' => 'combobox',
        'ImageView' when clickable => 'button',
        'ImageView' => 'img',
        _ when flag('checkable') => 'checkbox',
        _ when flag('scrollable') && text.isEmpty && desc.isEmpty => null,
        _ when clickable => 'button',
        _ when text.isNotEmpty || desc.isNotEmpty => 'text',
        _ => null,
      };
      var name = desc.isNotEmpty && role != 'textbox' ? desc : text;
      if (role == 'textbox') name = desc.isNotEmpty ? desc : (a('hint') ?? '').trim();
      // A clickable container takes its children's words; text inside it that its name already says isn't listed
      // again.
      if (role == 'button' && name.isEmpty) name = said(c);
      if (role == 'button' && name.isNotEmpty) {
        for (final d in c.descendantElements) {
          final words = [(d.getAttribute('text') ?? '').trim(), (d.getAttribute('content-desc') ?? '').trim()];
          if (words.every((w) => w.isEmpty || name.contains(w))) named.add(d);
        }
      }
      final skip = named.contains(c) && role == 'text';
      if (role != null && !skip && r > l && b > t && (name.isNotEmpty || role != 'img')) {
        final secret = flag('password');
        final toggles = role == 'switch' || role == 'checkbox' || role == 'radio';
        nodes.add(
          AppNode(
            ref: role == 'img' && name.isEmpty ? '' : '$cls|$name|$id',
            role: role,
            name: name.length > 120 ? '${name.substring(0, 117)}…' : name,
            value: role == 'textbox' && !secret && text != (a('hint') ?? '') ? text : null,
            state: [
              if (toggles) flag('checked') ? 'checked' : 'unchecked',
              if (!flag('enabled')) 'disabled',
              if (flag('selected')) 'selected',
              if (flag('focused') && role == 'textbox') 'focused',
            ],
            left: l,
            top: t,
            right: r,
            bottom: b,
            secret: secret,
          ),
        );
      }
      visit(c);
    }
  }

  final root = doc.findAllElements('hierarchy').firstOrNull;
  if (root != null) visit(root);
  // The keyboard's own app and the system bars aren't the app in front.
  final app =
      (packages.entries.where((e) => e.key != 'com.android.systemui' && !e.key.contains('inputmethod')).toList()
            ..sort((a, b) => b.value - a.value))
          .firstOrNull
          ?.key;
  int row(AppNode n) => (n.top! / 24).round();
  final ordered = [...nodes]..sort((a, b) => row(a) != row(b) ? row(a) - row(b) : a.left!.compareTo(b.left!));
  return (nodes: ordered, width: width, height: height, package: app);
}
