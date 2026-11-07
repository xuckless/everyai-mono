// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'app_view.dart';
import 'device_screen.dart';
import 'frames.dart';
import 'live_session.dart';

/// `everyai-ax`, our macOS helper for desktop windows (`tool/ax_helper/main.swift`): EVERYAI_AX_HELPER, the app
/// bundle's Resources, or a dev build in `frontend/.tools/` (`tool/build_ax_helper.sh`).
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

/// Runs the helper; its JSON output, or an [AppError] with what it said.
Future<Object?> axHelper(List<String> args, {Duration timeout = const Duration(seconds: 30)}) async {
  final exe = axHelperPath();
  if (exe == null) {
    throw const AppError('The desktop window helper (everyai-ax) is missing from this build of EveryAI.');
  }
  final r = await Process.run(exe, args).timeout(timeout);
  if (r.exitCode != 0) {
    final why = '${r.stderr}'.trim().replaceFirst(RegExp(r'^error:\s*'), '');
    throw AppError(why.isEmpty ? 'the window helper failed (exit ${r.exitCode})' : why);
  }
  final out = '${r.stdout}'.trim();
  return out.isEmpty ? null : jsonDecode(out);
}

/// One on-screen window of a process, as the helper lists it (points, screen coordinates).
typedef HelperWindow = ({int id, int pid, String app, String title, double x, double y, double w, double h});

Future<List<HelperWindow>> helperWindows(Iterable<int> pids) async {
  final out = await axHelper([
    'windows',
    for (final p in pids) ...['--pid', '$p'],
  ]);
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
        ),
  ];
}

/// Which desktop window each [DesktopWindow] driver drives, and which session holds it.
abstract final class DesktopWindows {
  static final holds = DeviceHolds();
  static final _drivers = <int, DesktopWindow>{};

  static DesktopWindow driver(int pid) => _drivers.putIfAbsent(pid, () => DesktopWindow(pid));
}

/// The front window of a desktop app (process [pid]) on macOS, through `everyai-ax`: its accessibility tree (points
/// from the window's top-left), actions through accessibility only (press, set the value, show a menu, scroll bars:
/// the user's cursor and keyboard stay theirs; the owner's rule), and pictures through ScreenCaptureKit. Apps with no
/// accessibility tree (Tk, games, canvases) can be seen but not driven.
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
    final all = await helperWindows([pid]);
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
    final out = await axHelper(['tree', '--pid', '$pid', '--window', w.title.isEmpty ? '0' : w.title]);
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

  Future<void> _actAt(String path, String action, {String? text}) => axHelper([
    'act',
    '--pid',
    '$pid',
    '--path',
    path,
    '--action',
    action,
    if (text != null) ...['--text', text],
  ]);

  /// The owner's rule for desktop windows: EveryAI acts through accessibility only, never synthetic mouse or key
  /// events (they would move the user's cursor or type into whatever has the focus).
  static const _axOnly =
      'EveryAI acts on desktop windows through accessibility only (no synthetic clicks or keys), and this needs one';

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
    if (row != null) {
      await _actAt(row, 'show');
      await _actAt(row, 'select');
      final what = (n.value ?? '').isNotEmpty ? n.value! : n.name;
      return 'Selected the row of $ref${what.isEmpty ? '' : ' "$what"'}.';
    }
    if (action == null) {
      throw AppError('${nodeText(n)} has no press action. $_axOnly: try the control around it, or a menu item.');
    }
    await _act(ref, action);
    return 'Pressed ${nodeText(n)}.';
  }

  @override
  Future<String> tapAt(double x, double y) async {
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
      throw AppError(
        'Nothing at (${x.round()}, ${y.round()}) can be pressed through accessibility. $_axOnly: '
        '${hasElements ? 'tap an element by ref (snapshot lists them)' : 'this app exposes no accessibility elements, so EveryAI can show it but not click in it; ask the user to click, or test its logic another way'}.',
      );
    }
    control.report(LiveActivity('click', x: x, y: y, caption: 'Pressing ${hit.name}'));
    await _act(hit.ref, 'AXPress');
    return 'Pressed ${nodeText(hit)} at (${x.round()}, ${y.round()}).';
  }

  @override
  Future<String> longPress(String ref) async {
    await _fresh();
    final n = _node(ref);
    if (!(_actions[ref]?.contains('AXShowMenu') ?? false)) throw AppError('${nodeText(n)} has no menu to show.');
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
    await _act(ref, 'setvalue', text: text);
    if (submit) {
      if (_actions[ref]?.contains('AXConfirm') ?? false) {
        await _act(ref, 'AXConfirm');
      } else {
        throw AppError('Set $ref, but it has no confirm action for submit. $_axOnly: press the form\'s button by ref.');
      }
    }
    await settle();
    await tree();
    final held = _nodes[ref]?.value;
    if (held != null && held != text && held == (n.value ?? '')) {
      throw AppError("$ref didn't take the text through accessibility (it still holds \"$held\"). $_axOnly.");
    }
    final shown = held == null || held == text ? '' : ' (the field shows "$held")';
    return 'Set $ref${n.name.isEmpty ? '' : ' "${n.name}"'} to the text$shown${submit ? ' and confirmed it' : ''}.';
  }

  @override
  Future<String> submit() => key('enter');

  /// Keys would be synthetic input: refused (the owner's rule), with what works instead.
  @override
  Future<String> key(String combo) async => throw AppError(
    'Keys can\'t be sent to a desktop window. $_axOnly: set text fields with type, and press buttons (OK, Cancel, '
    'Done) by ref.',
  );

  @override
  Future<String> scroll(double dy, {String? ref}) async {
    await _fresh();
    // A scroll bar's increment/decrement actions, the accessible way to scroll.
    final bars = [
      for (final n in _last)
        if (n.role == 'slider' && n.name.toLowerCase().contains('scroll')) n,
    ];
    final bar = bars.firstOrNull;
    if (bar == null) throw AppError('No scroll bar here to scroll with. $_axOnly.');
    final step = dy >= 0 ? 'AXIncrement' : 'AXDecrement';
    for (var i = 0; i < (dy.abs() / 120).ceil().clamp(1, 20); i++) {
      await _act(bar.ref, step);
    }
    return 'Scrolled ${dy >= 0 ? 'down' : 'up'} with ${nodeText(bar)}.';
  }

  @override
  Future<String> drag(double x, double y, double toX, double toY) async => throw const AppError(
    'Drags would be synthetic input: $_axOnly. Sliders: adjust is not here; set by ref if '
    'they take a value.',
  );

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
      await axHelper(['shot', '--window', '${w.id}', '--out', file]);
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
          final exe = axHelperPath();
          if (exe == null) throw const AppError('The desktop window helper (everyai-ax) is missing.');
          p = await Process.start(exe, ['stream', '--window', '${w.id}', '--fps', '$fps', '--scale', '$scale']);
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
  /// press action; otherwise nothing (the user brings the window to the front to use it).
  Future<bool> userClick(double x, double y) async {
    final hit = hitNode(await _fresh(), x, y);
    if (hit != null && hit.ref.isNotEmpty && (_actions[hit.ref]?.contains('AXPress') ?? false)) {
      await _act(hit.ref, 'AXPress');
      return true;
    }
    return false;
  }

  /// Brings the window to the front (the Preview's button).
  Future<void> raise() => axHelper([
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
