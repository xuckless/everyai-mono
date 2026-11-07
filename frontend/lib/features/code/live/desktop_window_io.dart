// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'app_view.dart';
import 'desktop_helper_io.dart';
import 'device_screen.dart';
import 'real_input.dart';
import 'frames.dart';
import 'live_session.dart';

/// `everyai-ax` on macOS (EVERYAI_AX_HELPER, the app bundle's Resources, or a dev build in `frontend/.tools/`).
/// Other systems have their own helper with the same commands ([desktopHelper]); this is null there.
String? axHelperPath() {
  if (!Platform.isMacOS) return null;
  final set = Platform.environment['EVERYAI_AX_HELPER'];
  if (set != null && File(set).existsSync()) return set;
  final exe = File(Platform.resolvedExecutable).parent.path;
  for (final p in [
    '$exe/../Resources/everyai-ax',
    '${Directory.current.path}/.tools/everyai-ax',
    '${Directory.current.path}/frontend/.tools/everyai-ax',
  ]) {
    if (File(p).existsSync()) return File(p).absolute.path;
  }
  return null;
}

/// The helper's command line for [args], or an [AppError] when this computer has none.
Future<List<String>> _helperCommand(List<String> args) async {
  final cmd = await desktopHelper();
  if (cmd == null) {
    throw AppError(desktopHelperProblem ?? 'The desktop window helper is missing from this build of EveryAI.');
  }
  return [...cmd, ...args];
}

/// Runs the desktop window helper (on X display [display] on Linux); its JSON output, or an [AppError] with what it
/// said.
Future<Object?> axHelper(List<String> args, {String? display, Duration timeout = const Duration(seconds: 30)}) async {
  final cmd = await _helperCommand(args);
  final r = await Process.run(
    cmd.first,
    cmd.sublist(1),
    environment: display == null ? null : {'DISPLAY': display},
  ).timeout(timeout);
  if (r.exitCode != 0) {
    final why = '${r.stderr}'.trim().replaceFirst(RegExp(r'^error:\s*'), '');
    throw AppError(why.isEmpty ? 'the window helper failed (exit ${r.exitCode})' : why);
  }
  final out = '${r.stdout}'.trim();
  return out.isEmpty ? null : jsonDecode(out);
}

/// One on-screen window of a process, as the helper lists it (points, screen coordinates).
typedef HelperWindow = ({
  int id,
  int pid,
  String app,
  String title,
  double x,
  double y,
  double w,
  double h,
  String exe,
});

Future<List<HelperWindow>> helperWindows(Iterable<int> pids, {String? display}) async {
  final out = await axHelper([
    'windows',
    for (final p in pids) ...['--pid', '$p'],
  ], display: display);
  return [
    for (final w in (out as List?) ?? const [])
      if (w is Map)
        (
          id: (w['id'] as num).toInt(),
          pid: (w['pid'] as num).toInt(),
          app: '${w['app'] ?? ''}',
          title: '${w['title'] ?? ''}',
          x: (w['x'] as num).toDouble(),
          y: (w['y'] as num).toDouble(),
          w: (w['w'] as num).toDouble(),
          h: (w['h'] as num).toDouble(),
          exe: '${w['exe'] ?? ''}',
        ),
  ];
}

/// Which desktop window each [DesktopWindow] driver drives, and which session holds it.
abstract final class DesktopWindows {
  static final holds = DeviceHolds();
  static final _drivers = <int, DesktopWindow>{};

  /// The driver for process [pid]'s windows; [display] (Linux) is the X display they are on, [nested] when that is
  /// a session's own headless display.
  static DesktopWindow driver(int pid, {String? display, bool nested = false}) {
    final d = _drivers.putIfAbsent(pid, () => DesktopWindow(pid));
    if (display != null) {
      d.display = display;
      d.nested = nested;
    }
    return d;
  }
}

/// The front window of a desktop app (process [pid]) on macOS, through `everyai-ax`: its accessibility tree (points
/// from the window's top-left), accessibility actions first (press, set the value, select rows, show a menu, scroll
/// bars: the user's cursor and keyboard stay theirs), the real pointer and keyboard when those can't do it and the
/// user allows it ([RealInput]), and pictures through ScreenCaptureKit.
final class DesktopWindow implements DeviceScreen {
  DesktopWindow(this.pid);

  final int pid;

