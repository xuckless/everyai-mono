// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';
import 'dart:io';

import 'screen_windows.dart';

/// Max elements read from a window, how deep, and how long the text may be.
const axMaxNodes = 400;
const axMaxDepth = 8;
const axMaxChars = 8000;

const _permissionNote =
    'Accessibility data off: allow EveryAI under System Settings > Privacy & Security > Accessibility.';
const _unavailableNote = 'Accessibility data not available.';

/// Roles that only group things: dropped when they have no label or value, their children stay.
const _noiseRoles = {'AXGroup', 'AXUnknown', 'AXSplitter', 'AXSplitGroup', 'AXScrollArea'};

/// Runs a JXA script for the accessibility tree (a fake in tests).
typedef AxRunner = Future<({int exitCode, String stdout, String stderr})> Function(String script);

/// Runs a JXA [script] through osascript; killed after 10 s.
Future<({int exitCode, String stdout, String stderr})> osascriptRunner(String script) async {
  final p = await Process.start('osascript', ['-l', 'JavaScript', '-e', script]);
  final out = utf8.decodeStream(p.stdout);
  final err = utf8.decodeStream(p.stderr);
  try {
    final code = await p.exitCode.timeout(const Duration(seconds: 10));
    return (exitCode: code, stdout: await out, stderr: await err);
  } on Object {
    p.kill(ProcessSignal.sigkill);
    return (exitCode: -1, stdout: '', stderr: 'timed out');
  }
}

/// The accessibility tree of window [w] as compact text, or a one-line note on why there is none. macOS
/// (System Events); the caller still returns the picture either way.
Future<String> windowAxTree(ScreenWindow w, {AxRunner run = osascriptRunner}) async {
  try {
    final res = await run(axScript(w));
    if (res.exitCode != 0) {
      return RegExp(r'assistive access|-25211|\b1002\b|-1719').hasMatch(res.stderr)
          ? _permissionNote
          : _unavailableNote;
    }
    final data = jsonDecode(res.stdout.trim());
    if (data is! Map) return _unavailableNote;
    final nodes = [
      for (final n in (data['nodes'] as List<Object?>? ?? const []))
        if (n is Map) n,
    ];
    if (nodes.isEmpty) return _unavailableNote;
    return formatAxTree(nodes, originX: (data['x'] as num?)?.toInt() ?? 0, originY: (data['y'] as num?)?.toInt() ?? 0);
  } on Object {
    return _unavailableNote;
  }
}

/// The JXA that reads [w]'s tree. The window's values go in as one JSON string, never as code.
String axScript(ScreenWindow w) {
  final arg = jsonEncode(jsonEncode({'pid': w.pid, 'title': w.title, 'w': w.width, 'h': w.height}));
  return '''
var q = JSON.parse($arg);
var se = Application("System Events");
var procs = se.processes.whose({unixId: q.pid})();
var wins = procs[0].windows();
var win = wins.filter(function (x) { try { return x.title() === q.title && x.size()[0] === q.w && x.size()[1] === q.h; } catch (e) { return false; } })[0]
  || wins.filter(function (x) { try { return x.size()[0] === q.w && x.size()[1] === q.h; } catch (e) { return false; } })[0] || wins[0];
var t0 = Date.now();
function get(f) { try { return f(); } catch (e) { return []; } }
function str(s) { return s == null ? "" : String(s).slice(0, 120); }
var nodes = [];
var queue = [[win, 0]];
while (queue.length && nodes.length < $axMaxNodes && Date.now() - t0 < 6000) {
  var item = queue.shift(), el = item[0], d = item[1];
  if (d >= $axMaxDepth) continue;
  var kids = get(function () { return el.uiElements(); });
  if (!kids.length) continue;
  var roles = get(function () { return el.uiElements.role(); });
  var titles = get(function () { return el.uiElements.title(); });
  var descs = get(function () { return el.uiElements.description(); });
  var vals = get(function () { return el.uiElements.value(); });
  var pos = get(function () { return el.uiElements.position(); });
  var sizes = get(function () { return el.uiElements.size(); });
  for (var i = 0; i < kids.length && nodes.length < $axMaxNodes; i++) {
    var role = str(roles[i]);
    var v = role === "AXSecureTextField" ? "" : str(vals[i]);
    var p = pos[i] || [0, 0], s = sizes[i] || [0, 0];
    nodes.push({d: d, role: role, label: str(titles[i]) || str(descs[i]), value: v, x: p[0], y: p[1], w: s[0], h: s[1]});
    queue.push([kids[i], d + 1]);
  }
}
var wp = get(function () { return win.position(); });
JSON.stringify({x: wp[0] || 0, y: wp[1] || 0, nodes: nodes});''';
}

/// Indented lines `Role "label" value="..." [x,y wxh]` for [nodes] (maps with d, role, label, value, x, y, w, h;
/// breadth-first order is regrouped under their parents by the caller's depth only, so lines keep script order).
/// Coordinates are relative to the window origin. Secure fields never show a value. Cut at [axMaxChars].
String formatAxTree(List<Map<Object?, Object?>> nodes, {int originX = 0, int originY = 0}) {
  final out = StringBuffer();
  var length = 0;
  for (final n in nodes) {
    final role = (n['role'] as String? ?? '').replaceFirst('AX', '');
    final label = (n['label'] as String? ?? '').replaceAll('\n', ' ');
    final secure = n['role'] == 'AXSecureTextField';
    final value = secure ? '' : (n['value'] as String? ?? '').replaceAll('\n', ' ');
    if (label.isEmpty && value.isEmpty && _noiseRoles.contains(n['role'])) continue;
    int num0(String k) => (n[k] as num?)?.toInt() ?? 0;
    final line =
        '${'  ' * num0('d')}$role'
        '${label.isEmpty ? '' : ' "$label"'}'
        '${value.isEmpty ? '' : ' value="$value"'}'
        ' [${num0('x') - originX},${num0('y') - originY} ${num0('w')}x${num0('h')}]\n';
    if (length + line.length > axMaxChars) {
      out.write('(cut: more elements not shown)');
      break;
    }
    out.write(line);
    length += line.length;
  }
  return out.toString().trimRight();
}
