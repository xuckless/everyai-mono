// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueNotifier, visibleForTesting;

import '../../live/frames.dart';
import '../../live/key_map.dart';
import '../../live/live_session.dart';
import '../../live/page_snapshot.dart';
import 'shell_io.dart' show killTree;

/// One Chrome per profile folder (Chrome locks a profile, so sessions of one project share the process and get a
/// page each). Started on first use, stopped a little after its last page closes.
final class ChromeHost {
  ChromeHost._(this.profileDir, this.executable);

  static final _hosts = <String, ChromeHost>{};

  /// The host of [profileDir] (one per folder for the app run).
  static ChromeHost of(String profileDir, {String? executable}) =>
      _hosts.putIfAbsent(profileDir, () => ChromeHost._(profileDir, executable));

  final String profileDir;
  final String? executable;
  Process? _process;
  Uri? _endpoint;
  Future<Uri>? _starting;
  var _pages = 0;
  Timer? _idle;

  /// Set while the profile is open in a plain window for the user to sign in (see [signIn]).
  Future<void>? _signingIn;

  bool get running => _endpoint != null;

  /// The browser-level DevTools address, starting Chrome when needed.
  Future<Uri> endpoint({required int width, required int height}) async {
    if (_signingIn case final s?) await s;
    if (_endpoint case final e?) return e;
    return _starting ??= _launch(width, height).whenComplete(() => _starting = null);
  }

  Future<Uri> _launch(int width, int height) async {
    final exe = executable ?? HeadlessBrowser.find();
    if (exe == null) throw const BrowserError(noBrowserMessage);
    Directory(profileDir).createSync(recursive: true);
    final process = await Process.start(exe, [
      '--headless=new',
      '--remote-debugging-port=0',
      '--user-data-dir=$profileDir',
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-extensions',
      '--disable-background-networking',
      // Never the user's Keychain or keyring.
      '--use-mock-keychain',
      '--password-store=basic',
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
        // Not killed later: its pid may be another program's by then.
        if (identical(_process, process)) {
          _process = null;
          _endpoint = null;
        }
        if (!endpoint.isCompleted) endpoint.completeError(const BrowserError('The browser exited at start.'));
      }),
    );
    final e = await endpoint.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () => throw const BrowserError('The browser did not start within 20 s.'),
    );
    return _endpoint = e;
  }

  void _opened() {
    _pages++;
    _idle?.cancel();
  }

  void _closedPage() {
    if (--_pages > 0) return;
    _pages = 0;
    _idle?.cancel();
    _idle = Timer(const Duration(seconds: 30), () => unawaited(stop()));
  }

  Future<void> stop() async {
    _idle?.cancel();
    final p = _process;
    _process = null;
    _endpoint = null;
    if (p != null) await killTree(p.pid);
  }

  /// Opens the profile in a plain Chrome window at [url], without the automation flags (sites such as Google
  /// refuse sign-in in a browser driven over DevTools), and waits until the user closes it. The headless browser
  /// stops meanwhile (its pages close); the next use starts it again with the new sign-ins.
  Future<void> signIn(String url) async {
    final exe = executable ?? HeadlessBrowser.find();
    if (exe == null) throw const BrowserError(noBrowserMessage);
    await stop();
    Directory(profileDir).createSync(recursive: true);
    final done = Completer<void>();
    _signingIn = done.future;
    try {
      final p = await Process.start(exe, [
        '--user-data-dir=$profileDir',
        '--no-first-run',
        '--no-default-browser-check',
        '--use-mock-keychain',
        '--password-store=basic',
        '--new-window',
        url,
      ]);
      unawaited(p.stdout.drain<void>());
      unawaited(p.stderr.drain<void>());
      await p.exitCode;
    } finally {
      _signingIn = null;
      done.complete();
    }
  }

  /// Whether the profile is open for sign-in now.
  bool get signingIn => _signingIn != null;

  /// Deletes the profile (sign-ins, cookies, storage): "Clear" in the project menu.
  Future<void> clear() async {
    await stop();
    final d = Directory(profileDir);
    if (d.existsSync()) d.deleteSync(recursive: true);
  }
}

const noBrowserMessage =
    'No Chrome, Chromium, Edge or Brave found. The user can download one from the Preview tab (or set '
    'EVERYAI_CHROME to a browser\'s path).';

/// A frame of a page's screencast: JPEG bytes, its size, and what to ack.
typedef ScreencastFrame = ({List<int> jpeg, int width, int height, double scrollY, int session});

/// What the Preview shows about the page: its address and title, and whether it can go back or forward.
typedef PageState = ({String url, String title, bool canBack, bool canForward, bool loading});