  @override
  final control = LiveControl();
  @override
  final frames = FrameBook();
  @override
  var width = 0.0;
  @override
  var height = 0.0;

  /// The window's top-left on screen (points), as of the last tree or window list.
  var _left = 0.0, _top = 0.0;
  var _title = '';
  var _app = '';
  int? _windowId;
  List<AppNode> _last = const [];
  var _nodes = <String, AppNode>{};
  var _paths = <String, String>{};
  var _actions = <String, Set<String>>{};
  // Ref → the path of the list or table row it sits in.
  var _rows = <String, String>{};
  final _refs = <String, String>{};
  var _next = 0;
  var _treeAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// The window to act on: a title (or part of one) the agent picked, else the app's main window.
  String? window;

  /// Linux: the X display the app is on (":7"), and whether it's the session's own headless one: input there doesn't
  /// touch the user's pointer, so it needs no consent and no guards.
  String? display;
  bool nested = false;

  Future<Object?> _helper(List<String> args) => axHelper(args, display: display);

  /// Clicks per tap for the current call: 2 a double click, 3 a triple click (selects a line of text). More than
  /// one is always real pointer input.
  int clicks = 1;

  @override
  ViewGeometry get geometry => ViewGeometry(width.round(), height.round());
  List<AppNode> get lastTree => _last;
  int? get windowId => _windowId;

  @override
  String get label => _title.isEmpty ? (_app.isEmpty ? 'process $pid' : _app) : '$_app · $_title';
  @override
  String get installs => '';
  @override
  String get launches => '';

  /// What the window list said about it (its app and title), before the first tree.
  void known(HelperWindow w) {
    if (_app.isEmpty) _app = w.app;
    if (_title.isEmpty) _title = w.title;
  }

  /// Whether the last tree had anything to act on by ref.
  bool get hasElements => _last.any((n) => n.ref.isNotEmpty);

  /// The window's id and frame now.
  Future<HelperWindow> place() async {
    final all = await helperWindows([pid], display: display);
    if (all.isEmpty) throw AppError('Process $pid has no window on screen now.');
    final w = window;
    final pick =
        (w == null ? null : all.where((x) => x.title == w).firstOrNull) ??
        (w == null ? null : all.where((x) => x.title.toLowerCase().contains(w.toLowerCase())).firstOrNull) ??
        all.where((x) => x.title == _title).firstOrNull ??
        (all.toList()..sort((a, b) => (b.w * b.h).compareTo(a.w * a.h))).first;
    _windowId = pick.id;
    _left = pick.x;
    _top = pick.y;
    width = pick.w;
    height = pick.h;
    _title = pick.title;
    _app = pick.app;
    return pick;
  }

  Future<List<AppNode>> _fresh() async =>
      DateTime.now().difference(_treeAt) < const Duration(milliseconds: 1500) ? _last : tree();

  @override
  Future<List<AppNode>> tree() async {
    final w = await place();
    final out = await _helper(['tree', '--pid', '$pid', '--window', w.title.isEmpty ? '${w.id}' : w.title]);
    if (out is! Map) throw const AppError("The window's accessibility tree couldn't be read.");
    final flat = flattenAxHelperTree(out, left: _left, top: _top);
    final seen = <String, int>{};
    final nodes = <AppNode>[];
    final paths = <String, String>{};
    final acts = <String, Set<String>>{};
    final rows = <String, String>{};
    final rowPaths = axRowPaths(out);
    for (final (node, path, actions) in flat) {
      if (node.ref.isEmpty) {
        nodes.add(node);
        continue;
      }
      final count = seen[node.ref] = (seen[node.ref] ?? 0) + 1;
      final ref = _refs['${node.ref}\u0001$count'] ??= 'w${++_next}';
      nodes.add(node.withRef(ref));
      paths[ref] = path;
      acts[ref] = actions;
      if (rowOf(path, rowPaths) case final row?) rows[ref] = row;
    }
    _last = nodes;
    _nodes = {for (final n in nodes) n.ref: n};
    _paths = paths;
    _actions = acts;
    _rows = rows;
    _treeAt = DateTime.now();
    return nodes;
  }

  @override
  Future<String> snapshot() async {
    final nodes = await tree();
    final head = '$label (window ${width.round()}×${height.round()} pt)';
    if (!nodes.any((n) => n.ref.isNotEmpty)) {
      return '$head\n(the app exposes no accessibility elements here, as Tk and canvas apps often don\'t: use a '
          'screenshot and tap by x and y)';
    }
    return appTreeText(head, nodes, width: width, height: height);
  }

