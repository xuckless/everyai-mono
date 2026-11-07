// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'app_view.dart';
import 'live_session.dart';

/// A React Native app in development, reached through Metro ([metro], `http://127.0.0.1:8081`): the JavaScript
/// runtime's Chrome DevTools Protocol target that Metro proxies (Hermes).
///
/// - The element list walks React's fiber tree (through the DevTools hook RN installs in development): pressables,
///   text inputs, switches and text, named by their accessibility label, test id or text. No places on screen: the
///   picture comes from the simulator or emulator the app runs in.
/// - Tap calls the element's own `onPress`, type its `onChangeText` (never a `secureTextEntry` field).
/// - The log is the console and uncaught errors; eval runs JavaScript in the app; reload reloads the bundle.
final class ReactNativeApp {
  ReactNativeApp(this.metro);

  final Uri metro;

  /// Who drives the app, and the agent's actions for the Preview's caption.
  final control = LiveControl();

  // Closed in close().
  // ignore: close_sinks
  WebSocket? _ws;
  var _nextId = 0;
  final _calls = <int, Completer<Map<String, Object?>>>{};
  final _log = <String>[];
  final _logged = <String>[];
  List<AppNode> _last = const [];
  var _nodes = <String, AppNode>{};

  /// The target's name (`React Native Bridgeless [C++ connection]`).
  String title = '';

  bool get connected => _ws != null;

