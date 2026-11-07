// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'app_view.dart';
import 'frames.dart';
import 'live_session.dart';

/// A Flutter app in debug mode (`flutter run`, any device), driven through its Dart VM service at [serviceUri]
/// (`http://127.0.0.1:PORT/TOKEN=/`, as `flutter run` prints it).
///
/// - The element list is the app's semantics tree (switched on with `ensureSemantics`, which the framework skips
///   otherwise), read in one evaluated expression with each node's place on screen.
/// - Actions are semantics actions (tap, setText) where the node has them, else pointer events at its centre.
/// - Pictures come from the widget inspector's screenshot (the Flutter layer only: no platform views).
/// - Hot reload and restart are the services `flutter run` registers on the VM service.
/// - The log is the app's stdout/stderr, `developer.log` records and Flutter's structured errors.
final class FlutterApp {
  FlutterApp(this.serviceUri);

  final Uri serviceUri;

  /// Who drives the app (agent or user), and the agent's actions for the Preview's ghost cursor.
  final control = LiveControl();

  /// The pictures of the app the model has seen.
  final frames = FrameBook();

  // Closed in close().
  // ignore: close_sinks
  WebSocket? _ws;
  var _nextId = 0;
  final _calls = <String, Completer<Map<String, Object?>>>{};

  /// Registered services (`reloadSources`, `hotRestart`) to the method names to call them by (`s1.reloadSources`).
  final _services = <String, String>{};

  String? _isolate;
  String? _rendering;
  String? _widgets;
  String? _rootLib;
  var _semantics = false;

  /// Whether this Flutter has `SemanticsFlags.toStrings` (3.38+); older ones list `SemanticsFlag`s.
  bool? _flagStrings;

  /// The view's size in logical pixels and its device pixel ratio, as of the last tree.
  var width = 0.0;
  var height = 0.0;
  var pixelRatio = 1.0;

  /// The last element list, by ref.
  var _nodes = <String, AppNode>{};
  List<AppNode> _last = const [];

  final _log = <String>[];
  final _logged = <String>[];
  var _pointer = 4000;

  bool get connected => _ws != null;

  /// The view's size now, in logical pixels.
  ViewGeometry get geometry => ViewGeometry(width.round(), height.round(), scale: pixelRatio);

  Uri get _wsUri {
    final path = serviceUri.path.endsWith('/') ? serviceUri.path : '${serviceUri.path}/';
    return serviceUri.replace(scheme: serviceUri.scheme == 'https' ? 'wss' : 'ws', path: '${path}ws');
  }

  Future<void> _connect() async {
    if (_ws != null) return;
    final WebSocket ws;
    try {
      ws = await WebSocket.connect(_wsUri.toString()).timeout(const Duration(seconds: 5));
    } on Object catch (e) {
      throw AppError("Can't reach the Flutter app's VM service ($serviceUri): it may have stopped. ($e)");
    }
    _ws = ws;
    ws.listen(_onMessage, onDone: () => _closed(ws), onError: (Object _) => _closed(ws));
    await Future.wait([
      for (final s in ['Service', 'Stdout', 'Stderr', 'Logging', 'Extension', 'Isolate'])
        _call('streamListen', {'streamId': s}).then<void>((_) {}, onError: (Object _) {}),
    ]);
  }

  void _closed(WebSocket ws) {
    if (!identical(_ws, ws)) return;
    _ws = null;
    _resetIsolate();
    for (final c in _calls.values) {
      if (!c.isCompleted) c.completeError(const AppError('The Flutter app closed its VM service (it stopped?).'));
    }
    _calls.clear();
  }

  void _resetIsolate() {
    _isolate = _rendering = _widgets = _rootLib = null;
    _semantics = false;
    // A new isolate numbers its nodes again; refs already given stay retired.
    _refs.clear();
    _nodes = {};
    _last = const [];
  }