  AppNode _node(String ref) {
    final n = _nodes[ref];
    if (n == null) throw AppError('No element $ref in the window now: take a new snapshot.');
    return n;
  }

  Future<void> _act(String ref, String action, {String? text}) => _actAt(_paths[ref]!, action, text: text);

  Future<void> _actAt(String path, String action, {String? text}) => _helper([
    'act',
    '--pid',
    '$pid',
    '--path',
    path,
    '--action',
    action,
    if (text != null) ...['--text', text],
  ]);

  /// Accessibility first (in place, the user's pointer and keyboard stay theirs); the real pointer and keyboard when
  /// accessibility can't do it and the user allows it ([RealInput], asked once). Real input brings the window to
  /// the front and moves the cursor.
  Future<void> _needReal(String what) async {
    // The session's own headless display has no user pointer or keyboard to take over.
    if (nested) return;
    if (!await RealInput.ensure()) throw AppError('${RealInput.refused}: $what.');
  }

  /// Runs a helper input command as real input to the window, its app brought to the front as it is (its key
  /// window, an open pop-up list or dialog, keeps the keyboard).
  Future<void> _real(String command, List<String> args) =>
      _helper([command, '--pid', '$pid', ...args, '--front', if (nested) '--nested']);

  /// A named key ("enter", "a") with modifiers, as the helper takes it: macOS key codes, names elsewhere.
  List<String> _keyArgs(String name, [List<String> mods = const []]) {
    final m = Platform.isMacOS ? mods : [for (final x in mods) x == 'cmd' || x == 'command' ? 'ctrl' : x];
    return [
      if (Platform.isMacOS) ...['--keycode', '${_keycodes[name]}'] else ...['--keyname', name],
      if (m.isNotEmpty) ...['--mods', m.join(',')],
    ];
  }

  // Window points to screen points.
  String _sx(double x) => (x + _left).toStringAsFixed(1);
  String _sy(double y) => (y + _top).toStringAsFixed(1);

  /// A real click at window point (x, y).
  Future<void> _click(double x, double y, {int count = 1}) => _real('click', [
    '--x',
    _sx(x),
    '--y',
    _sy(y),
    if (count > 1) ...['--count', '$count'],
  ]);

  @override
  Future<String> tap(String ref) async {
    await _fresh();
    final n = _node(ref);
    control.report(
      LiveActivity(
        'click',
        x: n.placed ? n.centreX : null,
        y: n.placed ? n.centreY : null,
        caption: 'Pressing ${n.name}',
      ),
    );
    final acts = _actions[ref] ?? const {};
    final action = const ['AXPress', 'AXConfirm', 'AXPick', 'AXOpen'].where(acts.contains).firstOrNull;
    // An entry of a list or table (a file in an open panel): selecting its row is what a click does.
    // An entry's own press (a file name's text field) does nothing useful there.
    final row = action == null || const {'textbox', 'text', 'row'}.contains(n.role) ? _rows[ref] : null;
    if (clicks > 1) {
      if (!n.placed) throw AppError('${nodeText(n)} has no place on screen to click.');
      await _needReal('a ${_clickWord()} click is real pointer input');
      await _click(n.centreX, n.centreY, count: clicks);
      return '${_clickWord(capital: true)}-clicked ${nodeText(n)} (the window came to the front).';
    }
    if (row != null) {
      await _actAt(row, 'show');
      await _actAt(row, 'select');
      final what = (n.value ?? '').isNotEmpty ? n.value! : n.name;
      return 'Selected the row of $ref${what.isEmpty ? '' : ' "$what"'}.';
    }
    if (action == null) {
      if (!n.placed) throw AppError('${nodeText(n)} has no press action and no place on screen to click.');
      await _needReal('${nodeText(n)} has no press action, so it needs a real click');
      await _click(n.centreX, n.centreY);
      return 'Clicked ${nodeText(n)} (the window came to the front).';
    }
    await _act(ref, action);
    return 'Pressed ${nodeText(n)}.';
  }

  String _clickWord({bool capital = false}) {
    final w = clicks == 2 ? 'double' : 'triple';
    return capital ? '${w[0].toUpperCase()}${w.substring(1)}' : w;
  }