/// A headless Chrome the session owns, driven over the DevTools protocol:
/// its own profile under the session's scratch folder (never the user's
/// browser or cookies), started on first use and stopped with the session.
/// The agent opens pages (`http://localhost…`, `file://…`), clicks and types
/// like a user (real mouse and key events), takes screenshots, runs scripts
/// and reads what the page logged. It never types into password or payment
/// fields nor submits their forms ([_guardJs]), and its downloads land in
/// [downloadDir].
final class HeadlessBrowser {
  HeadlessBrowser({required this.profileDir, this.executable}) : attachTo = null;

  /// Drives a page of a Chromium-based app that is already running (an Electron app started with
  /// `--remote-debugging-port`), at its browser-level DevTools [endpoint]: the app's own window, at its own size.
  /// Closing detaches; the app keeps running.
  HeadlessBrowser.attached(Uri endpoint) : attachTo = endpoint, profileDir = '', executable = null;

  /// The running app's DevTools endpoint this browser attaches to, or null for our own Chrome.
  final Uri? attachTo;

  /// Where the browser keeps its profile (cookies, storage): the project's, shared by its sessions (see
  /// [ChromeHost]).
  final String profileDir;

  ChromeHost get host => ChromeHost.of(profileDir, executable: executable);

  /// Who drives the page (agent or user), and the agent's actions for the Preview's ghost cursor.
  final control = LiveControl();

  /// The pictures of the page the model has seen, for checking and mapping its coordinates.
  final frames = FrameBook();

  /// The page's address, title and history, for the Preview's bar.
  final page = ValueNotifier<PageState>((url: '', title: '', canBack: false, canForward: false, loading: false));

  String? _targetId;
  // ignore: close_sinks
  final _screencast = StreamController<ScreencastFrame>.broadcast();
  var _casting = false;

  /// The page's screencast while [startScreencast] runs.
  Stream<ScreencastFrame> get screencast => _screencast.stream;

  /// The browser to run; null finds Chrome, Chromium, Edge or Brave.
  final String? executable;

  /// Where downloads go, set before the browser starts (the session's scratch
  /// folder); null refuses downloads.
  String? downloadDir;

  // Closed in close().
  // ignore: close_sinks
  WebSocket? _socket;
  // The browser-level connection: the download folder holds while it is open.
  // Closed in close().
  // ignore: close_sinks
  WebSocket? _browserSocket;

  /// Downloads started and not yet finished, by guid, with their file names.
  final _downloads = <String, ({String name, Completer<void> done})>{};

  /// Frames of other origins attached as their own targets: frame id to session id.
  final _frameSessions = <String, String>{};

  /// How long a click or key press waits for the downloads it started.
  @visibleForTesting
  Duration downloadWait = const Duration(seconds: 20);
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

  /// Everything the browser reports, page and browser level.
  @visibleForTesting
  Stream<({String method, Map<String, Object?> params})> get events => _events.stream;

  /// A Chrome for Testing the app downloaded (see `downloadChromeForTesting`), tried after installed browsers.
  static String? downloaded;

  /// Where a Chromium-family browser is installed, or null.
  static String? find() {
    final env = Platform.environment['EVERYAI_CHROME'];
    if (env != null && File(env).existsSync()) return env;
    final found = _installed();
    if (found != null) return found;
    final d = downloaded;
    return d != null && File(d).existsSync() ? d : null;
  }

  static String? _installed() {
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
    if (attachTo != null) return _attach(attachTo!);
    final endpoint = await host.endpoint(width: width, height: height);
    // A page of our own, with its own socket: commands go to it without per-target sessions.
    final browser = await WebSocket.connect(endpoint.toString());
    _browserSocket = browser;
    browser.listen(
      _onFrame,
      onError: (Object _) {},
      onDone: () {
        if (identical(_browserSocket, browser)) _closed();
      },
    );
    try {
      final created = await _sendOn(browser, 'Target.createTarget', {'url': 'about:blank'});
      _targetId = created['targetId'] as String?;
      if (_targetId == null) throw const BrowserError('The browser has no page to drive.');
      _socket = await WebSocket.connect('ws://${endpoint.host}:${endpoint.port}/devtools/page/$_targetId');
    } on Object {
      await browser.close();
      _browserSocket = null;
      rethrow;
    }
    host._opened();
    _socket!.listen(_onFrame, onDone: _closed, onError: (Object _) => _closed());
    final dir = downloadDir;
    if (dir != null) Directory(dir).createSync(recursive: true);
    await Future.wait([
      _send('Page.enable'),
      _send('Runtime.enable'),
      _send('Log.enable'),
      _send('Network.enable'),
      // Frames of other origins as their own targets, so the guards can look inside.
      _send('Target.setAutoAttach', {'autoAttach': true, 'waitForDebuggerOnStart': false, 'flatten': true}),
      _sendOn(_browserSocket, 'Target.setDiscoverTargets', {'discover': true}),
      _sendOn(_browserSocket, 'Browser.setDownloadBehavior', {
        'behavior': dir == null ? 'deny' : 'allow',
        'downloadPath': ?dir,
        'eventsEnabled': true,
      }),
    ]);
    await _viewport();
    if (_casting) await _castStart();
  }

