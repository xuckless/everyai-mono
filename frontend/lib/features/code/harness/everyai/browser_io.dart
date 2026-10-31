import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'shell_io.dart' show killTree;

/// A headless Chrome the session owns, driven over the DevTools protocol:
/// its own profile under the session's scratch folder (never the user's
/// browser or cookies), started on first use and stopped with the session.
/// The agent opens pages (`http://localhost…`, `file://…`), clicks and types
/// like a user (real mouse and key events), takes screenshots, runs scripts
/// and reads what the page logged.
final class HeadlessBrowser {
  HeadlessBrowser({required this.profileDir, this.executable});

  /// Where the browser keeps its profile (cookies, storage) for this session.
  final String profileDir;

  /// The browser to run; null finds Chrome, Chromium, Edge or Brave.
  final String? executable;

  Process? _process;
  // Closed in close().
  // ignore: close_sinks
  WebSocket? _socket;
  var _nextId = 0;
  final _calls = <int, Completer<Map<String, Object?>>>{};
  // Lives as long as this object: the browser may start again after close.
  // ignore: close_sinks
  final _events = StreamController<({String method, Map<String, Object?> params})>.broadcast();

  /// Console messages, uncaught errors and failed requests since the last read.
  final _log = <String>[];

  /// Width and height of the viewport, in CSS pixels.
  var width = 1280;
  var height = 800;

  bool get running => _socket != null;