  @override
  Future<String> tapAt(double x, double y) async {
    if (clicks > 1) {
      await _needReal('a ${_clickWord()} click is real pointer input');
      control.report(LiveActivity('click', x: x, y: y, caption: '${_clickWord(capital: true)}-clicking'));
      await _click(x, y, count: clicks);
      return '${_clickWord(capital: true)}-clicked at (${x.round()}, ${y.round()}) (the window came to the front).';
    }
    final nodes = await _fresh();
    // The smallest pressable element under the point.
    AppNode? hit;
    double area(AppNode n) => (n.right! - n.left!) * (n.bottom! - n.top!);
    for (final n in nodes) {
      if (!n.placed || n.ref.isEmpty || !(_actions[n.ref]?.contains('AXPress') ?? false)) continue;
      if (x < n.left! || x > n.right! || y < n.top! || y > n.bottom!) continue;
      if (hit == null || area(n) < area(hit)) hit = n;
    }
    if (hit == null) {
      await _needReal('nothing at (${x.round()}, ${y.round()}) can be pressed through accessibility');
      control.report(LiveActivity('click', x: x, y: y, caption: 'Clicking'));
      await _click(x, y);
      return 'Clicked at (${x.round()}, ${y.round()}) (the window came to the front).';
    }
    control.report(LiveActivity('click', x: x, y: y, caption: 'Pressing ${hit.name}'));
    await _act(hit.ref, 'AXPress');
    return 'Pressed ${nodeText(hit)} at (${x.round()}, ${y.round()}).';
  }

  @override
  Future<String> longPress(String ref) async {
    await _fresh();
    final n = _node(ref);
    if (!(_actions[ref]?.contains('AXShowMenu') ?? false)) {
      if (!n.placed) throw AppError('${nodeText(n)} has no menu to show.');
      await _needReal('${nodeText(n)} has no menu action, so it needs a real right-click');
      await _real('click', ['--x', _sx(n.centreX), '--y', _sy(n.centreY), '--right']);
      return 'Right-clicked ${nodeText(n)} (the window came to the front).';
    }
    await _act(ref, 'AXShowMenu');
    return 'Opened the menu of ${nodeText(n)}.';
  }

  @override
  Future<String> type(String ref, String text, {bool submit = false}) async {
    await _fresh();
    final n = _node(ref);
    if (n.secret) {
      throw AppError('$ref is a password field: the agent never types into one. Ask the user to type it.');
    }
    if (n.role != 'textbox') throw AppError('$ref is a ${n.role}, not a text field.');
    control.report(LiveActivity('type', x: n.centreX, y: n.centreY, caption: 'Typing into ${n.name}'));
    // Setting the value through accessibility replaces the text without touching the keyboard focus.
    var real = false;
    try {
      await _act(ref, 'setvalue', text: text);
    } on AppError {
      real = true;
    }
    if (!real) {
      await settle();
      await tree();
      final now = _nodes[ref]?.value;
      real = now != null && now != text && now == (n.value ?? '');
    }
    if (real) {
      // The field ignored it: click into it, select all, type.
      if (!n.placed) throw AppError("$ref didn't take the text through accessibility and has no place to click.");
      await _needReal("$ref didn't take the text through accessibility, so it needs real typing");
      // A triple click selects the field's text where Cmd+A isn't bound (Tk); Cmd+A then covers multi-line fields.
      await _click(n.centreX, n.centreY, count: 3);
      await _real('key', _keyArgs('a', ['cmd']));
      await _real('key', ['--text', text]);
    }
    if (submit) {
      if (!real && (_actions[ref]?.contains('AXConfirm') ?? false)) {
        await _act(ref, 'AXConfirm');
      } else {
        await _needReal('submitting $ref needs a real Return key');
        await _real('key', _keyArgs('enter'));
      }
    }
    await settle();
    await tree();
    final held = _nodes[ref]?.value;
    final shown = held == null || held == text ? '' : ' (the field shows "$held")';
    return '${real ? 'Typed into' : 'Set'} $ref${n.name.isEmpty ? '' : ' "${n.name}"'}${real ? '' : ' to the text'}'
        '$shown${submit ? ' and confirmed it' : ''}.';
  }

  @override
  Future<String> submit() => key('enter');