  /// Attaches to the first window of the app at [endpoint] (see [HeadlessBrowser.attached]).
  Future<void> _attach(Uri endpoint) async {
    final browser = await WebSocket.connect(endpoint.toString());
    _browserSocket = browser;
    browser.listen(
      _onFrame,
      onError: (Object _) {},
      onDone: () {
        if (identical(_browserSocket, browser)) _closed();
      },
    );
    try {
      final targets = await _sendOn(browser, 'Target.getTargets', const {});
      final pages = [
        for (final t in (targets['targetInfos'] as List?) ?? const [])
          if (t is Map && t['type'] == 'page' && !'${t['url']}'.startsWith('devtools://')) t,
      ];
      if (pages.isEmpty) throw const BrowserError("The app has no window to drive yet: try again once it's open.");
      _targetId = pages.first['targetId'] as String?;
      _socket = await WebSocket.connect('ws://${endpoint.host}:${endpoint.port}/devtools/page/$_targetId');
    } on Object {
      await browser.close();
      _browserSocket = null;
      rethrow;
    }
    _socket!.listen(_onFrame, onDone: _closed, onError: (Object _) => _closed());
    await Future.wait([_send('Page.enable'), _send('Runtime.enable'), _send('Log.enable'), _send('Network.enable')]);
    final size = await evaluate('[innerWidth, innerHeight]');
    if (size is List && size.length == 2) {
      width = (size[0] as num).round();
      height = (size[1] as num).round();
    }
    if (_casting) await _castStart();
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
    switch (method) {
      case 'Page.screencastFrame':
        final m = params['metadata'] as Map<String, Object?>? ?? const {};
        _screencast.add((
          jpeg: base64Decode(params['data'] as String? ?? ''),
          width: ((m['deviceWidth'] as num?) ?? width).round(),
          height: ((m['deviceHeight'] as num?) ?? height).round(),
          scrollY: ((m['scrollOffsetY'] as num?) ?? 0).toDouble(),
          session: (params['sessionId'] as num?)?.toInt() ?? 0,
        ));
        return;
      case 'Page.frameNavigated':
        final f = params['frame'] as Map<String, Object?>? ?? const {};
        if (f['parentId'] == null) {
          frames.moved();
          unawaited(_refreshPage(url: f['url'] as String?));
        }
      case 'Page.navigatedWithinDocument':
        frames.moved();
        unawaited(_refreshPage(url: params['url'] as String?));
      case 'Page.frameStartedLoading':
        page.value = (
          url: page.value.url,
          title: page.value.title,
          canBack: page.value.canBack,
          canForward: page.value.canForward,
          loading: true,
        );
      case 'Page.loadEventFired':
        unawaited(_refreshPage());
      case 'Target.targetInfoChanged':
        final t = params['targetInfo'] as Map<String, Object?>? ?? const {};
        if (t['targetId'] == _targetId) unawaited(_refreshPage(url: t['url'] as String?, title: t['title'] as String?));
      case 'Target.attachedToTarget':
        final t = params['targetInfo'] as Map<String, Object?>? ?? const {};
        if (t['type'] == 'iframe') _frameSessions['${t['targetId']}'] = '${params['sessionId']}';
      case 'Target.detachedFromTarget':
        _frameSessions.removeWhere((_, s) => s == params['sessionId']);
    }
    // A frame's own target reports nothing we keep.
    if (msg['sessionId'] != null) return;
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
      case 'Browser.downloadWillBegin':
        _downloads['${p['guid']}'] = (name: '${p['suggestedFilename'] ?? 'download'}', done: Completer<void>());
      case 'Browser.downloadProgress':
        final state = p['state'];
        if (state != 'completed' && state != 'canceled') break;
        final d = _downloads.remove('${p['guid']}');
        d?.done.complete();
        final name = d?.name ?? 'download';
        line = state == 'completed'
            ? 'Downloaded ${p['filePath'] ?? '$downloadDir/$name'}'
            : 'Download canceled: $name${downloadDir == null ? ' (this browser takes no downloads)' : ''}';
    }
    if (line == null) return;
    _log.add(line.length > 600 ? '${line.substring(0, 600)}…' : line);
    if (_log.length > 200) _log.removeRange(0, _log.length - 200);
  }

  void _closed() {
    if ((_socket != null || _browserSocket != null) && attachTo == null) host._closedPage();
    _socket = null;
    _targetId = null;
    unawaited(_browserSocket?.close());
    _browserSocket = null;
    for (final d in _downloads.values) {
      d.done.complete();
    }
    _downloads.clear();
    _frameSessions.clear();
    for (final c in _calls.values) {
      if (!c.isCompleted) c.completeError(const BrowserError('The browser closed.'));
    }
    _calls.clear();
  }

  Future<Map<String, Object?>> _send(String method, [Map<String, Object?> params = const {}]) =>
      _sendOn(_socket, method, params);

  /// Sends [method] on [socket]: the page's, or the browser's own; to the
  /// attached target [session] when given.
  Future<Map<String, Object?>> _sendOn(
    WebSocket? socket,
    String method,
    Map<String, Object?> params, {
    String? session,
  }) {
    if (socket == null) return Future.error(const BrowserError('The browser is not running.'));
    final id = ++_nextId;
    final c = Completer<Map<String, Object?>>();
    _calls[id] = c;
    socket.add(jsonEncode({'id': id, 'method': method, 'params': params, 'sessionId': ?session}));
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

  /// What the page logged since the last call; cleared on read (the last 50 lines stay in [history]).
  List<String> takeLog() {
    final out = [..._log];
    _logged.addAll(out);
    if (_logged.length > 50) _logged.removeRange(0, _logged.length - 50);
    _log.clear();
    return out;
  }

  final _logged = <String>[];

  /// The last 50 lines the page logged, read or not.
  List<String> get history => [..._logged, ..._log];

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
      throw BrowserError('The script threw: ${ex?['description'] ?? d['text']}', fromPage: true);
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

  /// A picture of [region] of the viewport (null: all of it) for the model, sized for it ([agentImageSize]; a
  /// zoomed region at up to twice its CSS size, so small things are legible), and the frame it is recorded as.
  Future<(List<int>, AgentFrame)> frameShot({ViewRect? region}) async {
    await _start();
    await _followWindow();
    final g = geometry;
    final r = region ?? (left: 0.0, top: 0.0, width: g.width.toDouble(), height: g.height.toDouble());
    final zoom = region == null ? 1.0 : 2.0;
    final size = agentImageSize(r.width, r.height, scale: zoom);
    final scroll = await evaluate('[scrollX, scrollY]');
    final sx = scroll is List ? (scroll[0] as num).toDouble() : 0.0,
        sy = scroll is List ? (scroll[1] as num).toDouble() : 0.0;
    final shot = await _send('Page.captureScreenshot', {
      'format': 'png',
      // In page coordinates: the viewport's region plus the scroll offset.
      'clip': {'x': r.left + sx, 'y': r.top + sy, 'width': r.width, 'height': r.height, 'scale': size.width / r.width},
    });
    final f = frames.record(
      imageWidth: size.width,
      imageHeight: size.height,
      geometry: g,
      region: region,
      scrollX: sx,
      scrollY: sy,
    );
    return (base64Decode(shot['data']! as String), f);
  }

  /// An attached app's window may have been resized by the user: read its size again.
  Future<void> _followWindow() async {
    if (attachTo == null) return;
    final size = await evaluate('[innerWidth, innerHeight]');
    if (size is List && size.length == 2) {
      width = (size[0] as num).round();
      height = (size[1] as num).round();
    }
  }

  /// The page's scroll offset now.
  Future<({double x, double y})> scrollOffset() async {
    final v = await evaluate('[scrollX, scrollY]');
    return v is List ? (x: (v[0] as num).toDouble(), y: (v[1] as num).toDouble()) : (x: 0.0, y: 0.0);
  }

  /// The page's elements now (see [pageSnapshotJs]), for what an action changed; empty when the page gives none.
  Future<List<PageElement>> elements() async {
    try {
      final v = await evaluate(pageSnapshotJs);
      if (v is! Map) return const [];
      return [for (final i in (v['items'] as List?) ?? const []) ?PageElement.fromJson(i)];
    } on BrowserError {
      return const [];
    }
  }

  /// The page's element list (see [pageSnapshotJs]): what the model clicks by ref.
  Future<String> snapshot() async {
    await _followWindow();
    final v = await evaluate(pageSnapshotJs);
    if (v is! Map) return '(the page gave no element list)';
    return pageSnapshotText(
      modal: v['modal'] as String?,
      title: '${v['title'] ?? ''}',
      url: '${v['url'] ?? ''}',
      width: (v['w'] as num?)?.toInt() ?? width,
      height: (v['h'] as num?)?.toInt() ?? height,
      scrollY: (v['y'] as num?)?.toInt() ?? 0,
      scrollHeight: (v['sh'] as num?)?.toInt() ?? 0,
      elements: [for (final i in (v['items'] as List?) ?? const []) ?PageElement.fromJson(i)],
    );
  }

  /// The centre of element [ref] of the last element list, scrolled into view.
  Future<({double x, double y})> refCentre(String ref) async {
    final v = await evaluate(refCentreJs(ref));
    if (v is! Map) throw BrowserError('No element $ref on the page now: take a new snapshot.');
    if (v['w'] == 0 && v['h'] == 0) throw BrowserError('$ref has no size now (hidden?).');
    return (x: (v['x'] as num).toDouble(), y: (v['y'] as num).toDouble());
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
  Future<String> click({String? selector, String? ref, double? x, double? y, int count = 1}) async {
    await _start();
    final at = ref != null
        ? await refCentre(ref)
        : selector != null
        ? await _centre(selector)
        : (x: x ?? 0, y: y ?? 0);
    control.report(LiveActivity('click', x: at.x, y: at.y, caption: count > 1 ? 'Double-clicking' : 'Clicking'));
    await _refuse('''
const w = submits(deep(${at.x}, ${at.y}));
return w ? 'that button submits a form with ' + w : null;''', focus: false);
    final before = await _here();
    // What is under the point before the click (a click may re-lay the page out).
    final hit = await evaluate(
      '(() => { const p = document.elementFromPoint(${at.x}, ${at.y}); if (!p) return null; '
      'const e = p.closest("a,button,input,select,textarea,summary,label,[role],[onclick],[tabindex]") || p; '
      'const t = (e.getAttribute("aria-label") || e.innerText || e.value || e.alt || e.title || "").replace(/\\s+/g, " ").trim(); '
      'const role = e.getAttribute("role") || e.tagName.toLowerCase(); '
      'return role + (e.id ? "#" + e.id : "") + (t ? \' "\' + t.slice(0, 40) + \'"\' : ""); })()',
    );
    final running = {..._downloads.keys};
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
    await _settleDownloads(running);
    final after = await _here();
    final moved = after.url != before.url
        ? ' The page went to ${after.url} (${after.title}).'
        : after.title != before.title
        ? ' The title is now "${after.title}".'
        : '';
    return 'Clicked at (${at.x.round()}, ${at.y.round()})${hit == null ? '' : ' on $hit'}.$moved';
  }

  Future<({String url, String title})> _here() async {
    try {
      final v = await evaluate('[location.href, document.title]');
      return v is List ? (url: '${v[0]}', title: '${v[1]}') : (url: '', title: '');
    } on BrowserError {
      return (url: '', title: '');
    }
  }

  /// Types [text] into [selector] (clicked first) or the focused element.
  Future<String> type(String text, {String? selector, String? ref, bool submit = false}) async {
    await _start();
    if (selector != null || ref != null) await click(selector: selector, ref: ref);
    control.report(const LiveActivity('type', caption: 'Typing'));
    await _refuse(
      '''
const el = focused();
const f = $submit && el && (el.form || (el.closest && el.closest('form')));
return sensitive(el) ? 'the field is ' + sensitive(el) : f && sensitiveForm(f) ? 'its form has ' + sensitiveForm(f) : null;''',
    );
    await _send('Input.insertText', {'text': text});
    if (submit) await press('Enter');
    return 'Typed ${text.length} characters${submit ? ' and pressed Enter' : ''}.';
  }

  /// A key press: a key's name ("Enter", "ArrowUp", "Space"), one character ("a", "W", "@"), or a combination
  /// ("Shift+Tab", "Control+a", "Meta+Shift+z"). Characters press the US key that types them, with Shift when it
  /// takes it, so pages that read `key`, `code` or `shiftKey` see what a keyboard sends.
  Future<String> press(String key) async {
    await _start();
    final k = parseKeyPress(key);
    if (k == null) {
      throw BrowserError(
        'Unknown key "$key". Use a key name (Enter, Tab, Escape, Backspace, Delete, Space, ArrowUp/Down/Left/Right, '
        'Home, End, PageUp, PageDown, F1-F12), one character, or a combination such as Shift+Tab or Control+a.',
      );
    }
    final base = <String, Object?>{
      'key': k.key,
      'code': k.code,
      'windowsVirtualKeyCode': k.vk,
      'modifiers': k.modifiers,
      if (k.modifiers & (cdpControl | cdpMeta) != 0)
        if (editingCommandFor(k.code, shift: k.modifiers & cdpShift != 0) case final c?) 'commands': [c],
    };
    final text = k.text ?? '';
    if (k.code == 'Enter' || k.code == 'NumpadEnter') {
      await _refuse('''
const el = focused();
const f = el && (el.form || (el.closest && el.closest('form')));
return f && sensitiveForm(f) ? 'Enter would submit a form with ' + sensitiveForm(f) : null;''');
    } else if (text.isNotEmpty) {
      // Space also presses a focused button.
      await _refuse(
        '''
const el = focused();
const w = ${k.code == 'Space'} && submits(el);
return sensitive(el) ? 'the field is ' + sensitive(el) : w ? 'Space would press a button that submits a form with ' + w : null;''',
      );
    }
    final before = {..._downloads.keys};
    await _send('Input.dispatchKeyEvent', {
      ...base,
      'type': text.isEmpty ? 'rawKeyDown' : 'keyDown',
      'text': ?(text.isEmpty ? null : text),
    });
    await _send('Input.dispatchKeyEvent', {...base, 'type': 'keyUp'});
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await _settleDownloads(before);
    return 'Pressed $key.';
  }

  Future<String> scroll(double dy, {double? x, double? y}) async {
    await _start();
    control.report(LiveActivity('scroll', x: x ?? width / 2, y: y ?? height / 2, caption: 'Scrolling'));
    await _send('Input.dispatchMouseEvent', {
      'type': 'mouseWheel',
      'x': x ?? width / 2,
      'y': y ?? height / 2,
      'deltaX': 0,
      'deltaY': dy,
    });
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final pos = await evaluate(
      '[Math.round(scrollY), Math.max(0, document.documentElement.scrollHeight - innerHeight)]',
    );
    if (pos is! List) return 'Scrolled.';
    return 'Scrolled; the page is at y=${pos[0]}${pos[0] == pos[1]
        ? ' (the bottom)'
        : pos[0] == 0
        ? ' (the top)'
        : ' of ${pos[1]}'}.';
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
    if (attachTo != null) return "The app's window keeps its own size ($width×$height).";
    width = w.clamp(200, 3840);
    height = h.clamp(200, 2400);
    await _start();
    await _viewport();
    return 'The viewport is $width×$height.';
  }

  /// Waits ([downloadWait]) for the downloads an action started (those not in
  /// [before], the guids running when it began), so its log says where they
  /// landed. Earlier downloads still running never hold a later action.
  Future<void> _settleDownloads(Set<String> before) async {
    final mine = [
      for (final e in _downloads.entries)
        if (!before.contains(e.key)) e.value,
    ];
    if (mine.isEmpty) return;
    await Future.wait([for (final d in mine) d.done.future]).timeout(
      downloadWait,
      onTimeout: () {
        for (final d in mine) {
          if (!d.done.isCompleted) _log.add('Download still running: ${d.name}');
        }
        return const [];
      },
    );
  }

  /// Throws a refusal when [check] (a function body over [_guardJs]'s
  /// helpers, returning why or null) finds a password or payment field;
  /// with [focus], in the frame that has the focus too.
  Future<void> _refuse(String check, {bool focus = true}) async {
    final why = await _guard(check, focus: focus);
    if (why == null) return;
    throw BrowserError(
      'Refused: $why. The browser tool never types passwords, one-time codes or payment details and never submits '
      'their forms: the user does that. To test a sign-in or checkout of the app you build, check it another way '
      '(a test, or its API) or ask the user.',
    );
  }

  /// Runs [check] in the page (or in [session], a frame attached as its own
  /// target, and its execution [context]); when the focus is in a frame the
  /// page's script can't look into (another origin), runs it again inside that
  /// frame, through the browser. A frame the browser can't reach either counts
  /// as sensitive: we can't tell what it holds.
  Future<String?> _guard(String check, {bool focus = true, String? session, int? context, int depth = 0}) async {
    Future<Map<String, Object?>> send(String method, Map<String, Object?> params) =>
        _sendOn(_socket, method, params, session: session);
    final r = await send('Runtime.evaluate', {
      'expression':
          '(() => { $_guardJs\nconst why = (() => { $check })();\n'
          'const el = focused();\nreturn why || ($focus && el && el.tagName === "IFRAME" ? el : null); })()',
      'contextId': ?context,
      'objectGroup': 'everyai-guard',
    });
    if (r['exceptionDetails'] case final Map<String, Object?> d) {
      final ex = d['exception'] as Map<String, Object?>?;
      throw BrowserError('The script threw: ${ex?['description'] ?? d['text']}', fromPage: true);
    }
    final result = r['result'] as Map<String, Object?>? ?? const {};
    if (result['value'] case final String why) return why;
    final frame = result['objectId'];
    if (frame is! String) return null;
    try {
      if (depth >= 4) return 'the focus is in frames nested too deep to check';
      final node = (await send('DOM.describeNode', {'objectId': frame}))['node'] as Map<String, Object?>?;
      final id = node?['frameId'] as String?;
      // Another origin's frame mostly runs in its own process, attached as its own target.
      if (_frameSessions[id] case final child?) return await _guard(check, session: child, depth: depth + 1);
      final world = await send('Page.createIsolatedWorld', {'frameId': id, 'worldName': 'everyai'});
      final inFrame = (world['executionContextId']! as num).toInt();
      return await _guard(check, session: session, context: inFrame, depth: depth + 1);
    } on BrowserError {
      return "the focus is in a frame the browser tool can't look into";
    } finally {
      unawaited(
        send('Runtime.releaseObjectGroup', {
          'objectGroup': 'everyai-guard',
        }).catchError((Object _) => const <String, Object?>{}),
      );
    }
  }

  /// Closes this session's page (Chrome itself stops once no session has one).
  Future<void> close() async {
    final target = _targetId;
    if (target != null && _browserSocket != null && attachTo == null) {
      try {
        await _sendOn(_browserSocket, 'Target.closeTarget', {'targetId': target}).timeout(const Duration(seconds: 3));
      } on Object {
        // Gone already.
      }
    }
    final had = _socket != null || _browserSocket != null;
    final socket = _socket;
    _socket = null;
    _targetId = null;
    await socket?.close();
    final browserSocket = _browserSocket;
    _browserSocket = null;
    await browserSocket?.close();
    if (had && attachTo == null) host._closedPage();
  }

  /// The page's size now, in CSS pixels.
  ViewGeometry get geometry => ViewGeometry(width, height);

  Future<void> _refreshPage({String? url, String? title}) async {
    if (_socket == null) return;
    try {
      final h = await _send('Page.getNavigationHistory');
      final at = (h['currentIndex'] as num?)?.toInt() ?? 0;
      final entries = (h['entries'] as List<Object?>?) ?? const [];
      final here = at < entries.length ? entries[at] as Map<String, Object?> : const <String, Object?>{};
      page.value = (
        url: url ?? here['url'] as String? ?? page.value.url,
        title: title ?? here['title'] as String? ?? page.value.title,
        canBack: at > 0,
        canForward: at < entries.length - 1,
        loading: false,
      );
    } on Object {
      // Closing.
    }
  }

  // ----------------------------------------------------------- the Preview (the user's own input, unguarded)

  /// Starts painting frames into [screencast] (the Preview is showing), up to [maxWidth]×[maxHeight].
  Future<void> startScreencast() async {
    _casting = true;
    await _start();
    await _castStart();
  }

  Future<void> _castStart() async {
    await _send('Page.startScreencast', {'format': 'jpeg', 'quality': 72, 'maxWidth': width, 'maxHeight': height});
    // Chrome sends frames on changes only: a still page would show nothing until it moves. One picture now.
    final shot = await _send('Page.captureScreenshot', {'format': 'jpeg', 'quality': 72});
    final scroll = await evaluate('scrollY');
    _screencast.add((
      jpeg: base64Decode(shot['data']! as String),
      width: width,
      height: height,
      scrollY: scroll is num ? scroll.toDouble() : 0,
      session: 0,
    ));
  }

  Future<void> stopScreencast() async {
    _casting = false;
    if (_socket == null) return;
    try {
      await _send('Page.stopScreencast');
    } on Object {
      // Closed.
    }
  }

  /// Tells Chrome frame [session] was painted, so it sends the next (the Preview paces the stream this way).
  void ackFrame(int session) {
    // 0: the picture taken at the start, not one of Chrome's frames.
    if (_socket == null || session == 0) return;
    unawaited(
      _send('Page.screencastFrameAck', {'sessionId': session}).catchError((Object _) => const <String, Object?>{}),
    );
  }

  /// A mouse event from the user's view, in CSS pixels: `mouseMoved`, `mousePressed`, `mouseReleased`,
  /// `mouseWheel`.
  Future<void> userMouse(
    String type,
    double x,
    double y, {
    String button = 'none',
    int buttons = 0,
    int clickCount = 0,
    int modifiers = 0,
    double deltaX = 0,
    double deltaY = 0,
  }) async {
    await _start();
    await _send('Input.dispatchMouseEvent', {
      'type': type,
      'x': x,
      'y': y,
      'button': button,
      'buttons': buttons,
      'clickCount': clickCount,
      'modifiers': modifiers,
      if (type == 'mouseWheel') ...{'deltaX': deltaX, 'deltaY': deltaY},
    });
  }

  /// A key event from the user's view (`keyDown` with [text] for printable keys, `rawKeyDown`, `keyUp`); [commands]
  /// are editing commands Chrome runs for it (`selectAll`, `undo`…), which headless Chrome doesn't map from keys.
  Future<void> userKey(
    String type, {
    required String key,
    required String code,
    int keyCode = 0,
    String? text,
    int modifiers = 0,
    List<String> commands = const [],
  }) async {
    await _start();
    await _send('Input.dispatchKeyEvent', {
      'type': type,
      'key': key,
      'code': code,
      'windowsVirtualKeyCode': keyCode,
      'nativeVirtualKeyCode': keyCode,
      'modifiers': modifiers,
      'text': ?text,
      'unmodifiedText': ?text,
      if (commands.isNotEmpty) 'commands': commands,
    });
  }

  /// Text the user pasted or composed (an IME), inserted at the caret.
  Future<void> userText(String text) async {
    await _start();
    await _send('Input.insertText', {'text': text});
  }

  /// The page's selected text (the user's copy).
  Future<String> selectedText() async {
    final v = await evaluate('String(getSelection ? getSelection() : "")');
    return v is String ? v : '';
  }

  /// Goes to [url] for the user (the address bar).
  Future<void> userOpen(String url) async {
    await _start();
    await _send('Page.navigate', {'url': url});
  }

  Future<void> back() => _history(-1);
  Future<void> forward() => _history(1);

  Future<void> reload() async {
    await _start();
    await _send('Page.reload');
  }

  Future<void> _history(int step) async {
    await _start();
    final h = await _send('Page.getNavigationHistory');
    final at = ((h['currentIndex'] as num?)?.toInt() ?? 0) + step;
    final entries = (h['entries'] as List<Object?>?) ?? const [];
    if (at < 0 || at >= entries.length) return;
    await _send('Page.navigateToHistoryEntry', {'entryId': (entries[at] as Map<String, Object?>)['id']});
  }

  /// Sets the page's size (the Preview's size menu): frames taken before no longer map.
  Future<void> setSize(int w, int h) async {
    await resize(w, h);
    if (_casting) await _castStart();
  }
}