  Future<void> _connect() async {
    if (_ws != null) return;
    final List<Object?> targets;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final req = await client.getUrl(metro.replace(path: '/json/list'));
      final res = await req.close().timeout(const Duration(seconds: 5));
      targets = jsonDecode(await res.transform(utf8.decoder).join()) as List<Object?>;
    } on Object catch (e) {
      throw AppError("Can't reach Metro at $metro (is the dev server running?): $e");
    } finally {
      client.close(force: true);
    }
    final pages = [
      for (final t in targets)
        if (t is Map && t['webSocketDebuggerUrl'] is String) t.cast<String, Object?>(),
    ];
    // The newest app connection; Hermes (or RN's own) targets first.
    pages.sort((a, b) => (_isRn(a) ? 0 : 1) - (_isRn(b) ? 0 : 1));
    final pick = pages.where(_isRn).lastOrNull ?? pages.lastOrNull;
    if (pick == null) {
      throw const AppError(
        'Metro is running but no app is connected to it: open the app in the simulator or emulator (or reload it).',
      );
    }
    title = '${pick['title'] ?? pick['description'] ?? 'React Native'}';
    var url = pick['webSocketDebuggerUrl']! as String;
    // Metro writes `localhost`; reach it at the host we reached Metro at.
    final u = Uri.parse(url);
    url = u.replace(host: metro.host).toString();
    final ws = await WebSocket.connect(url).timeout(const Duration(seconds: 5));
    _ws = ws;
    ws.listen(_onMessage, onDone: () => _closed(ws), onError: (Object _) => _closed(ws));
    await _send('Runtime.enable').timeout(const Duration(seconds: 5), onTimeout: () => const {});
  }

  static bool _isRn(Map<String, Object?> t) =>
      t['reactNative'] != null || '${t['vm']}'.contains('Hermes') || '${t['title']}'.contains('React Native');

  void _closed(WebSocket ws) {
    if (!identical(_ws, ws)) return;
    _ws = null;
    for (final c in _calls.values) {
      if (!c.isCompleted) c.completeError(const AppError('The app disconnected from Metro (reloaded or stopped).'));
    }
    _calls.clear();
  }

  void _onMessage(Object? data) {
    if (data is! String) return;
    final Map<String, Object?> msg;
    try {
      msg = (jsonDecode(data) as Map).cast();
    } on Object {
      return;
    }
    if (msg['id'] case final num id) {
      final c = _calls.remove(id.toInt());
      if (c == null) return;
      if (msg['error'] case final Map<Object?, Object?> e) {
        c.completeError(AppError('${e['message']}'));
      } else {
        c.complete(((msg['result'] as Map?) ?? const {}).cast());
      }
      return;
    }
    final p = (msg['params'] as Map?)?.cast<String, Object?>() ?? const {};
    switch (msg['method']) {
      case 'Runtime.consoleAPICalled':
        final args = [
          for (final a in (p['args'] as List?) ?? const [])
            if (a is Map) '${a['value'] ?? a['description'] ?? a['unserializableValue'] ?? ''}',
        ];
        _add('console.${p['type']}: ${args.join(' ')}');
      case 'Runtime.exceptionThrown':
        final d = (p['exceptionDetails'] as Map?)?.cast<String, Object?>();
        _add('Uncaught: ${(d?['exception'] as Map?)?['description'] ?? d?['text'] ?? ''}');
    }
  }

  void _add(String line) {
    _log.add(line.length > 2000 ? '${line.substring(0, 2000)}…' : line);
    if (_log.length > 200) _log.removeRange(0, _log.length - 200);
  }

  List<String> takeLog() {
    final out = [..._log];
    _logged.addAll(out);
    if (_logged.length > 50) _logged.removeRange(0, _logged.length - 50);
    _log.clear();
    return out;
  }

  List<String> get history => [..._logged, ..._log];

  Future<Map<String, Object?>> _send(String method, [Map<String, Object?> params = const {}]) {
    final ws = _ws;
    if (ws == null) return Future.error(const AppError('Not connected to the app.'));
    final id = ++_nextId;
    final c = _calls[id] = Completer();
    ws.add(jsonEncode({'id': id, 'method': method, 'params': params}));
    return c.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        _calls.remove(id);
        throw AppError("The app didn't answer $method in 20 s (paused in the debugger?).");
      },
    );
  }

  Future<Object?> _evaluate(String script) async {
    await _connect();
    final r = await _send('Runtime.evaluate', {'expression': script, 'returnByValue': true});
    if (r['exceptionDetails'] case final Map<String, Object?> d) {
      final ex = d['exception'] as Map<String, Object?>?;
      throw AppError('The script threw: ${ex?['description'] ?? d['text']}', fromApp: true);
    }
    return (r['result'] as Map?)?['value'];
  }

  /// The app's element list now.
  Future<List<AppNode>> tree() async {
    final v = await _evaluate('$reactNativeTreeJs\n__everyaiRNList()');
    if (v is Map && v['error'] == 'nohook') {
      throw const AppError(
        "The app has no React DevTools hook (a release build?): its elements can't be listed. Use the simulator's "
        'or emulator\'s screen instead; logs, eval and reload still work.',
      );
    }
    final nodes = [
      for (final i in (v is Map ? v['items'] as List? : null) ?? const [])
        if (i is Map) reactNativeNode(i.cast()),
    ];
    _last = nodes;
    _nodes = {for (final n in nodes) n.ref: n};
    return nodes;
  }

  Future<String> snapshot() async => appTreeText('App: React Native ($title)', await tree());

  List<AppNode> get lastTree => _last;

  AppNode _node(String ref) {
    final n = _nodes[ref];
    if (n == null) throw AppError('No element $ref in the app now: take a new snapshot.');
    return n;
  }

  /// Calls [ref]'s handler for [action] (`press`, `text`, `submit`, `toggle`) with [arg].
  Future<String> _act(String ref, String action, [String? arg]) async {
    final v = await _evaluate(
      '$reactNativeTreeJs\n__everyaiRNAct(${jsonEncode(ref)}, ${jsonEncode(action)}, ${jsonEncode(arg)})',
    );
    if (v is String && v.startsWith('error:')) throw AppError(v.substring(6).trim());
    return '$v';
  }

  Future<String> tap(String ref) async {
    await tree();
    final n = _node(ref);
    control.report(LiveActivity('click', caption: 'Tapping ${n.name.isEmpty ? n.role : n.name}'));
    await _act(ref, n.role == 'switch' ? 'toggle' : 'press');
    return 'Tapped $ref ${n.role}${n.name.isEmpty ? '' : ' "${n.name}"'}.';
  }

  Future<String> longPress(String ref) async {
    await tree();
    final n = _node(ref);
    control.report(LiveActivity('click', caption: 'Long-pressing ${n.name.isEmpty ? n.role : n.name}'));
    await _act(ref, 'long');
    return 'Long-pressed $ref ${n.role}${n.name.isEmpty ? '' : ' "${n.name}"'}.';
  }

  Future<String> type(String ref, String text, {bool submit = false}) async {
    await tree();
    final n = _node(ref);
    if (n.secret) {
      throw AppError('$ref is a password field: the agent never types into one. Ask the user to type it.');
    }
    if (n.role != 'textbox') throw AppError('$ref is a ${n.role}, not a text input.');
    control.report(LiveActivity('type', caption: 'Typing into ${n.name.isEmpty ? 'a field' : n.name}'));
    await _act(ref, 'text', text);
    if (submit) await _act(ref, 'submit', text);
    return 'Typed into $ref${n.name.isEmpty ? '' : ' "${n.name}"'}${submit ? ' and submitted' : ''}.';
  }

  /// Gives React time to render what the last action changed.
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 250));

  /// Reloads the JavaScript bundle (the app's state is lost; Fast Refresh already applies saved edits).
  Future<String> reload() async {
    await _connect();
    try {
      await _send('Page.reload');
    } on AppError {
      // Older RN: Metro's own reload, sent to every connected app.
      final client = HttpClient();
      try {
        final req = await client.postUrl(metro.replace(path: '/reload'));
        await (await req.close()).drain<void>();
      } on Object catch (e) {
        throw AppError('Metro would not reload the app: $e');
      } finally {
        client.close(force: true);
      }
    }
    // The old connection ends with the bundle; the next call connects again.
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    return 'Reloaded the app (its state is reset).';
  }

  /// Runs JavaScript [script] in the app; its value as JSON.
  Future<String> evaluate(String script) async => const JsonEncoder.withIndent('  ').convert(await _evaluate(script));

  String? changedSince(List<AppNode> before) => appTreeChange(before, _last);

  Future<void> close() async {
    final ws = _ws;
    _ws = null;
    await ws?.close();
  }
}