  static const _keycodes = <String, int>{
    'a': 0,
    's': 1,
    'd': 2,
    'f': 3,
    'h': 4,
    'g': 5,
    'z': 6,
    'x': 7,
    'c': 8,
    'v': 9,
    'b': 11,
    'q': 12,
    'w': 13,
    'e': 14,
    'r': 15,
    'y': 16,
    't': 17,
    '1': 18,
    '2': 19,
    '3': 20,
    '4': 21,
    '6': 22,
    '5': 23,
    '=': 24,
    '9': 25,
    '7': 26,
    '-': 27,
    '8': 28,
    '0': 29,
    ']': 30,
    'o': 31,
    'u': 32,
    '[': 33,
    'i': 34,
    'p': 35,
    'l': 37,
    'j': 38,
    "'": 39,
    'k': 40,
    ';': 41,
    '\\': 42,
    ',': 43,
    '/': 44,
    'n': 45,
    'm': 46,
    '.': 47,
    '`': 50,
    'enter': 36,
    'return': 36,
    'tab': 48,
    'space': 49,
    'backspace': 51,
    'escape': 53,
    'esc': 53,
    'delete': 117,
    'home': 115,
    'end': 119,
    'pageup': 116,
    'pagedown': 121,
    'left': 123,
    'right': 124,
    'down': 125,
    'up': 126,
    'arrowleft': 123,
    'arrowright': 124,
    'arrowdown': 125,
    'arrowup': 126,
    'f1': 122,
    'f2': 120,
    'f3': 99,
    'f4': 118,
    'f5': 96,
    'f6': 97,
    'f7': 98,
    'f8': 100,
    'f9': 101,
    'f10': 109,
    'f11': 103,
    'f12': 111,
  };

  /// A key or shortcut (or text when it names no key), as real keyboard input to the window.
  @override
  Future<String> key(String combo) async {
    final (:mods, key: name) = splitKeyCombo(combo);
    final code = _keycodes[name];
    for (final m in mods) {
      if (!const {'cmd', 'command', 'shift', 'alt', 'option', 'ctrl', 'control'}.contains(m)) {
        throw AppError('Unknown modifier "$m" in "$combo".');
      }
    }
    if (code == null && mods.isNotEmpty) throw AppError('Unknown key "$name" in "$combo".');
    await _needReal('keys are real keyboard input');
    control.report(LiveActivity('type', caption: 'Pressing $combo'));
    if (code == null) {
      await _real('key', ['--text', combo]);
      return 'Typed "$combo" (the window came to the front).';
    }
    await _real('key', _keyArgs(name, mods));
    return 'Pressed $combo (the window came to the front).';
  }

  @override
  Future<String> scroll(double dy, {String? ref}) async {
    await _fresh();
    // A scroll bar's increment/decrement actions, the accessible way to scroll.
    final bars = [
      for (final n in _last)
        if (n.role == 'slider' && n.name.toLowerCase().contains('scroll')) n,
    ];
    final target = ref == null ? null : _nodes[ref];
    final bar = target == null ? bars.firstOrNull : null;
    if (bar == null) {
      // The wheel, over the element or the window's middle.
      await _needReal('there is no scroll bar to scroll through accessibility, so it needs the real wheel');
      final over = target != null && target.placed;
      final x = over ? target.centreX : width / 2, y = over ? target.centreY : height / 2;
      control.report(LiveActivity('scroll', x: x, y: y, caption: 'Scrolling'));
      await _real('scroll', ['--x', _sx(x), '--y', _sy(y), '--dy', '${dy.round()}']);
      return 'Scrolled ${dy >= 0 ? 'down' : 'up'} about ${dy.abs().round()} pt with the wheel (the window came to '
          'the front).';
    }
    final step = dy >= 0 ? 'AXIncrement' : 'AXDecrement';
    for (var i = 0; i < (dy.abs() / 120).ceil().clamp(1, 20); i++) {
      await _act(bar.ref, step);
    }
    return 'Scrolled ${dy >= 0 ? 'down' : 'up'} with ${nodeText(bar)}.';
  }

  @override
  Future<String> drag(double x, double y, double toX, double toY) async {
    await _needReal('drags are real pointer input');
    control.report(LiveActivity('drag', x: toX, y: toY, caption: 'Dragging'));
    await _real('drag', ['--x', _sx(x), '--y', _sy(y), '--to-x', _sx(toX), '--to-y', _sy(toY)]);
    return 'Dragged from (${x.round()}, ${y.round()}) to (${toX.round()}, ${toY.round()}) (the window came to the '
        'front).';
  }