  void _onMessage(Object? data) {
    if (data is! String) return;
    final Map<String, Object?> msg;
    try {
      msg = (jsonDecode(data) as Map).cast();
    } on Object {
      return;
    }
    if (msg['id'] case final Object id) {
      final c = _calls.remove('$id');
      if (c == null) return;
      if (msg['error'] case final Map<Object?, Object?> e) {
        final details = (e['data'] as Map?)?['details'];
        c.completeError(AppError('${e['message']}${details == null ? '' : ': $details'}', fromApp: details != null));
      } else {
        c.complete(((msg['result'] as Map?) ?? const {}).cast());
      }
      return;
    }
    final params = (msg['params'] as Map?)?.cast<String, Object?>();
    final event = (params?['event'] as Map?)?.cast<String, Object?>();
    if (event == null) return;
    switch (params?['streamId']) {
      case 'Service':
        final service = event['service'] as String?, method = event['method'] as String?;
        if (service == null) break;
        if (event['kind'] == 'ServiceRegistered' && method != null) _services[service] = method;
        if (event['kind'] == 'ServiceUnregistered') _services.remove(service);
      case 'Stdout' || 'Stderr':
        final bytes = event['bytes'] as String?;
        if (bytes == null) break;
        final text = utf8.decode(base64Decode(bytes), allowMalformed: true);
        final err = params?['streamId'] == 'Stderr';
        for (final l in const LineSplitter().convert(text)) {
          if (l.trim().isNotEmpty) _add(err ? 'stderr: $l' : l);
        }
      case 'Logging':
        final r = (event['logRecord'] as Map?)?.cast<String, Object?>();
        final m = (r?['message'] as Map?)?['valueAsString'];
        final name = (r?['loggerName'] as Map?)?['valueAsString'];
        if (m != null) _add('log${name == null || '$name'.isEmpty ? '' : ' [$name]'}: $m');
      case 'Extension':
        if (event['extensionKind'] == 'Flutter.Error') {
          final d = (event['extensionData'] as Map?)?.cast<String, Object?>();
          final text = d?['renderedErrorText'] ?? d?['description'];
          if (text != null) _add('Flutter error: ${'$text'.trim()}');
        }
      case 'Isolate':
        if (event['kind'] == 'IsolateExit' && (event['isolate'] as Map?)?['id'] == _isolate) _resetIsolate();
    }
  }

  void _add(String line) {
    _log.add(line.length > 2000 ? '${line.substring(0, 2000)}…' : line);
    if (_log.length > 200) _log.removeRange(0, _log.length - 200);
  }

  /// What the app logged since the last call; cleared on read (the last 50 lines stay in [history]).
  List<String> takeLog() {
    final out = [..._log];
    _logged.addAll(out);
    if (_logged.length > 50) _logged.removeRange(0, _logged.length - 50);
    _log.clear();
    return out;
  }

  /// The last 50 lines the app logged, read or not.
  List<String> get history => [..._logged, ..._log];