/// One item of the fiber walk (`{ref, role, name, value?, state, secret?}`) as a node.
AppNode reactNativeNode(Map<String, Object?> i) => AppNode(
  ref: '${i['ref'] ?? ''}',
  role: '${i['role'] ?? 'text'}',
  name: '${i['name'] ?? ''}',
  value: i['value'] as String?,
  state: [for (final s in (i['state'] as List?) ?? const []) '$s'],
  secret: i['secret'] == true,
);

/// JavaScript (ES5, for Hermes) that defines `__everyaiRNList()`, walking React's committed fiber trees through
/// `__REACT_DEVTOOLS_GLOBAL_HOOK__` into `{items:[{ref, role, name, value?, state, secret?}]}` (or `{error:'nohook'}`),
/// and `__everyaiRNAct(ref, action, arg)`, which walks again (so handlers are the committed ones, not stale closures)
/// and calls the element's handler. An element keeps its ref across walks.
const reactNativeTreeJs = r'''
(function (g) {
  if (g.__everyaiRNList) return;
  function roots() {
    var hook = g.__REACT_DEVTOOLS_GLOBAL_HOOK__;
    if (!hook || typeof hook.getFiberRoots !== 'function') return null;
    var out = [], ids = [];
    if (hook.renderers && hook.renderers.forEach) hook.renderers.forEach(function (_, id) { ids.push(id); });
    if (!ids.length) ids = [1, 2, 3];
    ids.forEach(function (id) {
      var set = hook.getFiberRoots(id);
      if (set && set.forEach) set.forEach(function (r) { out.push(r); });
    });
    return out;
  }
  var ids = g.__everyaiRNIds || (g.__everyaiRNIds = new WeakMap());
  function refOf(f) {
    var r = ids.get(f) || (f.alternate && ids.get(f.alternate));
    if (!r) { g.__everyaiRNNext = (g.__everyaiRNNext || 0) + 1; r = 'r' + g.__everyaiRNNext; }
    ids.set(f, r);
    if (f.alternate) ids.set(f.alternate, r);
    return r;
  }
  function textOf(f) {
    var s = '';
    (function walk(c) {
      for (; c; c = c.sibling) {
        if (c.tag === 6) s += ' ' + c.memoizedProps;
        else walk(c.child);
      }
    })(f.child);
    return s.replace(/\s+/g, ' ').trim();
  }
  function fn(x) { return typeof x === 'function'; }
  function nameOf(f, p) {
    return String(p.accessibilityLabel || p['aria-label'] || p.title || textOf(f) || p.placeholder || p.testID || '')
      .replace(/\s+/g, ' ').trim().slice(0, 160);
  }
  function stateOf(p) {
    var a = p.accessibilityState || {}, s = [];
    if (p.disabled || a.disabled || p.editable === false) s.push('disabled');
    if (a.checked === true || p.value === true) s.push('checked');
    if (a.selected || p.selected) s.push('selected');
    if (a.expanded) s.push('expanded');
    return s;
  }
  function walk() {
    var rs = roots();
    if (!rs) return null;
    var items = [], refs = new Map();
    function visit(f, inside) {
      for (; f; f = f.sibling) {
        if (items.length >= 400) return;
        var p = f.memoizedProps, item = null, descend = true;
        var composite = f.tag === 0 || f.tag === 1 || f.tag === 11 || f.tag === 14 || f.tag === 15;
        if (p && typeof p === 'object' && !inside) {
          if (composite && (fn(p.onChangeText) || (fn(p.onChange) && 'secureTextEntry' in p))) {
            item = {role: 'textbox', name: String(p.accessibilityLabel || p.placeholder || p.testID || '').slice(0, 160),
              state: stateOf(p), secret: !!p.secureTextEntry};
            if (!p.secureTextEntry && (p.value != null || p.defaultValue != null)) item.value = String(p.value != null ? p.value : p.defaultValue).slice(0, 200);
          } else if (composite && fn(p.onValueChange) && typeof p.value === 'boolean') {
            item = {role: 'switch', name: nameOf(f, p), state: stateOf(p)};
          } else if (composite && (fn(p.onPress) || fn(p.onLongPress))) {
            item = {role: p.accessibilityRole === 'link' ? 'link' : 'button', name: nameOf(f, p), state: stateOf(p)};
          }
          if (item) { item.ref = refOf(f); refs.set(item.ref, f); items.push(item); descend = false; }
        }
        if (!item && !inside) {
          if (f.tag === 5 && typeof f.type === 'string' && /Text$/.test(f.type) && !/Input/.test(f.type)) {
            var t = textOf(f);
            if (t) items.push({ref: '', role: 'text', name: t.slice(0, 160), state: []});
            descend = false;
          } else if (f.tag === 6 && String(f.memoizedProps).trim()) {
            items.push({ref: '', role: 'text', name: String(f.memoizedProps).trim().slice(0, 160), state: []});
          }
        }
        if (descend) visit(f.child, inside);
      }
    }
    rs.forEach(function (r) { if (r.current) visit(r.current.child, false); });
    return {items: items, refs: refs};
  }
  g.__everyaiRNList = function () {
    var w = walk();
    return w ? {items: w.items} : {error: 'nohook'};
  };
  g.__everyaiRNAct = function (ref, action, arg) {
    var w = walk();
    if (!w) return 'error: no React DevTools hook';
    var f = w.refs.get(ref);
    if (!f) return 'error: No element ' + ref + ' in the app now: take a new snapshot.';
    var p = f.memoizedProps || {};
    var ev = {nativeEvent: {text: arg}, persist: function () {}, preventDefault: function () {}, stopPropagation: function () {}};
    if (action === 'press') {
      if (p.disabled) return 'error: ' + ref + ' is disabled.';
      (fn(p.onPress) ? p.onPress : p.onLongPress)(ev);
    } else if (action === 'long') {
      if (!fn(p.onLongPress)) return 'error: ' + ref + ' has no long-press handler (onLongPress).';
      p.onLongPress(ev);
    } else if (action === 'toggle') {
      p.onValueChange(!p.value);
    } else if (action === 'text') {
      if (p.secureTextEntry) return 'error: a password field';
      if (fn(p.onChangeText)) p.onChangeText(arg);
      if (fn(p.onChange)) p.onChange(ev);
    } else if (action === 'submit') {
      if (!fn(p.onSubmitEditing)) return 'error: ' + ref + ' has no submit handler (onSubmitEditing).';
      p.onSubmitEditing(ev);
    }
    return 'ok';
  };
})(globalThis);
''';