  @override
  Future<String> back() => throw const AppError('A desktop window has no back: use key ("Escape", "cmd+[").');
  @override
  Future<String> home() => throw const AppError('A desktop window has no home.');
  @override
  Future<String> install(String path) => throw const AppError('install is for simulators and emulators.');
  @override
  Future<String> launch(String app) =>
      throw const AppError('launch is for simulators and emulators: start a desktop app with bash or app_run.');
  @override
  Future<List<String>?> logs() async => null;
  @override
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 400));
  @override
  String? changedSince(List<AppNode> before) => appTreeChange(before, _last, width: width, height: height);

  @override
  Future<(List<int>, AgentFrame)> frameShot({ViewRect? region}) async {
    final w = await place();
    final dir = Directory.systemTemp.createTempSync('everyai-window');
    try {
      final file = '${dir.path}/w.png';
      await _helper(['shot', '--window', '${w.id}', '--out', file, if (nested) '--nested']);
      final png = File(file).readAsBytesSync();
      final r = region ?? (left: 0.0, top: 0.0, width: width, height: height);
      final size = agentImageSize(r.width, r.height, scale: region == null ? 1.0 : 2.0);
      final f = frames.record(imageWidth: size.width, imageHeight: size.height, geometry: geometry, region: region);
      return (await cropForModel(png, width, r, size), f);
    } finally {
      dir.deleteSync(recursive: true);
    }
  }

  /// The window as JPEG frames for the Preview, while listened to.
  Stream<Uint8List> stream({int fps = 10, double scale = 0.5}) {
    Process? p;
    late final StreamController<Uint8List> out;
    out = StreamController<Uint8List>(
      onListen: () async {
        try {
          final w = await place();
          final cmd = await _helperCommand([
            'stream',
            '--window',
            '${w.id}',
            '--fps',
            '$fps',
            '--scale',
            '$scale',
            if (nested) '--nested',
          ]);
          p = await Process.start(
            cmd.first,
            cmd.sublist(1),
            environment: display == null ? null : {'DISPLAY': display!},
          );
          unawaited(p!.stderr.drain<void>());
          await p!.stdout.transform(MjpegParts()).pipe(out);
        } on Object catch (e) {
          if (!out.isClosed) {
            out.addError(e);
            await out.close();
          }
        }
      },
      onCancel: () => p?.kill(),
    );
    return out.stream;
  }

  /// The user's click in the Preview (window points): pressed through accessibility when the element there has a
  /// press action, else a real click when the user allows real input (it brings the window to the front).
  Future<bool> userClick(double x, double y) async {
    final hit = hitNode(await _fresh(), x, y);
    if (hit != null && hit.ref.isNotEmpty && (_actions[hit.ref]?.contains('AXPress') ?? false)) {
      await _act(hit.ref, 'AXPress');
      return true;
    }
    if (!await RealInput.ensure()) return false;
    await _click(x, y);
    return true;
  }

  /// Brings the window to the front (the Preview's button).
  Future<void> raise() => _helper([
    'raise',
    '--pid',
    '$pid',
    if (_title.isNotEmpty) ...['--window', _title],
  ]);
}

/// The paths of the rows (table, list and outline rows) in the helper's tree JSON.
Set<String> axRowPaths(Map<Object?, Object?> json) => {
  for (final n in (json['nodes'] as List?) ?? const [])
    if (n is Map && const {'AXRow', 'AXOutlineRow'}.contains(n['role'])) '${n['path']}',
};

/// The row [path] sits in (itself, or its nearest row ancestor), if any.
String? rowOf(String path, Set<String> rows) {
  for (var p = path; p.isNotEmpty; p = p.contains('.') ? p.substring(0, p.lastIndexOf('.')) : '') {
    if (rows.contains(p)) return p;
  }
  return null;
}