  /// Where a Chromium-family browser is installed, or null.
  static String? find() {
    final env = Platform.environment['EVERYAI_CHROME'];
    if (env != null && File(env).existsSync()) return env;
    final home = Platform.environment['HOME'] ?? '';
    final candidates = <String>[
      if (Platform.isMacOS) ...[
        '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
        '$home/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
        '/Applications/Chromium.app/Contents/MacOS/Chromium',
        '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
        '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
        '/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary',
      ],
      if (Platform.isLinux)
        for (final dir in ['/usr/bin', '/usr/local/bin', '/snap/bin'])
          for (final name in [
            'google-chrome',
            'google-chrome-stable',
            'chromium',
            'chromium-browser',
            'microsoft-edge',
          ])
            '$dir/$name',
      if (Platform.isWindows) ...[
        r'C:\Program Files\Google\Chrome\Application\chrome.exe',
        r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
        r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
      ],
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  Future<void> _start() async {
    if (_socket != null) return;
    final exe = executable ?? find();
    if (exe == null) {
      throw const BrowserError(
        'No Chrome, Chromium, Edge or Brave found. Install one (or set EVERYAI_CHROME to its path), or check the '
        'page another way.',
      );
    }
    Directory(profileDir).createSync(recursive: true);
    final process = await Process.start(exe, [
      '--headless=new',
      '--remote-debugging-port=0',
      '--user-data-dir=$profileDir',
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-extensions',
      '--disable-background-networking',
      '--hide-scrollbars',
      '--mute-audio',
      '--window-size=$width,$height',
      'about:blank',
    ]);
    _process = process;
    unawaited(process.stdout.drain<void>());
    // Chrome says where its DevTools endpoint is on stderr.
    final endpoint = Completer<Uri>();
    process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      final m = RegExp(r'DevTools listening on (ws://\S+)').firstMatch(line);
      if (m != null && !endpoint.isCompleted) endpoint.complete(Uri.parse(m[1]!));
    }, onError: (Object _) {});
    unawaited(
      process.exitCode.then((_) {
        if (!endpoint.isCompleted) endpoint.completeError(const BrowserError('The browser exited at start.'));
        _closed();
      }),
    );
    final browserWs = await endpoint.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () => throw const BrowserError('The browser did not start within 20 s.'),
    );
    // The page target (about:blank) has its own socket: commands go to it
    // without per-target sessions.
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse('http://${browserWs.host}:${browserWs.port}/json/list'));
      final res = await req.close();
      final list = jsonDecode(await res.transform(utf8.decoder).join()) as List<Object?>;
      final page = list.whereType<Map<String, Object?>>().firstWhere(
        (t) => t['type'] == 'page',
        orElse: () => throw const BrowserError('The browser has no page to drive.'),
      );
      _socket = await WebSocket.connect(page['webSocketDebuggerUrl']! as String);
    } finally {
      client.close(force: true);
    }
    _socket!.listen(_onFrame, onDone: _closed, onError: (Object _) => _closed());
    await Future.wait([_send('Page.enable'), _send('Runtime.enable'), _send('Log.enable'), _send('Network.enable')]);
    await _viewport();
  }

  void _onFrame(Object? frame) {
    if (frame is! String) return;
    final Map<String, Object?> msg;
    try {
      msg = jsonDecode(frame) as Map<String, Object?>;
    } on Object {
      return;
    }
    if (msg['id'] case final int id) {
      final c = _calls.remove(id);
      if (c == null) return;
      if (msg['error'] case final Map<String, Object?> e) {
        c.completeError(BrowserError('${e['message'] ?? e}'));
      } else {
        c.complete((msg['result'] as Map<String, Object?>?) ?? const {});
      }
      return;
    }
    final method = msg['method'] as String? ?? '';
    final params = (msg['params'] as Map<String, Object?>?) ?? const {};
    _record(method, params);
    _events.add((method: method, params: params));
  }

  /// Keeps what a developer would look for in the console.
  void _record(String method, Map<String, Object?> p) {
    String? line;
    switch (method) {
      case 'Runtime.consoleAPICalled':
        final args = [
          for (final a in (p['args'] as List<Object?>? ?? const []))
            if (a is Map<String, Object?>) '${a['value'] ?? a['description'] ?? a['type']}',
        ].join(' ');
        line = 'console.${p['type']}: $args';
      case 'Runtime.exceptionThrown':
        final d = p['exceptionDetails'] as Map<String, Object?>? ?? const {};
        final ex = d['exception'] as Map<String, Object?>?;
        line =
            'Uncaught: ${ex?['description'] ?? d['text']}'
            '${d['url'] == null ? '' : ' (${d['url']}:${d['lineNumber']})'}';
      case 'Log.entryAdded':
        final e = p['entry'] as Map<String, Object?>? ?? const {};
        if (e['level'] == 'error' || e['level'] == 'warning') line = '${e['level']}: ${e['text']} ${e['url'] ?? ''}';
      case 'Network.loadingFailed':
        if (p['canceled'] != true) line = 'Request failed: ${p['errorText']} (${p['type'] ?? ''})';
      case 'Network.responseReceived':
        final r = p['response'] as Map<String, Object?>? ?? const {};
        final status = (r['status'] as num?)?.toInt() ?? 0;
        if (status >= 400) line = 'HTTP $status: ${r['url']}';
    }
    if (line == null) return;
    _log.add(line.length > 600 ? '${line.substring(0, 600)}…' : line);
    if (_log.length > 200) _log.removeRange(0, _log.length - 200);
  }

  void _closed() {
    _socket = null;
    for (final c in _calls.values) {
      if (!c.isCompleted) c.completeError(const BrowserError('The browser closed.'));
    }
    _calls.clear();
  }

  Future<Map<String, Object?>> _send(String method, [Map<String, Object?> params = const {}]) {
    final socket = _socket;
    if (socket == null) return Future.error(const BrowserError('The browser is not running.'));
    final id = ++_nextId;
    final c = Completer<Map<String, Object?>>();
    _calls[id] = c;
    socket.add(jsonEncode({'id': id, 'method': method, 'params': params}));
    return c.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _calls.remove(id);
        throw BrowserError('$method took longer than 30 s.');
      },
    );
  }

  Future<void> _viewport() => _send('Emulation.setDeviceMetricsOverride', {
    'width': width,
    'height': height,
    'deviceScaleFactor': 1,
    'mobile': false,
  });

  /// What the page logged since the last call; cleared on read.
  List<String> takeLog() {
    final out = [..._log];
    _log.clear();
    return out;
  }

  Future<String> open(String url) async {
    await _start();
    final loaded = _events.stream.firstWhere((e) => e.method == 'Page.loadEventFired');
    final r = await _send('Page.navigate', {'url': url});
    if (r['errorText'] case final String e when e.isNotEmpty) throw BrowserError('Could not open $url: $e');
    await loaded.timeout(const Duration(seconds: 20), onTimeout: () => (method: '', params: const <String, Object?>{}));
    // A moment for scripts that run after load (frameworks mounting).
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return describe();
  }

  /// The page's address and title.
  Future<String> describe() async {
    final v = await evaluate('JSON.stringify({url: location.href, title: document.title})');
    final m = jsonDecode(v as String) as Map<String, Object?>;
    return '${m['title']} — ${m['url']}';
  }

  Future<Object?> evaluate(String script) async {
    await _start();
    final r = await _send('Runtime.evaluate', {
      'expression': script,
      'returnByValue': true,
      'awaitPromise': true,
      'userGesture': true,
    });
    if (r['exceptionDetails'] case final Map<String, Object?> d) {
      final ex = d['exception'] as Map<String, Object?>?;
      throw BrowserError('The script threw: ${ex?['description'] ?? d['text']}');
    }
    return (r['result'] as Map<String, Object?>?)?['value'];
  }

  /// PNG bytes of the viewport, or of the whole page with [fullPage].
  Future<List<int>> screenshot({bool fullPage = false}) async {
    await _start();
    final params = <String, Object?>{'format': 'png'};
    if (fullPage) {
      final m = await _send('Page.getLayoutMetrics');
      final size = (m['cssContentSize'] ?? m['contentSize']) as Map<String, Object?>? ?? const {};
      params['captureBeyondViewport'] = true;
      params['clip'] = {
        'x': 0,
        'y': 0,
        'width': (size['width'] as num?) ?? width,
        // Very long pages are cut at 8000 px.
        'height': (((size['height'] as num?) ?? height).clamp(1, 8000)),
        'scale': 1,
      };
    }
    final r = await _send('Page.captureScreenshot', params);
    return base64Decode(r['data']! as String);
  }

  /// The centre of the first element matching [selector], scrolled into view.
  Future<({double x, double y})> _centre(String selector) async {
    final v = await evaluate('''
(() => {
  const el = document.querySelector(${jsonEncode(selector)});
  if (!el) return null;
  el.scrollIntoView({block: 'center', inline: 'center'});
  const r = el.getBoundingClientRect();
  return {x: r.left + r.width / 2, y: r.top + r.height / 2, w: r.width, h: r.height};
})()''');
    if (v is! Map) throw BrowserError('No element matches $selector.');
    if (v['w'] == 0 && v['h'] == 0) throw BrowserError('$selector matches an element with no size (hidden?).');
    return (x: (v['x'] as num).toDouble(), y: (v['y'] as num).toDouble());
  }

  /// A real mouse click (press and release) on [selector] or at [x],[y]: it
  /// goes through overlays the way a user's click would.
  Future<String> click({String? selector, double? x, double? y, int count = 1}) async {
    await _start();
    final at = selector != null ? await _centre(selector) : (x: x ?? 0, y: y ?? 0);
    await _send('Input.dispatchMouseEvent', {'type': 'mouseMoved', 'x': at.x, 'y': at.y});
    for (var n = 1; n <= count; n++) {
      for (final type in ['mousePressed', 'mouseReleased']) {
        await _send('Input.dispatchMouseEvent', {
          'type': type,
          'x': at.x,
          'y': at.y,
          'button': 'left',
          'clickCount': n,
        });
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final hit = await evaluate(
      '(() => { const e = document.elementFromPoint(${at.x}, ${at.y}); '
      'return e ? e.tagName.toLowerCase() + (e.id ? "#" + e.id : "") + '
      '(e.className && typeof e.className === "string" ? "." + e.className.trim().split(/\\s+/).join(".") : "") : null; })()',
    );
    return 'Clicked at (${at.x.round()}, ${at.y.round()})${hit == null ? '' : ' on $hit'}.';
  }

  /// Types [text] into [selector] (clicked first) or the focused element.
  Future<String> type(String text, {String? selector, bool submit = false}) async {
    await _start();
    if (selector != null) await click(selector: selector);
    await _send('Input.insertText', {'text': text});
    if (submit) await press('Enter');
    return 'Typed ${text.length} characters${submit ? ' and pressed Enter' : ''}.';
  }

  static const _keys = <String, (String code, int vk, String text)>{
    'Enter': ('Enter', 13, '\r'),
    'Tab': ('Tab', 9, ''),
    'Escape': ('Escape', 27, ''),
    'Backspace': ('Backspace', 8, ''),
    'Delete': ('Delete', 46, ''),
    'Space': ('Space', 32, ' '),
    'ArrowUp': ('ArrowUp', 38, ''),
    'ArrowDown': ('ArrowDown', 40, ''),
    'ArrowLeft': ('ArrowLeft', 37, ''),
    'ArrowRight': ('ArrowRight', 39, ''),
    'Home': ('Home', 36, ''),
    'End': ('End', 35, ''),
    'PageUp': ('PageUp', 33, ''),
    'PageDown': ('PageDown', 34, ''),
  };

  /// A key press: a named key ([_keys]) or one character ("a", "W").
  Future<String> press(String key) async {
    await _start();
    final named = _keys[key];
    final single = named == null && key.length == 1;
    if (named == null && !single) {
      throw BrowserError('Unknown key "$key". Use one of ${_keys.keys.join(', ')} or one character.');
    }
    final upper = single ? key.toUpperCase() : '';
    final base = <String, Object?>{
      'key': key == 'Space' ? ' ' : key,
      'code': named?.$1 ?? (RegExp(r'[a-zA-Z]').hasMatch(key) ? 'Key$upper' : ''),
      'windowsVirtualKeyCode': named?.$2 ?? upper.codeUnitAt(0),
    };
    final text = named?.$3 ?? key;
    await _send('Input.dispatchKeyEvent', {
      ...base,
      'type': text.isEmpty ? 'rawKeyDown' : 'keyDown',
      'text': ?(text.isEmpty ? null : text),
    });
    await _send('Input.dispatchKeyEvent', {...base, 'type': 'keyUp'});
    await Future<void>.delayed(const Duration(milliseconds: 150));
    return 'Pressed $key.';
  }

  Future<String> scroll(double dy, {double? x, double? y}) async {
    await _start();
    await _send('Input.dispatchMouseEvent', {
      'type': 'mouseWheel',
      'x': x ?? width / 2,
      'y': y ?? height / 2,
      'deltaX': 0,
      'deltaY': dy,
    });
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final pos = await evaluate('Math.round(window.scrollY)');
    return 'Scrolled; the page is at y=$pos.';
  }

  /// Waits for [selector] to appear (or [ms] to pass).
  Future<String> wait({String? selector, int ms = 5000}) async {
    await _start();
    if (selector == null) {
      await Future<void>.delayed(Duration(milliseconds: ms.clamp(0, 30000)));
      return 'Waited ${ms}ms.';
    }
    final end = DateTime.now().add(Duration(milliseconds: ms.clamp(0, 30000)));
    while (DateTime.now().isBefore(end)) {
      if (await evaluate('!!document.querySelector(${jsonEncode(selector)})') == true) return '$selector is there.';
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw BrowserError('$selector did not appear within ${ms}ms.');
  }

  Future<String> resize(int w, int h) async {
    width = w.clamp(200, 3840);
    height = h.clamp(200, 2400);
    await _start();
    await _viewport();
    return 'The viewport is ${width}x$height.';
  }

  Future<void> close() async {
    final socket = _socket;
    _socket = null;
    await socket?.close();
    final p = _process;
    _process = null;
    if (p != null) await killTree(p.pid);
  }
}

final class BrowserError implements Exception {
  const BrowserError(this.message);
  final String message;
  @override
  String toString() => message;
}