/// Page helpers for the guards: `sensitive(el)` says what a password, one-time
/// code or payment field is ("a password field") or null; `sensitiveForm(f)`
/// the same for a form holding one; `focused()` is the focused element,
/// through shadow roots and same-origin frames (other frames: see [_guard]);
/// `submits(el)` is what makes the form a submit control [el] sends sensitive,
/// or null; `deep(x, y)` is the element at a point, through shadow roots. A
/// frame also counts by its name (Stripe and the like put card fields in their
/// own frame). Names in other languages, canvas fields, div "buttons" and
/// clicks inside another origin's frame are missed: a tripwire, not a sandbox.
const _guardJs = r'''
const cardName = /card.?(number|num)|cardno|card.?no(?![a-z])|ccnum|security.?code|sort.?code|routing.?number|account.?number|(?<![a-z])(cvv|cvc|csc|iban)(?![a-z])/i;
const payFrame = /stripe|braintree|adyen|paypal|checkout|card|payment/i;
const sensitive = (el) => {
  if (!el || !el.tagName) return null;
  const tag = el.tagName.toLowerCase();
  if (tag === 'iframe') {
    return payFrame.test([el.src, el.name, el.title].join(' ')) ? 'in a payment frame' : null;
  }
  if (tag === 'input' && (el.type || '').toLowerCase() === 'password') return 'a password field';
  const ac = (el.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/);
  if (ac.includes('current-password') || ac.includes('new-password')) return 'a password field';
  if (ac.includes('one-time-code')) return 'a one-time code field';
  if (ac.some((t) => t.startsWith('cc-'))) return 'a payment card field';
  const names = [el.getAttribute('name'), el.id, el.getAttribute('aria-label')].filter(Boolean).join(' ');
  return cardName.test(names) ? 'a payment field' : null;
};
const sensitiveForm = (f) => {
  for (const el of [...(f.elements || []), ...f.querySelectorAll('iframe')]) {
    const why = sensitive(el);
    if (why) return why === 'in a payment frame' ? 'a payment frame' : why;
  }
  return null;
};
const submits = (el) => {
  const c = el && el.closest && el.closest('button, input[type=submit i], input[type=image i]');
  const f = c && c.type !== 'button' && c.type !== 'reset' ? c.form : null;
  return f ? sensitiveForm(f) : null;
};
const inside = (el) => {
  try { return el.contentDocument && el.contentDocument.activeElement; } catch (e) { return null; }
};
const focused = () => {
  let el = document.activeElement;
  for (;;) {
    const next = (el && el.shadowRoot && el.shadowRoot.activeElement) || (el && el.tagName === 'IFRAME' && inside(el));
    if (!next || next === el || next.tagName === 'BODY') return el;
    el = next;
  }
};
const deep = (x, y) => {
  let el = document.elementFromPoint(x, y);
  while (el && el.shadowRoot) {
    const under = el.shadowRoot.elementFromPoint(x, y);
    if (!under || under === el) break;
    el = under;
  }
  return el;
};''';

final class BrowserError implements Exception {
  const BrowserError(this.message, {this.fromPage = false});
  final String message;

  /// The message quotes the page (a script's exception), so it goes in the page's untrusted block.
  final bool fromPage;
  @override
  String toString() => message;
}