/// The helper's tree JSON as nodes (points from the window's top-left at [left], [top]) with each one's path and
/// actions. A node's ref holds its identity (role, name, identifier) for the driver to number.
List<(AppNode, String, Set<String>)> flattenAxHelperTree(
  Map<Object?, Object?> json, {
  double left = 0,
  double top = 0,
}) {
  final out = <(AppNode, String, Set<String>)>[];
  for (final n in (json['nodes'] as List?) ?? const []) {
    if (n is! Map) continue;
    final ax = '${n['role'] ?? ''}', sub = '${n['subrole'] ?? ''}';
    final actions = {for (final a in (n['actions'] as List?) ?? const []) '$a'};
    String s(String k) => '${n[k] ?? ''}'.trim();
    final title = s('title'), desc = s('desc'), label = s('label'), help = s('help'), placeholder = s('placeholder');
    final value = s('value');
    // Window chrome the agent shouldn't press by accident.
    if (const {'AXCloseButton', 'AXMinimizeButton', 'AXZoomButton', 'AXFullScreenButton'}.contains(sub)) continue;
    final role = switch (ax) {
      'AXButton' || 'AXMenuButton' || 'AXDisclosureTriangle' => 'button',
      'AXTextField' || 'AXTextArea' || 'AXSearchField' || 'AXComboBox' => 'textbox',
      'AXCheckBox' when sub == 'AXSwitch' => 'switch',
      'AXCheckBox' => 'checkbox',
      'AXRadioButton' when sub == 'AXTabButton' => 'tab',
      'AXRadioButton' => 'radio',
      'AXSlider' || 'AXIncrementor' => 'slider',
      'AXPopUpButton' => 'combobox',
      'AXLink' => 'link',
      'AXMenuItem' || 'AXMenuBarItem' => 'menuitem',
      'AXHeading' => 'heading',
      'AXImage' => 'img',
      'AXStaticText' => 'text',
      'AXRow' || 'AXCell' || 'AXOutlineRow' when actions.contains('AXPress') => 'row',
      _ when actions.contains('AXPress') && (title.isNotEmpty || desc.isNotEmpty) => 'button',
      _ => null,
    };
    if (role == null) continue;
    final secret = sub == 'AXSecureTextField';
    var name = [title, label, desc].firstWhere((x) => x.isNotEmpty, orElse: () => '');
    if (role == 'textbox' && name.isEmpty) name = placeholder.isNotEmpty ? placeholder : help;
    if (role == 'text') name = value.isNotEmpty ? value : name;
    if ((role == 'text' || role == 'img') && name.isEmpty) continue;
    // Pictures nothing can press are decoration (sidebar icons, badges).
    if (role == 'img' && !actions.contains('AXPress')) continue;
    final x = (n['x'] as num?)?.toDouble(), y = (n['y'] as num?)?.toDouble();
    final w = (n['w'] as num?)?.toDouble(), h = (n['h'] as num?)?.toDouble();
    final toggles = role == 'checkbox' || role == 'radio' || role == 'switch' || role == 'tab';
    final node = AppNode(
      ref: (role == 'text' || role == 'img') && !actions.contains('AXPress') ? '' : '$ax|$name|${s('identifier')}',
      role: role,
      name: name.length > 120 ? '${name.substring(0, 117)}…' : name,
      value: role == 'textbox' && !secret ? value : (role == 'slider' ? value : null),
      state: [
        if (toggles) value == '1' ? (role == 'tab' ? 'selected' : 'checked') : (role == 'tab' ? '' : 'unchecked'),
        if (n['enabled'] == false) 'disabled',
        if (n['focused'] == true) 'focused',
      ].where((s) => s.isNotEmpty).toList(),
      left: x == null ? null : x - left,
      top: y == null ? null : y - top,
      right: x == null || w == null ? null : x + w - left,
      bottom: y == null || h == null ? null : y + h - top,
      secret: secret,
    );
    out.add((node, '${n['path']}', actions));
  }
  return out;
}

/// Splits an MJPEG stream into JPEG frames by each part's Content-Length (the helper's and AXe's format).
final class MjpegParts extends StreamTransformerBase<List<int>, Uint8List> {
  static final _length = RegExp(r'Content-Length:\s*(\d+)\r?\n\r?\n', caseSensitive: false);

  @override
  Stream<Uint8List> bind(Stream<List<int>> stream) async* {
    var data = Uint8List(0);
    await for (final chunk in stream) {
      data = Uint8List.fromList([...data, ...chunk]);
      for (;;) {
        final head = latin1.decode(Uint8List.sublistView(data, 0, data.length < 4096 ? data.length : 4096));
        final m = _length.firstMatch(head);
        if (m == null) {
          if (data.length > 4096) data = Uint8List.sublistView(data, data.length - 1024);
          break;
        }
        final size = int.parse(m.group(1)!);
        if (data.length < m.end + size) break;
        yield Uint8List.fromList(Uint8List.sublistView(data, m.end, m.end + size));
        data = Uint8List.sublistView(data, m.end + size);
      }
    }
  }
}