  Future<Map<String, Object?>> _call(String method, [Map<String, Object?> params = const {}]) {
    final ws = _ws;
    if (ws == null) return Future.error(const AppError('Not connected to the Flutter app.'));
    final id = '${++_nextId}';
    final c = _calls[id] = Completer();
    ws.add(jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params}));
    return c.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _calls.remove(id);
        throw AppError('The Flutter app did not answer $method in 30 s (paused at a breakpoint, or busy?).');
      },
    );
  }

  /// Finds the app's UI isolate (the one with the widget inspector) and the libraries expressions run in.
  Future<void> _ready() async {
    await _connect();
    if (_isolate != null) return;
    final vm = await _call('getVM');
    final isolates = [for (final i in (vm['isolates'] as List?) ?? const []) (i as Map).cast<String, Object?>()];
    isolates.sort((a, b) => (a['name'] == 'main' ? 0 : 1) - (b['name'] == 'main' ? 0 : 1));
    for (final i in isolates) {
      final iso = await _call('getIsolate', {'isolateId': i['id']});
      final rpcs = ((iso['extensionRPCs'] as List?) ?? const []).cast<Object?>();
      if (!rpcs.contains('ext.flutter.inspector.screenshot') && !rpcs.contains('ext.flutter.reassemble')) continue;
      String? lib(String uri) => [
        for (final l in (iso['libraries'] as List?) ?? const [])
          if ((l as Map)['uri'] == uri) l['id'] as String?,
      ].firstOrNull;
      _isolate = i['id'] as String?;
      _rendering = lib('package:flutter/src/rendering/binding.dart');
      _widgets = lib('package:flutter/src/widgets/editable_text.dart');
      _rootLib = (iso['rootLib'] as Map?)?['id'] as String?;
      break;
    }
    if (_isolate == null || _rendering == null) {
      throw const AppError(
        "The app's VM service has no Flutter UI isolate with the debug extensions (a profile or release build, or "
        'still starting?). Run it in debug mode (flutter run).',
      );
    }
  }

  /// Evaluates one-line Dart [expression] in library [target] of the UI isolate; the result as a string.
  Future<String> _eval(String target, String expression) async {
    final r = await _call('evaluate', {'isolateId': _isolate, 'targetId': target, 'expression': expression});
    if (r['type'] == '@Error' || r['kind'] == 'Error' || r['kind'] == 'UnhandledException') {
      throw AppError(shortError('${r['message'] ?? (r['exception'] as Map?)?['valueAsString'] ?? r}'), fromApp: true);
    }
    if (r['valueAsStringIsTruncated'] == true && r['id'] != null) {
      final full = await _call('getObject', {'isolateId': _isolate, 'objectId': r['id'], 'count': 4 * 1024 * 1024});
      return '${full['valueAsString'] ?? ''}';
    }
    if (r['kind'] == 'Null') return 'null';
    return '${r['valueAsString'] ?? r['kind'] ?? ''}';
  }

  Future<String> _evalRendering(String expression) => _eval(_rendering!, expression);

  static const _owner = 'RendererBinding.instance.renderViews.first.owner!.semanticsOwner!';

  /// The tree expression: rows of `id, left, top, right, bottom, label, value, hint, tooltip, flags, actions`
  /// (physical pixels), after a first row of the view's logical size and pixel ratio.
  static String _treeJs(bool flagStrings) {
    final flags = flagStrings
        ? 'd.flagsCollection.toStrings().join(",")'
        // ignore: no_adjacent_strings_in_list
        : 'SemanticsFlag.values.where((f) => d.hasFlag(f)).map((f) => f.name).join(",")';
    return oneLineDart('''
(() {
  final view = RendererBinding.instance.renderViews.first;
  final out = <String>[[view.size.width, view.size.height, view.flutterView.devicePixelRatio].join('\\u001f')];
  final root = view.owner!.semanticsOwner?.rootSemanticsNode;
  String c(String s) => s.replaceAll('\\u001f', ' ').replaceAll('\\u001e', ' ');
  void visit(SemanticsNode n, Matrix4 m) {
    final t = n.transform == null ? m : (m.clone()..multiply(n.transform!));
    final r = MatrixUtils.transformRect(t, n.rect);
    final d = n.getSemanticsData();
    out.add([n.id, r.left, r.top, r.right, r.bottom, c(d.label), c(d.value), c(d.hint), c(d.tooltip), $flags,
      SemanticsAction.values.where((a) => d.hasAction(a)).map((a) => a.name).join(',')].join('\\u001f'));
    n.visitChildren((k) { visit(k, t); return true; });
  }
  if (root != null) visit(root, Matrix4.identity());
  return out.join('\\u001e');
})()''');
  }

  /// Switches the app's semantics on (once per isolate): Flutter builds the tree only when asked.
  Future<void> _ensureSemantics() async {
    if (_semantics) return;
    await _evalRendering('RendererBinding.instance.ensureSemantics().toString()');
    _semantics = true;
  }

  /// The app's element list now.
  Future<List<AppNode>> tree() async {
    await _ready();
    await _ensureSemantics();
    String raw = '';
    for (var tries = 0; tries < 10; tries++) {
      try {
        raw = await _evalRendering(_treeJs(_flagStrings ?? true));
        _flagStrings ??= true;
      } on AppError catch (e) {
        if (_flagStrings != null || !e.message.contains('toStrings')) rethrow;
        _flagStrings = false;
        raw = await _evalRendering(_treeJs(false));
      }
      // The first frame after switching semantics on builds the tree.
      if (raw.contains('\u001e')) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final rows = raw.split('\u001e');
    final head = rows.first.split('\u001f');
    width = double.tryParse(head[0]) ?? width;
    height = double.tryParse(head.elementAtOrNull(1) ?? '') ?? height;
    pixelRatio = double.tryParse(head.elementAtOrNull(2) ?? '') ?? pixelRatio;
    final nodes = <AppNode>[];
    for (final row in rows.skip(1)) {
      final f = row.split('\u001f');
      if (f.length < 11) continue;
      final node = flutterNode(f, pixelRatio);
      if (node != null) nodes.add(node);
    }
    // A control's unnamed twin inside it (a SwitchListTile's Switch) adds nothing.
    nodes.removeWhere(
      (n) =>
          n.name.isEmpty &&
          n.value == null &&
          n.placed &&
          nodes.any(
            (o) =>
                !identical(o, n) &&
                o.role == n.role &&
                o.name.isNotEmpty &&
                o.placed &&
                o.left! < n.right! &&
                n.left! < o.right! &&
                o.top! < n.bottom! &&
                n.top! < o.bottom!,
          ),
    );
    // Reading order: rows top to bottom (a few pixels count as one row), left to right in a row; unplaced last.
    int row(AppNode n) => n.placed ? (n.top! / 8).round() : 1 << 30;
    nodes.sort((a, b) => row(a) - row(b) != 0 ? row(a) - row(b) : (a.left ?? 0).compareTo(b.left ?? 0));
    // Flutter reuses a semantics id for other content (a list that shifted): a ref names one element, so an id
    // whose role or name changed gets a new ref, and the old ref stops working instead of hitting something else.
    final mapped = <AppNode>[];
    final ids = <String, int>{};
    for (final n in nodes) {
      if (n.ref.isEmpty) {
        mapped.add(n);
        continue;
      }
      final id = int.parse(n.ref.substring(1));
      final identity = '${n.role}\u0001${n.name}';
      var known = _refs[id];
      if (known == null || known.identity != identity) {
        // First seen: its own id, unless that ref meant something else before.
        final ref = known == null && !_refsUsed.contains('s$id') ? 's$id' : 's${_freshRef()}';
        known = (ref: ref, identity: identity);
        _refs[id] = known;
      }
      _refsUsed.add(known.ref);
      ids[known.ref] = id;
      mapped.add(n.withRef(known.ref));
    }
    _semanticsIds = ids;
    _last = mapped;
    _nodes = {for (final n in mapped) n.ref: n};
    return mapped;
  }

  /// Semantics id to the ref it is shown as, and what it was (role and name) when the ref was given.
  final _refs = <int, ({String ref, String identity})>{};
  final _refsUsed = <String>{};
  var _semanticsIds = <String, int>{};
  var _nextRef = 0;

  int _freshRef() {
    while (_refsUsed.contains('s${++_nextRef}')) {}
    return _nextRef;
  }

  /// The app's element list as text.
  Future<String> snapshot() async {
    final nodes = await tree();
    return appTreeText(
      'App: Flutter (view ${width.round()}×${height.round()} logical px)',
      nodes,
      width: width,
      height: height,
    );
  }

  AppNode _node(String ref) {
    final n = _nodes[ref];
    if (n == null) throw AppError('No element $ref in the app now: take a new snapshot.');
    return n;
  }

  /// Taps element [ref]: its semantics tap when it has one, else a pointer tap at its centre.
  Future<String> tap(String ref) async {
    await tree();
    final n = _node(ref);
    _report('click', n);
    if (n.actions.contains('tap')) {
      await _act(ref, 'tap');
    } else if (n.placed) {
      await _pointerTap(n.centreX, n.centreY);
    } else {
      throw AppError('$ref has no place on screen and no tap action.');
    }
    return 'Tapped $ref ${n.role}${n.name.isEmpty ? '' : ' "${n.name}"'}.';
  }

  /// Performs semantics [action] on [ref] (an argument as Dart source).
  Future<void> _act(String ref, String action, [String? argument]) => _inFrame(
    _rendering!,
    '$_owner.performAction(${_id(ref)}, SemanticsAction.$action${argument == null ? '' : ', $argument'});',
  );

  /// Runs Dart statements [body] (in library [target]) right after the app's next frame, the way input arrives:
  /// layout is clean then, and an error lands in the app's log instead of breaking the evaluation half-way (a
  /// text field left mid-edit). Wait with [settle].
  Future<void> _inFrame(String target, String body) => _eval(
    target,
    '(() { SchedulerBinding.instance.addPostFrameCallback((_) { $body }); '
    'SchedulerBinding.instance.scheduleFrame(); return "ok"; })()',
  );

  /// A tap at ([x], [y]) in logical pixels.
  Future<String> tapAt(double x, double y) async {
    await _ready();
    control.report(LiveActivity('click', x: x, y: y, caption: 'Tapping'));
    // What was there when the agent tapped.
    final hit = _hit(await tree(), x, y);
    await _pointerTap(x, y);
    final on = hit == null
        ? ''
        : ' on ${hit.ref.isEmpty ? '' : '${hit.ref} '}${hit.role}${hit.name.isEmpty ? '' : ' "${hit.name}"'}';
    return 'Tapped at (${x.round()}, ${y.round()})$on.';
  }

  /// The smallest element holding ([x], [y]).
  static AppNode? _hit(List<AppNode> nodes, double x, double y) {
    AppNode? best;
    for (final n in nodes) {
      if (!n.placed || x < n.left! || x > n.right! || y < n.top! || y > n.bottom!) continue;
      final area = (n.right! - n.left!) * (n.bottom! - n.top!);
      if (best == null || area < (best.right! - best.left!) * (best.bottom! - best.top!)) best = n;
    }
    return best;
  }

  Future<void> _pointerTap(double x, double y) async {
    final p = ++_pointer;
    final at = _offset(x, y);
    await _inFrame(
      _rendering!,
      'GestureBinding.instance.handlePointerEvent(PointerDownEvent(pointer: $p, position: $at)); '
      'GestureBinding.instance.handlePointerEvent(PointerUpEvent(pointer: $p, position: $at));',
    );
  }

  static String _offset(double x, double y) => 'Offset(${x.toStringAsFixed(1)}, ${y.toStringAsFixed(1)})';

  /// A press held at ([x], [y]) for [hold], or dragged from there to ([toX], [toY]) over [hold] (swipes,
  /// sliders, dismissing).
  Future<void> _pointerPath(double x, double y, {double? toX, double? toY, required Duration hold}) async {
    final p = ++_pointer;
    await _inFrame(
      _rendering!,
      'GestureBinding.instance.handlePointerEvent(PointerDownEvent(pointer: $p, position: ${_offset(x, y)}));',
    );
    const steps = 8;
    for (var i = 1; i <= steps; i++) {
      await Future<void>.delayed(hold ~/ steps);
      if (toX == null || toY == null) continue;
      final cx = x + (toX - x) * i / steps, cy = y + (toY - y) * i / steps;
      final dx = (toX - x) / steps, dy = (toY - y) / steps;
      await _inFrame(
        _rendering!,
        'GestureBinding.instance.handlePointerEvent(PointerMoveEvent(pointer: $p, position: ${_offset(cx, cy)}, '
        'delta: ${_offset(dx, dy)}));',
      );
    }
    await _inFrame(
      _rendering!,
      'GestureBinding.instance.handlePointerEvent(PointerUpEvent(pointer: $p, position: ${_offset(toX ?? x, toY ?? y)}));',
    );
  }

  /// Long-presses [ref]: its semantics long press, else a held pointer at its centre.
  Future<String> longPress(String ref) async {
    await tree();
    final n = _node(ref);
    _report('click', n);
    if (n.actions.contains('longPress')) {
      await _act(ref, 'longPress');
    } else if (n.placed) {
      await _pointerPath(n.centreX, n.centreY, hold: const Duration(milliseconds: 700));
    } else {
      throw AppError('$ref has no place on screen and no long-press action.');
    }
    return 'Long-pressed $ref ${n.role}${n.name.isEmpty ? '' : ' "${n.name}"'}.';
  }

  /// Drags from ([x], [y]) to ([toX], [toY]) in logical pixels.
  Future<String> drag(double x, double y, double toX, double toY) async {
    await _ready();
    control.report(LiveActivity('click', x: x, y: y, caption: 'Dragging'));
    await _pointerPath(x, y, toX: toX, toY: toY, hold: const Duration(milliseconds: 300));
    return 'Dragged from (${x.round()}, ${y.round()}) to (${toX.round()}, ${toY.round()}).';
  }

  /// Moves slider (or other adjustable) [ref] by [steps] of its own step (negative: down).
  Future<String> adjust(String ref, int steps) async {
    await tree();
    final n = _node(ref);
    final action = steps >= 0 ? 'increase' : 'decrease';
    if (!n.actions.contains(action)) throw AppError("$ref can't be adjusted (it has no $action action).");
    _report('click', n);
    for (var i = 0; i < steps.abs().clamp(1, 50); i++) {
      await _act(ref, action);
      await settle(limit: const Duration(milliseconds: 300));
    }
    return 'Adjusted $ref ${n.role}${n.name.isEmpty ? '' : ' "${n.name}"'} by $steps step(s).';
  }

  /// Puts [text] in text field [ref] (replacing what it held), and submits it with [submit]: focuses the field,
  /// then edits it the way the keyboard does (the field's own editing path, so onChanged and formatters run), and
  /// checks the field holds the text afterwards.
  Future<String> type(String ref, String text, {bool submit = false}) async {
    await tree();
    var n = _node(ref);
    if (n.secret) {
      throw AppError(
        '$ref is a password field: the agent never types into one. Ask the user to type it (or use a test '
        'account the app fills in itself).',
      );
    }
    if (n.role != 'textbox') throw AppError('$ref is a ${n.role}, not a text field.');
    _report('type', n);
    if (!n.state.contains('focused')) {
      if (n.actions.contains('tap')) {
        await _act(ref, 'tap');
      } else if (n.actions.contains('focus')) {
        await _act(ref, 'focus');
      } else if (n.placed) {
        await _pointerTap(n.centreX, n.centreY);
      }
      // A field that just appeared takes the focus a frame or two later.
      for (var i = 0; i < 8; i++) {
        await settle();
        await tree();
        n = _node(ref);
        if (n.state.contains('focused') || n.actions.contains('setText')) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    final editing = _widgets != null && n.state.contains('focused') && await _hasFocusedField();
    if (editing) {
      await _inFrame(
        _widgets!,
        'final s = FocusManager.instance.primaryFocus?.context?.findAncestorStateOfType<EditableTextState>(); '
        'if (s != null) { final t = ${dartString(text)}; s.userUpdateTextEditingValue(TextEditingValue(text: t, '
        'selection: TextSelection.collapsed(offset: t.length)), SelectionChangedCause.keyboard); }',
      );
    } else if (n.actions.contains('setText')) {
      await _act(ref, 'setText', dartString(text));
    } else {
      throw AppError("$ref doesn't take text (read-only, disabled, or it didn't take the focus).");
    }
    // The field's semantics catch up a frame or two after the edit.
    AppNode? now;
    for (var i = 0; i < 8; i++) {
      await settle();
      await tree();
      now = _nodes[ref];
      if (now == null || (now.value ?? '') != (n.value ?? '')) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (now == null) throw AppError('$ref went away while typing into it: take a new snapshot.');
    final held = now.value ?? '';
    if (held != text) {
      if (held == (n.value ?? '')) {
        throw AppError(
          "Typing into $ref didn't change it: it still holds \"$held\". (The field may be read-only, "
          'or the app rejected the text.)',
        );
      }
    }
    if (submit) await this.submit();
    final shown = held == text ? '' : ' (the field shows "$held": the app changed what was typed)';
    return 'Typed into $ref${n.name.isEmpty ? '' : ' "${n.name}"'}$shown${submit ? ' and submitted' : ''}.';
  }

  Future<bool> _hasFocusedField() async =>
      await _eval(
        _widgets!,
        '(FocusManager.instance.primaryFocus?.context?.findAncestorStateOfType<EditableTextState>() != null)'
        '.toString()',
      ) ==
      'true';

  /// Sends the focused text field's action (done, search, go: what the keyboard's action key would).
  Future<String> submit() async {
    await _ready();
    if (_widgets == null) throw const AppError('This app has no text fields to submit.');
    if (!await _hasFocusedField()) throw const AppError('No text field has the focus: type into one first.');
    await _inFrame(
      _widgets!,
      'final s = FocusManager.instance.primaryFocus?.context?.findAncestorStateOfType<EditableTextState>(); '
      'if (s != null) s.performAction(s.widget.textInputAction ?? TextInputAction.done);',
    );
    return 'Submitted the focused field.';
  }

  /// The system back (Android's back button; pops the top route).
  Future<String> back() async {
    await _ready();
    if (_widgets == null) throw const AppError("Can't reach the app's navigator.");
    await _inFrame(_widgets!, 'WidgetsBinding.instance.handlePopRoute();');
    return 'Went back.';
  }

  /// Scrolls by [dy] logical pixels (positive: down) with a mouse wheel over [ref], or at ([x], [y]), or the view's
  /// centre.
  Future<String> scroll(double dy, {String? ref, double? x, double? y}) async {
    await tree();
    var px = x ?? width / 2, py = y ?? height / 2;
    if (ref != null) {
      final n = _node(ref);
      if (!n.placed) throw AppError('$ref has no place on screen.');
      px = n.centreX;
      py = n.centreY;
    }
    control.report(LiveActivity('scroll', x: px, y: py, caption: 'Scrolling'));
    await _inFrame(
      _rendering!,
      'GestureBinding.instance.handlePointerEvent(PointerScrollEvent(position: ${_offset(px, py)}, '
      'scrollDelta: Offset(0, ${dy.toStringAsFixed(1)})));',
    );
    return 'Scrolled ${dy >= 0 ? 'down' : 'up'} ${dy.abs().round()} px at (${px.round()}, ${py.round()}).';
  }

  /// A picture of [region] of the view (null: all of it), sized for the model, and the frame it is recorded as.
  Future<(List<int>, AgentFrame)> frameShot({ViewRect? region}) async {
    await tree();
    if (width <= 0 || height <= 0) throw const AppError('The app has no view to picture yet.');
    final r = region ?? (left: 0.0, top: 0.0, width: width, height: height);
    final scale = region == null ? 1.0 : 2.0;
    final size = agentImageSize(r.width, r.height, scale: scale);
    // The whole view, then cut and sized.
    final (png, ratio) = await _viewShot(size.width / r.width);
    final f = frames.record(imageWidth: size.width, imageHeight: size.height, geometry: geometry, region: region);
    if (region == null && png.isNotEmpty) {
      final fitted = await Isolate.run(() => _fit(png, size.width, size.height, null));
      return (fitted, f);
    }
    final crop = (
      x: (r.left * ratio).round(),
      y: (r.top * ratio).round(),
      w: (r.width * ratio).round(),
      h: (r.height * ratio).round(),
    );
    return (await Isolate.run(() => _fit(png, size.width, size.height, crop)), f);
  }

  static List<int> _fit(List<int> png, int w, int h, ({int x, int y, int w, int h})? crop) {
    var image = img.decodePng(Uint8List.fromList(png));
    if (image == null) return png;
    if (crop != null) image = img.copyCrop(image, x: crop.x, y: crop.y, width: crop.w, height: crop.h);
    if (image.width != w || image.height != h) image = img.copyResize(image, width: w, height: h);
    return img.encodePng(image);
  }

  /// A picture of the whole view and its pixels per logical pixel: the engine's own (the last frame, every layer),
  /// else the widget inspector's at [ratio].
  Future<(List<int>, double)> _viewShot(double ratio) async {
    try {
      final r = await _call('_flutter.screenshot');
      if (r['screenshot'] case final String data when data.isNotEmpty) return (base64Decode(data), pixelRatio);
    } on AppError {
      // An embedder without it: the inspector.
    }
    return (await _inspectorShot(ratio), ratio);
  }

  Future<List<int>> _inspectorShot(double ratio) async {
    final root = await _call('ext.flutter.inspector.getRootWidget', {'isolateId': _isolate, 'objectGroup': 'everyai'});
    final id = (root['result'] as Map?)?['valueId'];
    if (id == null) throw const AppError('The app has no root widget yet.');
    final shot = await _call('ext.flutter.inspector.screenshot', {
      'isolateId': _isolate,
      'id': id,
      'width': '${(width * ratio).round()}',
      'height': '${(height * ratio).round()}',
      'maxPixelRatio': '$ratio',
    });
    final data = shot['result'];
    if (data is! String || data.isEmpty) throw const AppError("The app couldn't take a picture of itself.");
    return base64Decode(data);
  }

  /// A picture of the whole view for the Preview, at most [maxWidth] pixels wide; not recorded as an agent frame.
  /// Reads the view's size again every [sizeEvery]th call (the window may have been resized).
  Future<List<int>> previewShot({double maxWidth = 1000, int sizeEvery = 5}) async {
    await _ready();
    if (width <= 0 || ++_previewShots % sizeEvery == 0) await tree();
    if (width <= 0) throw const AppError('The app has no view to picture yet.');
    final (png, _) = await _viewShot((maxWidth / width).clamp(0.1, pixelRatio));
    return png;
  }

  var _previewShots = 0;

  /// The user's tap in the Preview at ([x], [y]), logical pixels.
  Future<void> userTap(double x, double y) async {
    await _ready();
    await _pointerTap(x, y);
  }

  /// The user's mouse wheel in the Preview: [dy] logical pixels at ([x], [y]).
  Future<void> userScroll(double x, double y, double dy) async {
    await _ready();
    await _inFrame(
      _rendering!,
      'GestureBinding.instance.handlePointerEvent(PointerScrollEvent(position: ${_offset(x, y)}, '
      'scrollDelta: Offset(0, ${dy.toStringAsFixed(1)})));',
    );
  }

  /// Hot reload ([restart]: hot restart), through the services `flutter run` registered.
  Future<String> reload({bool restart = false}) async {
    await _connect();
    final service = restart ? 'hotRestart' : 'reloadSources';
    // Registrations arrive as events right after the stream is joined.
    for (var i = 0; i < 10 && !_services.containsKey(service); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final method = _services[service];
    if (method == null) {
      throw AppError(
        'Hot ${restart ? 'restart' : 'reload'} needs the app to run under `flutter run` (or `flutter attach`); '
        'this VM service has no such service.',
      );
    }
    await _ready();
    final Map<String, Object?> r;
    try {
      r = await _call(method, {'isolateId': _isolate});
    } on AppError catch (e) {
      throw AppError('Hot ${restart ? 'restart' : 'reload'} failed: ${e.message}', fromApp: true);
    }
    if (restart) {
      _resetIsolate();
      // What the app printed before belongs to the old run.
      _log.clear();
      _logged.clear();
    }
    if (r['success'] == false || r['type'] == 'ReloadReport' && r['success'] != true) {
      final notices = [
        for (final n in ((r['notices'] as List?) ?? (r['details'] as Map?)?['notices'] as List? ?? const []))
          '${(n as Map)['message'] ?? n}',
      ];
      throw AppError('Hot reload was rejected:\n${notices.join('\n')}', fromApp: true);
    }
    // The reassembled frame.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return restart ? 'Hot restarted the app (its state is reset).' : 'Hot reloaded the app (its state is kept).';
  }

  /// Evaluates Dart [expression] in the app's main library and returns its `toString()`.
  Future<String> evaluate(String expression) async {
    await _ready();
    final target = _rootLib ?? _rendering!;
    return _eval(target, '(${oneLineDart(expression)}).toString()');
  }

  void _report(String kind, AppNode n) => control.report(
    LiveActivity(
      kind,
      x: n.placed ? n.centreX : null,
      y: n.placed ? n.centreY : null,
      caption: '${kind == 'type' ? 'Typing into' : 'Tapping'} ${n.name.isEmpty ? n.role : n.name}',
    ),
  );

  /// Waits until the app has drawn what the last action changed: no frame scheduled and no animation running (up to
  /// [limit]).
  Future<void> settle({Duration limit = const Duration(milliseconds: 800)}) async {
    await _ready();
    final end = DateTime.now().add(limit);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    while (DateTime.now().isBefore(end)) {
      final busy = await _evalRendering(
        '(SchedulerBinding.instance.hasScheduledFrame || SchedulerBinding.instance.transientCallbackCount > 0)'
        '.toString()',
      );
      if (busy != 'true') return;
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
  }

  /// What visibly changed since the tree before the last action (call [tree] after it).
  String? changedSince(List<AppNode> before) => appTreeChange(before, _last, width: width, height: height);

  List<AppNode> get lastTree => _last;

  int _id(String ref) => _semanticsIds[ref] ?? -1;

  Future<void> close() async {
    final ws = _ws;
    _ws = null;
    _resetIsolate();
    await ws?.close();
  }
}

/// One row of the tree expression ([f]: id, left, top, right, bottom, label, value, hint, tooltip, flags,
/// actions; physical pixels) as a node in logical pixels, or null for a node with nothing to show or do.
AppNode? flutterNode(List<String> f, double pixelRatio) {
  final flags = f[9].isEmpty ? const <String>{} : f[9].split(',').toSet();
  final actions = f[10].isEmpty ? const <String>{} : f[10].split(',').toSet();
  if (flags.contains('isHidden')) return null;
  double px(String s) => (double.tryParse(s) ?? 0) / pixelRatio;
  final label = f[5].trim(), value = f[6].trim(), hint = f[7].trim(), tooltip = f[8].trim();
  final scrolls = actions.any((a) => a.startsWith('scroll'));
  final acts = actions.difference({'showOnScreen', 'didGainAccessibilityFocus', 'didLoseAccessibilityFocus'});
  if (label.isEmpty && value.isEmpty && tooltip.isEmpty && acts.isEmpty && !flags.contains('isTextField')) {
    return null;
  }
  final role = flags.contains('isLiveRegion') && !flags.contains('isTextField') && !acts.contains('tap')
      ? 'status'
      : flags.contains('isTextField')
      ? 'textbox'
      : flags.contains('isSlider')
      ? 'slider'
      : flags.contains('hasCheckedState')
      ? (flags.contains('isInMutuallyExclusiveGroup') ? 'radio' : 'checkbox')
      : flags.contains('hasToggledState')
      ? 'switch'
      : flags.contains('isLink')
      ? 'link'
      : flags.contains('isButton')
      ? 'button'
      : flags.contains('isHeader')
      ? 'heading'
      : flags.contains('isImage')
      ? 'img'
      : acts.contains('tap') || acts.contains('longPress')
      ? 'button'
      : scrolls && label.isEmpty
      ? 'scrollable'
      : 'text';
  final state = [
    if (flags.contains('isChecked') || flags.contains('isToggled'))
      'checked'
    else if (flags.contains('hasCheckedState') || flags.contains('hasToggledState'))
      'unchecked',
    if (flags.contains('hasEnabledState') && !flags.contains('isEnabled')) 'disabled',
    if (flags.contains('isSelected')) 'selected',
    if (flags.contains('isFocused')) 'focused',
    if (flags.contains('isExpanded')) 'expanded',
    if (flags.contains('isRequired')) 'required',
    if (flags.contains('isReadOnly')) 'read-only',
  ];
  final name = [
    label,
    if (tooltip.isNotEmpty && tooltip != label) tooltip,
    if (role == 'textbox' && hint.isNotEmpty) hint,
  ].where((s) => s.isNotEmpty).join(' · ');
  // Plain text without a ref (nothing to act on); controls and scrollables get one.
  final acting = role != 'text' || acts.isNotEmpty;
  return AppNode(
    ref: acting ? 's${f[0]}' : '',
    role: role,
    name: name,
    value: value.isEmpty ? null : value,
    state: state,
    left: px(f[1]),
    top: px(f[2]),
    right: px(f[3]),
    bottom: px(f[4]),
    actions: actions,
    secret: flags.contains('isObscured'),
  );
}
