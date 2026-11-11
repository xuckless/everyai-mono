// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueNotifier, visibleForTesting;

import '../../live/browser_page.dart';
import '../../live/frames.dart';
import '../../live/browser_jar.dart';
import '../../live/key_map.dart';
import '../../live/login_wall.dart';
import '../../live/live_session.dart';
import '../../live/page_snapshot.dart';
import '../../../../core/process/child_processes.dart';

export '../../live/browser_page.dart';

/// Where a profile's Chrome is.
///
/// ```
///   closed ──use──▶ launching ──up──▶ up ──stop / idle──▶ stopping ──gone──▶ closed
///     │  ▲             │ fail / stop ▲                                  ▲
///     │  └─────────────┘ (a launch that lands after a stop is ended)     │
///     └──signIn──▶ signingIn ──window closed────────────────────────────┘
/// ```
sealed class ChromeHostState {
  const ChromeHostState();
}

final class ChromeClosed extends ChromeHostState {
  const ChromeClosed();
}

final class ChromeLaunching extends ChromeHostState {
  const ChromeLaunching(this.generation, this.ready);
  final int generation;
  final Future<Uri> ready;
}

final class ChromeUp extends ChromeHostState {
  const ChromeUp(this.generation, this.process, this.endpoint);
  final int generation;
  final Process process;
  final Uri endpoint;
}

final class ChromeStopping extends ChromeHostState {
  const ChromeStopping(this.done);
  final Future<void> done;
}

final class ChromeSigningIn extends ChromeHostState {
  const ChromeSigningIn(this.done);
  final Future<void> done;
}

/// One Chrome per profile folder (Chrome locks a profile, so sessions of one project share the process and get a
/// page each). Started on first use, stopped a little after its last page closes, and at quit ([stopAll]).
final class ChromeHost {
  ChromeHost._(this.profileDir, this.executable);

  static final _hosts = <String, ChromeHost>{};

  /// The host of [profileDir] (one per folder for the app run).
  static ChromeHost of(String profileDir, {String? executable}) =>
      _hosts.putIfAbsent(profileDir, () => ChromeHost._(profileDir, executable));

  /// Stops every profile's Chrome (the app quits).
  static Future<void> stopAll() => Future.wait([for (final h in _hosts.values.toList()) h.stop()]);

  final String profileDir;
  final String? executable;
  ChromeHostState _state = const ChromeClosed();

  /// Bumped by every launch and stop: a launch that finishes under another generation was stopped meanwhile.
  var _generation = 0;
  var _pages = 0;
  Timer? _idle;

  ChromeHostState get state => _state;

  bool get running => _state is ChromeUp;

  /// The browser-level DevTools address, starting Chrome when needed.
  Future<Uri> endpoint({required int width, required int height}) async {
    while (true) {
      switch (_state) {
        case ChromeUp(:final endpoint):
          return endpoint;
        case ChromeLaunching(:final ready):
          return ready;
        case ChromeStopping(:final done) || ChromeSigningIn(:final done):
          await done;
        case ChromeClosed():
          final generation = ++_generation;
          final ready = Completer<Uri>();
          // The state first: a launch that fails at once settles it back to closed.
          _state = ChromeLaunching(generation, ready.future);
          unawaited(_launch(generation, width, height).then(ready.complete, onError: ready.completeError));
          return ready.future;
      }
    }
  }

  /// Chrome's flags: headless, our own profile, nothing that phones home or touches the user's Keychain.
  static List<String> launchArgs(String profileDir, int width, int height) => [
    '--headless=new',
    '--remote-debugging-port=0',
    '--user-data-dir=$profileDir',
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-extensions',
    '--disable-background-networking',
    '--disable-breakpad',
    '--disable-crash-reporter',
    // Never the user's Keychain or keyring.
    '--use-mock-keychain',
    '--password-store=basic',
    '--hide-scrollbars',
    '--mute-audio',
    '--window-size=$width,$height',
    'about:blank',
  ];

  Future<Uri> _launch(int generation, int width, int height) async {
    final exe = executable ?? HeadlessBrowser.find();
    if (exe == null) {
      _settle(generation, const ChromeClosed());
      throw const BrowserError(noBrowserMessage);
    }
    Directory(profileDir).createSync(recursive: true);
    final Process process;
    try {
      process = await Process.start(exe, launchArgs(profileDir, width, height));
    } on Object catch (e) {
      _settle(generation, const ChromeClosed());
      throw BrowserError('The browser did not start: $e');
    }
    ChildProcesses.track(process.pid, label: 'Chrome ($profileDir)', executable: exe, exited: process.exitCode);
    unawaited(process.stdout.drain<void>());
    // Chrome says where its DevTools endpoint is on stderr.
    final endpoint = Completer<Uri>();
    process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      final m = RegExp(r'DevTools listening on (ws://\S+)').firstMatch(line);
      if (m != null && !endpoint.isCompleted) endpoint.complete(Uri.parse(m[1]!));
    }, onError: (Object _) {});
    unawaited(
      process.exitCode.then((_) {
        if (_state case ChromeUp(process: final p) when identical(p, process)) _state = const ChromeClosed();
        if (!endpoint.isCompleted) endpoint.completeError(const BrowserError('The browser exited at start.'));
      }),
    );
    final Uri e;
    try {
      e = await endpoint.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () => throw const BrowserError('The browser did not start within 20 s.'),
      );
    } on Object {
      await ChildProcesses.stop(process.pid);
      _settle(generation, const ChromeClosed());
      rethrow;
    }
    // Stopped while it started: this Chrome isn't wanted any more.
    if (generation != _generation) {
      await ChildProcesses.stop(process.pid);
      throw const BrowserError('The browser was stopped while it started.');
    }
    _state = ChromeUp(generation, process, e);
    return e;
  }

  /// Moves to [next] when [generation] is still the current one.
  void _settle(int generation, ChromeHostState next) {
    if (generation == _generation) _state = next;
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

  /// Ends Chrome (a launch under way is ended when it lands); a stop under way is joined.
  Future<void> stop() {
    _idle?.cancel();
    switch (_state) {
      case ChromeStopping(:final done) || ChromeSigningIn(:final done):
        return done;
      case ChromeClosed():
        return Future.value();
      case ChromeLaunching(:final ready):
        // The launch that lands is ended by its generation check; until then the old Chrome holds the profile, so
        // a new start waits for it.
        _generation++;
        final done = ready.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
          if (_state is ChromeStopping) _state = const ChromeClosed();
        });
        _state = ChromeStopping(done);
        return done;
      case ChromeUp(:final process):
        _generation++;
        final done = ChildProcesses.stop(process.pid).whenComplete(() {
          if (_state is ChromeStopping) _state = const ChromeClosed();
        });
        _state = ChromeStopping(done);
        return done;
    }
  }

  /// Opens the profile in a plain Chrome window at [url], without the automation flags (sites such as Google
  /// refuse sign-in in a browser driven over DevTools), and waits until the user closes it. The headless browser
  /// stops meanwhile (its pages close); the next use starts it again with the new sign-ins.
  Future<void> signIn(String url) async {
    final exe = executable ?? HeadlessBrowser.find();
    if (exe == null) throw const BrowserError(noBrowserMessage);
    // Pages that go with the headless Chrome now went on purpose (their login walls keep waiting for this window).
    _stoppingForSignIn = true;
    final done = Completer<void>();
    try {
      await stop();
    } on Object {
      _stoppingForSignIn = false;
      rethrow;
    }
    Directory(profileDir).createSync(recursive: true);
    _state = ChromeSigningIn(done.future);
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
      ChildProcesses.track(p.pid, label: 'Chrome sign-in ($profileDir)', executable: exe, exited: p.exitCode);
      unawaited(p.stdout.drain<void>());
      unawaited(p.stderr.drain<void>());
      await p.exitCode;
    } finally {
      _state = const ChromeClosed();
      _stoppingForSignIn = false;
      done.complete();
    }
  }

  var _stoppingForSignIn = false;

  /// Whether the profile is open for sign-in now.
  bool get signingIn => _state is ChromeSigningIn;

  /// Whether Chrome is stopped for, or open in, a sign-in window ([signIn]): its pages closed on purpose.
  bool get closedForSignIn => _stoppingForSignIn || signingIn;

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

/// A headless Chrome the session owns, driven over the DevTools protocol:
/// its own profile under the session's scratch folder (never the user's
/// browser or cookies), started on first use and stopped with the session.
/// The agent opens pages (`http://localhost…`, `file://…`), clicks and types
/// like a user (real mouse and key events), takes screenshots, runs scripts
/// and reads what the page logged. It never types into password or payment
/// fields nor submits their forms ([_guardJs]), and its downloads land in
/// [downloadDir].
final class HeadlessBrowser implements StreamedPage {
  HeadlessBrowser({required this.profileDir, this.executable, this.jarHome}) : attachTo = null;

  /// Drives a page of a Chromium-based app that is already running (an Electron app started with
  /// `--remote-debugging-port`), at its browser-level DevTools [endpoint]: the app's own window, at its own size.
  /// Closing detaches; the app keeps running.
  HeadlessBrowser.attached(Uri endpoint) : attachTo = endpoint, profileDir = '', executable = null, jarHome = null;

  /// Where the session's own cookie jar is kept: with one, the browser runs in a context of its own in the
  /// project's Chrome (cookies and storage apart from other sessions'), started from the jar and saved back to it.
  /// Without one, it uses the profile's shared cookies.
  @override
  final JarHome? jarHome;

  /// The session's browser context in Chrome, while running with a [jarHome].
  String? _contextId;

  /// The jar as last read or captured; [_jarLoad] reads it from disk once a run.
  JarData _jar = emptyJar;
  Future<void>? _jarLoad;
  var _jarLoaded = false;

  /// The jar file is there but doesn't open (another keychain: a debug and a release build): it is never written
  /// over.
  var _jarUnreadable = false;

  /// Origins whose stored local storage still waits to go into the context: written into a page of the origin when
  /// it first loads (only there: no page gets another origin's storage), which then reloads.
  final _restore = <String>{};

  /// A jar write in flight (forgetJar waits for it, so a deleted jar can't come back).
  Future<void>? _writing;

  /// Saved logins this session started from, by site: their refreshed sign-ins are written back.
  @override
  final usedLogins = <String, String>{};

  /// Keeps the jar current while running (a Chrome that stops all at once loses at most this much).
  Timer? _jarTimer;

  /// Set by [forgetJar]: the session is gone, so its jar is deleted rather than saved.
  var _forget = false;

  /// The login wall: the agent's call waits on a sign-in page until the user signs in or skips.
  @override
  final loginWall = LoginWall();

  /// The running app's DevTools endpoint this browser attaches to, or null for our own Chrome.
  final Uri? attachTo;

  /// Where the browser keeps its profile (cookies, storage): the project's, shared by its sessions (see
  /// [ChromeHost]).
  final String profileDir;

  ChromeHost get host => ChromeHost.of(profileDir, executable: executable);

  /// Who drives the page (agent or user), and the agent's actions for the Preview's ghost cursor.
  @override
  final control = LiveControl();

  /// The pictures of the page the model has seen, for checking and mapping its coordinates.
  @override
  final frames = FrameBook();

  /// The page's address, title and history, for the Preview's bar.
  @override
  final page = ValueNotifier<PageState>((url: '', title: '', canBack: false, canForward: false, loading: false));

  /// The session's tabs, in the order they opened; the active one is [activeTab].
  @override
  final tabs = ValueNotifier<List<BrowserTab>>(const []);

  /// The dialog the active page waits on, or null.
  @override
  final dialog = ValueNotifier<PageDialog?>(null);

  /// The file picker the active page opened, or null.
  @override
  final fileChooser = ValueNotifier<FileChooser?>(null);

  /// This session's downloads (the last 20).
  @override
  final downloads = ValueNotifier<List<BrowserDownload>>(const []);

  /// The tab the agent and the Preview act on.
  @override
  String? get activeTab => _targetId;

  /// The browser's DevTools address (to connect to another tab).
  Uri? _endpointUri;

  String? _targetId;
  // ignore: close_sinks
  final _screencast = StreamController<ScreencastFrame>.broadcast();
  var _casting = false;

  /// The page's screencast while [startScreencast] runs.
  @override
  Stream<ScreencastFrame> get screencast => _screencast.stream;

  /// The browser to run; null finds Chrome, Chromium, Edge or Brave.
  final String? executable;

  /// Where downloads go, set before the browser starts (the session's scratch
  /// folder); null refuses downloads.
  @override
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
  @override
  var width = 1280;
  @override
  var height = 800;

  @override
  bool get running => _socket != null || _switching != null;

  /// A tab switch in flight ([switchTab]); [_start] and further switches wait for it.
  Future<void>? _switching;

  /// Waits until no tab switch is in flight.
  Future<void> _switched() async {
    for (var s = _switching; s != null; s = _switching) {
      await s.then((_) {}, onError: (Object _) {});
    }
  }

  /// [close] is closing the tabs: a closed tab hands over to no other.
  var _closing = false;

  /// This browser counts as one of its host's pages (from [_start] until [_release]).
  var _counted = false;

  void _release() {
    if (!_counted) return;
    _counted = false;
    host._closedPage();
  }

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
    // A tab switch in flight: its socket is coming, not a new page.
    await _switched();
    if (_socket != null || _closing || _switching != null) return;
    if (attachTo != null) return _attach(attachTo!);
    final endpoint = await host.endpoint(width: width, height: height);
    _endpointUri = endpoint;
    // A page of our own, with its own socket: commands go to it without per-target sessions.
    final browser = await WebSocket.connect(endpoint.toString());
    _browserSocket = browser;
    browser.listen(
      (f) => _onFrame(f, browser),
      onError: (Object _) {},
      onDone: () {
        if (identical(_browserSocket, browser)) _closed();
      },
    );
    try {
      // A window of its own: headless Chrome paints only the front tab of a window, so a page that shares one with
      // another session's goes to the back and its screencast stops (the address still changes, the picture not).
      if (jarHome != null) {
        // Disposed with the browser socket: a context left by an app that crashed goes with it.
        final ctx = await _sendOn(browser, 'Target.createBrowserContext', {'disposeOnDetach': true});
        _contextId = ctx['browserContextId'] as String?;
        await _loadJar();
        // A fresh context: every origin's storage waits for its first page.
        _restore
          ..clear()
          ..addAll(_jar.storage.keys);
        final cookies = [for (final c in _jar.cookies) ?cookieParam(c)];
        if (cookies.isNotEmpty) {
          await _sendOn(browser, 'Storage.setCookies', {'cookies': cookies, 'browserContextId': _contextId});
        }
      }
      final created = await _sendOn(browser, 'Target.createTarget', {
        'url': 'about:blank',
        'newWindow': true,
        'browserContextId': ?_contextId,
      });
      _targetId = created['targetId'] as String?;
      if (_targetId == null) throw const BrowserError('The browser has no page to drive.');
      _socket = await WebSocket.connect('ws://${endpoint.host}:${endpoint.port}/devtools/page/$_targetId');
    } on Object {
      await browser.close();
      _browserSocket = null;
      rethrow;
    }
    _counted = true;
    host._opened();
    final page = _socket!;
    page.listen((f) => _onFrame(f, page), onDone: () => _pageGone(page), onError: (Object _) => _pageGone(page));
    _tabList
      ..clear()
      ..add((id: _targetId!, url: 'about:blank', title: ''));
    _publishTabs();
    final dir = downloadDir;
    if (dir != null) Directory(dir).createSync(recursive: true);
    await Future.wait([
      _enablePage().then((_) => _learnFrames()),
      _sendOn(_browserSocket, 'Target.setDiscoverTargets', {'discover': true}),
      // Per browser context: a session with a jar downloads in its own context, not the profile's default one.
      _sendOn(_browserSocket, 'Browser.setDownloadBehavior', {
        'behavior': dir == null ? 'deny' : 'allow',
        'downloadPath': ?dir,
        'eventsEnabled': true,
        'browserContextId': ?_contextId,
      }),
    ]);
    await _viewport();
    if (_casting) await _castStart();
    if (jarHome != null) {
      _jarTimer?.cancel();
      _jarTimer = Timer.periodic(const Duration(seconds: 30), (_) => unawaited(_keepJar()));
    }
  }

  // ----------------------------------------------------------------------------------- the session's cookie jar

  /// Reads the jar once; concurrent callers share the read.
  Future<void> _loadJar() {
    if (jarHome == null) return Future.value();
    return _jarLoad ??= _readJar();
  }

  Future<void> _readJar() async {
    final home = jarHome!;
    try {
      final store = await home.store();
      final j = await store.read(home.name);
      if (j == null && store.exists(home.name)) _jarUnreadable = true;
      _jar = jarMerged(jarFromJson(j), _jar);
      if (j is Map && j['logins'] is Map) {
        usedLogins.addAll({for (final e in (j['logins'] as Map).entries) '${e.key}': '${e.value}'});
      }
    } on Object {
      // No key (a refused keychain prompt): the jar isn't loaded, so nothing is written over it, and the next use
      // asks again.
      _jarLoad = null;
      return;
    }
    _jarLoaded = true;
  }

  /// Writes origin [origin]'s stored local storage into the page now on it, then reloads so the site starts
  /// signed in.
  Future<void> _restoreOrigin(String origin) async {
    final items = _jar.storage[origin];
    if (items == null || items.isEmpty) return;
    try {
      await _send('DOMStorage.enable');
      for (final e in items.entries) {
        await _send('DOMStorage.setDOMStorageItem', {
          'storageId': {'securityOrigin': origin, 'isLocalStorage': true},
          'key': e.key,
          'value': e.value,
        });
      }
      await _send('Page.reload');
    } on Object {
      // The page left already: it comes back on the origin's next page.
      _restore.add(origin);
    }
  }

  /// The page's local storage into the jar (the app reads it, not the agent).
  Future<void> _readStorage() async {
    if (_socket == null || dialog.value != null) return;
    try {
      final r = await _send('Runtime.evaluate', {
        'expression': storageReadJs,
        'returnByValue': true,
        'objectGroup': 'everyai-jar',
      }).timeout(const Duration(seconds: 3));
      final v = (r['result'] as Map<String, Object?>?)?['value'];
      if (v is List && v.length == 2 && v[0] is String && v[1] is Map) {
        final items = {for (final e in (v[1] as Map).entries) '${e.key}': '${e.value}'};
        final storage = {..._jar.storage};
        if (items.isEmpty) {
          storage.remove(v[0]);
        } else {
          storage[v[0] as String] = items;
        }
        _jar = (cookies: _jar.cookies, storage: storage);
      }
    } on Object {
      // A page that's busy or gone: the last reading stands.
    }
  }

  /// Origins this session's tabs showed as their page (not iframes': their storage is another site's partition).
  final _topOrigins = <String>{};

  /// A local storage change Chrome reported (DOMStorage events), into the jar: only for the tabs' own origins.
  void _storageChanged(String method, Map<String, Object?> p) {
    final origin = storageEventOrigin(p['storageId'] as Map<String, Object?>? ?? const {});
    if (origin == null || !_topOrigins.contains(origin)) return;
    final items = {...?_jar.storage[origin]};
    switch (method) {
      case 'DOMStorage.domStorageItemAdded' || 'DOMStorage.domStorageItemUpdated':
        items['${p['key']}'] = '${p['newValue'] ?? ''}';
      case 'DOMStorage.domStorageItemRemoved':
        items.remove('${p['key']}');
      case 'DOMStorage.domStorageItemsCleared':
        items.clear();
    }
    final storage = {..._jar.storage};
    if (items.isEmpty) {
      storage.remove(origin);
    } else {
      storage[origin] = items;
    }
    _jar = (cookies: _jar.cookies, storage: storage);
  }

  /// The jar as it is now: the context's cookies and the storage read from its pages.
  @override
  Future<JarData> captureJar() async {
    if (_contextId != null && _browserSocket != null) {
      try {
        final r = await _sendOn(_browserSocket, 'Storage.getCookies', {
          'browserContextId': _contextId,
        }).timeout(const Duration(seconds: 3));
        _jar = (
          cookies: [
            for (final c in (r['cookies'] as List?) ?? const [])
              if (c is Map) c.cast<String, Object?>(),
          ],
          storage: _jar.storage,
        );
      } on Object {
        // Keep the last reading.
      }
      await _readStorage();
    }
    return _jar;
  }

  Future<void> _keepJar() async {
    await captureJar();
    await _writeJar();
  }

  Future<void> _writeJar() async {
    final home = jarHome;
    if (home == null || _forget || !_jarLoaded || _jarUnreadable) return;
    final prev = _writing;
    final w = _writing = () async {
      if (prev != null) await prev;
      if (_forget) return;
      try {
        await (await home.store()).write(home.name, {...jarToJson(_jar), 'logins': usedLogins});
      } on Object {
        // No keychain: the jar lives for this run only.
      }
    }();
    await w;
    if (identical(_writing, w)) _writing = null;
  }

  /// Saves the jar now (captured first while running, unless [captured]: the caller just did).
  @override
  Future<void> saveJar({bool captured = false}) async {
    if (!_jarLoaded) await _loadJar();
    if (running && !captured) await captureJar();
    await _writeJar();
  }

  /// The session was removed: its jar is deleted, and nothing is saved when the browser closes.
  @override
  Future<void> forgetJar() async {
    _forget = true;
    _jarTimer?.cancel();
    final home = jarHome;
    if (home == null) return;
    if (_writing case final w?) await w;
    try {
      await (await home.store()).delete(home.name);
    } on Object {
      // Nothing kept.
    }
  }

  /// Adds [data] (a saved login, or a sign-in made in a real window) to the session: its cookies at once, its
  /// storage now on a page of its origin (which reloads) and otherwise when one first loads. [loginId] records the
  /// saved login it came from, for writing the refreshed sign-in back.
  @override
  Future<void> applyJar(JarData data, {String? site, String? loginId}) async {
    await _loadJar();
    _jar = jarMerged(_jar, data);
    if (site != null && loginId != null) usedLogins[site] = loginId;
    if (running && _browserSocket != null) {
      final cookies = [for (final c in data.cookies) ?cookieParam(c)];
      if (cookies.isNotEmpty) {
        await _sendOn(_browserSocket, 'Storage.setCookies', {'cookies': cookies, 'browserContextId': ?_contextId});
      }
      // Storage goes into each origin's own page: the one on it now, the others when they first load.
      _restore.addAll(data.storage.keys);
      final origin = webOrigin(page.value.url);
      if (origin != null && _restore.remove(origin)) {
        await _restoreOrigin(origin);
      } else if (data.cookies.isNotEmpty) {
        await reload();
      }
    }
    await _writeJar();
  }

  /// Signs the session out of [site] (null: every site): its cookies and storage leave the jar and the browser. A
  /// site's storage is cleared in each of its origins the session knows of (not only the page's); every site gets a
  /// fresh browser context, its tabs opened again where they were.
  @override
  Future<void> clearJar({String? site}) async {
    await _loadJar();
    final live = running && _browserSocket != null && _contextId != null;
    final all = live ? await captureJar() : _jar;
    if (site != null && live) {
      for (final c in jarForSite(all, site).cookies) {
        await _send('Network.deleteCookies', {
          'name': c['name'],
          'domain': c['domain'],
          'path': c['path'],
          if (c['partitionKey'] case final Map<String, Object?> k) 'partitionKey': k,
        });
      }
      // Every origin of the site the session knows of: stored ones, the tabs', and the ones this tab went through.
      final visited = <String>[];
      try {
        final h = await _send('Page.getNavigationHistory');
        for (final e in (h['entries'] as List?) ?? const []) {
          if (e is Map && e['url'] is String) visited.add(e['url'] as String);
        }
      } on Object {
        // No history: the others still go.
      }
      final origins = <String>{
        for (final o in all.storage.keys)
          if (siteOf(Uri.tryParse(o)?.host ?? '') == site) o,
        for (final o in _restore)
          if (siteOf(Uri.tryParse(o)?.host ?? '') == site) o,
        for (final t in [..._tabList.map((t) => t.url), page.value.url, ...visited])
          if (webOrigin(t) case final o? when siteOf(Uri.parse(o).host) == site) o,
        for (final c in jarForSite(all, site).cookies)
          if ('${c['domain'] ?? ''}'.replaceFirst(RegExp(r'^\.'), '') case final d when d.isNotEmpty) ...[
            'https://$d',
            'http://$d',
          ],
      };
      for (final origin in origins) {
        try {
          // Sent on the page: it clears in the page's own browser context.
          await _send('Storage.clearDataForOrigin', {
            'origin': origin,
            'storageTypes': 'local_storage,indexeddb,cache_storage,service_workers,websql,file_systems',
          });
        } on Object {
          // An origin Chrome doesn't take (a bare cookie domain): nothing stored there.
        }
      }
      final here = Uri.tryParse(page.value.url);
      if (here != null && here.hasAuthority && siteOf(here.host) == site) {
        await _send('Runtime.evaluate', {'expression': 'try { sessionStorage.clear(); } catch (_) {}'});
      }
    }
    _jar = site == null ? emptyJar : jarWithoutSite(_jar, site);
    _restore.removeWhere((o) => site == null || siteOf(Uri.tryParse(o)?.host ?? '') == site);
    if (site == null) {
      usedLogins.clear();
    } else {
      usedLogins.remove(site);
    }
    await _writeJar();
    if (site == null && live) {
      await _freshContext();
    } else if (running) {
      await reload();
    }
  }

  /// Closes the session's browser context (with everything it holds) and starts a new, empty one, with the tabs
  /// that were open opened again (the active one active).
  Future<void> _freshContext() async {
    final here = page.value.url;
    final others = [
      for (final t in _tabList)
        if (t.id != _targetId && webOrigin(t.url) != null) t.url,
    ];
    _noSave = true;
    try {
      // Closing the browser socket disposes the context (disposeOnDetach).
      await close();
    } finally {
      _noSave = false;
    }
    await _start();
    final main = _targetId;
    for (final u in others) {
      await openTab(u).catchError((Object _) {});
    }
    if (main != null && _targetId != main) await switchTab(main);
    if (webOrigin(here) != null) await userOpen(here);
  }

  /// Set while [_freshContext] closes the old context: what it held is not saved.
  var _noSave = false;

  /// The sites this session is signed in to (it has cookies for), from the last reading.
  @override
  List<String> get signedInSites => jarSites(_jar);

  /// The sign-ins in the project's shared profile (the "Sign in in a window" Chrome, and sign-ins made before
  /// sessions had jars of their own): its cookies for [site], or for every site.
  @override
  Future<JarData> profileSignIns({String? site}) async {
    await _start();
    final r = await _sendOn(_browserSocket, 'Storage.getCookies', const {});
    final all = (
      cookies: [
        for (final c in (r['cookies'] as List?) ?? const [])
          if (c is Map) c.cast<String, Object?>(),
      ],
      storage: const <String, Map<String, String>>{},
    );
    return site == null ? all : jarForSite(all, site);
  }

  /// What every page of ours is driven with: events, frames of other origins as their own targets (so the guards
  /// can look inside), file pickers handed to us instead of opening, and the right-click tracker.
  Future<void> _enablePage() async {
    await Future.wait([
      _send('Page.enable'),
      _send('Runtime.enable'),
      _send('Log.enable'),
      _send('Network.enable'),
      _send('Target.setAutoAttach', {'autoAttach': true, 'waitForDebuggerOnStart': false, 'flatten': true}),
      _send('Page.setInterceptFileChooserDialog', {'enabled': true}),
      // A tab in a window that isn't the front one still counts as focused and visible: it keeps painting and its
      // timers and focus handlers keep running.
      _send('Emulation.setFocusEmulationEnabled', {'enabled': true}).then((_) {}, onError: (Object _) {}),
      _send('Page.addScriptToEvaluateOnNewDocument', {'source': _contextTrackerJs}),
      // A session with a jar follows its pages' local storage as it changes, so a write just before the page leaves
      // (a token saved right before an OAuth redirect) is kept.
      if (jarHome != null) _send('DOMStorage.enable'),
    ]);
    // Not waited for: a page that shows a dialog runs no script until it is answered.
    unawaited(_send('Runtime.evaluate', {'expression': _contextTrackerJs}).then((_) {}, onError: (Object _) {}));
  }

  /// Frames inside the session's tabs (a tab's main frame has the tab's id): a download one of them starts is ours.
  final _ownFrames = <String>{};

  bool _ownsFrame(String id) => _ownFrames.contains(id) || _tabList.any((t) => t.id == id);

  /// Adds the frames already in the active page (Page.frameAttached tells only of new ones).
  Future<void> _learnFrames() async {
    try {
      final tree = await _send('Page.getFrameTree');
      void walk(Object? node) {
        if (node is! Map<String, Object?>) return;
        final f = node['frame'];
        if (f is Map<String, Object?> && f['id'] != null) _ownFrames.add('${f['id']}');
        for (final c in (node['childFrames'] as List<Object?>?) ?? const []) {
          walk(c);
        }
      }

      walk(tree['frameTree']);
    } on Object {
      // A page showing a dialog may not answer; its new frames still arrive as events.
    }
  }

  /// Tabs switched away from while they showed a dialog: their socket (the only one the page still answers) and
  /// the dialog.
  final _parked = <String, ({WebSocket socket, PageDialog dialog})>{};

  /// Tabs that share their opener's renderer, by tab id: the tab that opened each.
  final _openerOf = <String, String>{};

  /// The first tab of [id]'s renderer group (pages opened from one another).
  String _groupOf(String id) {
    var at = id;
    for (var hops = 0; hops < 20; hops++) {
      final up = _openerOf[at];
      if (up == null) break;
      at = up;
    }
    return at;
  }

  /// The dialog another tab waits on that holds up the active one too (they share a renderer), with that tab's
  /// number (from 1), or null.
  @override
  ({int tab, PageDialog dialog})? get dialogHoldingThis {
    final here = _targetId;
    if (here == null) return null;
    final group = _groupOf(here);
    final hereUrl = _tabList.where((t) => t.id == here).firstOrNull?.url ?? page.value.url;
    for (final (i, t) in _tabList.indexed) {
      if (t.id == here) continue;
      if (_parked[t.id] case final p? when _groupOf(t.id) == group && maySharePageProcess(hereUrl, t.url)) {
        return (tab: i + 1, dialog: p.dialog);
      }
    }
    return null;
  }

  /// The dialog another tab of the session waits on, with its tab's number (from 1), or null.
  @override
  ({int tab, PageDialog dialog})? get dialogElsewhere {
    for (final (i, t) in _tabList.indexed) {
      final p = t.id == _targetId ? null : _parked[t.id];
      if (p != null) return (tab: i + 1, dialog: p.dialog);
    }
    return null;
  }

  /// Which socket each call in flight went out on.
  final _callSockets = <int, WebSocket>{};

  /// [socket]'s page went (it closed itself, say from a click on its own Close button): what was sent there is
  /// done, with no answer coming.
  void _settleCallsOn(WebSocket socket) {
    for (final e in [..._callSockets.entries]) {
      if (!identical(e.value, socket)) continue;
      _callSockets.remove(e.key);
      final c = _calls.remove(e.key);
      // An error, never an empty answer: a guard's check that never came back must not read as "allowed".
      if (c != null && !c.isCompleted) c.completeError(const TabClosedError());
    }
  }

  /// The tabs, with their latest address and title.
  final _tabList = <BrowserTab>[];

  void _publishTabs() => tabs.value = List.unmodifiable(_tabList);

  /// The active page's socket closed: its tab went (a pop-up closed itself) or the browser did. Another tab of the
  /// session takes over; with none left the browser counts as closed.
  void _pageGone(WebSocket socket) {
    _settleCallsOn(socket);
    _parked.removeWhere((_, p) => identical(p.socket, socket));
    if (!identical(_socket, socket) || _closing) return;
    final gone = _targetId;
    final opener = gone == null ? null : _openerOf.remove(gone);
    _tabList.removeWhere((t) => t.id == gone);
    _publishTabs();
    if (_tabList.isNotEmpty && _browserSocket != null) {
      _socket = null;
      // As in a browser, the page that opened the closed tab comes back; else the newest tab.
      final next = _tabList.any((t) => t.id == opener) ? opener! : _tabList.last.id;
      unawaited(_fallBackTo(next));
      return;
    }
    _closed();
  }

  /// Switches to [id] after the active tab went; if that fails the other tabs are tried, and only with none left
  /// does the session's browser count as closed (one stuck tab must not close the rest).
  Future<void> _fallBackTo(String id) async {
    final tryOrder = [id, ..._tabList.map((t) => t.id).where((t) => t != id).toList().reversed];
    for (final t in tryOrder) {
      if (_closing || _browserSocket == null || !_tabList.any((x) => x.id == t)) continue;
      try {
        await switchTab(t);
        if (_socket != null) return;
      } on Object {
        // The next one.
      }
    }
    if (_socket == null) _closed();
  }

  /// Closes [socket], a tab switched away from, once the calls sent on it have answered (the click that opened the
  /// pop-up being switched to is one).
  Future<void> _retire(WebSocket socket) async {
    final pending = [
      for (final e in _callSockets.entries)
        if (identical(e.value, socket)) ?_calls[e.key]?.future,
    ];
    await Future.wait([for (final f in pending) f.then((_) {}, onError: (Object _) {})]);
    await socket.close();
  }

  /// Makes tab [id] the one the agent and the Preview act on. Switches run one after another, and the one in
  /// flight is known at once ([_switching]), so input meanwhile waits for it instead of opening a page.
  @override
  Future<void> switchTab(String id) {
    final prev = _switching;
    late final Future<void> done;
    done = () async {
      if (prev != null) await prev.then((_) {}, onError: (Object _) {});
      final e = _endpointUri;
      if (e == null || _closing || !_tabList.any((t) => t.id == id)) return;
      if (id == _targetId && _socket != null) return;
      // Bounded, so a page that never answers can't hold up every call after it (they all wait for the switch).
      await _switchTo(id, e).timeout(
        const Duration(seconds: 20),
        onTimeout: () => throw const BrowserError('Switching tabs took longer than 20 s.'),
      );
    }();
    _switching = done;
    unawaited(
      done.then((_) {}, onError: (Object _) {}).whenComplete(() {
        if (identical(_switching, done)) _switching = null;
      }),
    );
    return done;
  }

  Future<void> _switchTo(String id, Uri e) async {
    final old = _socket;
    final oldId = _targetId;
    final shown = dialog.value;
    _socket = null;
    _targetId = id;
    dialog.value = null;
    fileChooser.value = null;
    if (old != null) {
      // The tab left stops painting; its late frames would otherwise be acked against the new tab's socket.
      if (_casting) unawaited(_sendOn(old, 'Page.stopScreencast', const {}).then((_) {}, onError: (Object _) {}));
      // A page waiting on a dialog answers nothing on a new socket (Chrome doesn't tell a new one of the dialog
      // either): its socket is kept, and coming back to the tab takes it up again.
      if (shown != null && oldId != null) {
        _parked[oldId] = (socket: old, dialog: shown);
      } else {
        unawaited(_retire(old));
      }
    }
    if (_parked.remove(id) case final p?) {
      _socket = p.socket;
      dialog.value = p.dialog;
      await _sendOn(_browserSocket, 'Target.activateTarget', {'targetId': id});
      frames.moved();
      _publishTabs();
      // It shows its dialog and paints nothing: the cast is started without waiting (it answers with the dialog).
      if (_casting) unawaited(_castStart().then((_) {}, onError: (Object _) {}));
      return;
    }
    final socket = await WebSocket.connect('ws://${e.host}:${e.port}/devtools/page/$id');
    if (_closing || _browserSocket == null) {
      await socket.close();
      return;
    }
    _socket = socket;
    socket.listen(
      (f) => _onFrame(f, socket),
      onDone: () => _pageGone(socket),
      onError: (Object _) => _pageGone(socket),
    );
    _frameSessions.clear();
    // Pages opened from one another share a renderer: one waiting on a dialog holds up the others too. Bounded, so
    // the switch still ends (the calls stay in flight and land once the dialog is answered).
    try {
      await _enablePage().timeout(const Duration(seconds: 5));
    } on TimeoutException {
      _log.add("The tab doesn't answer yet${_parked.isEmpty ? '' : ': another tab waits on a dialog'}.");
      // Still the active tab: in front, and painting once it answers.
      await _sendOn(_browserSocket, 'Target.activateTarget', {'targetId': id}).then((_) {}, onError: (Object _) {});
      frames.moved();
      _publishTabs();
      if (_casting) unawaited(_castStart().then((_) {}, onError: (Object _) {}));
      return;
    }
    await _learnFrames();
    await _viewport();
    await _sendOn(_browserSocket, 'Target.activateTarget', {'targetId': id});
    frames.moved();
    await _refreshPage();
    _publishTabs();
    if (_casting) await _castStart();
  }

  /// Opens [url] in a new tab of the session and makes it active (the Preview's "Open link in new tab").
  @override
  Future<void> openTab(String url) async {
    await _start();
    final created = await _sendOn(_browserSocket, 'Target.createTarget', {
      'url': url,
      'newWindow': true,
      'browserContextId': ?_contextId,
    });
    final id = created['targetId'] as String?;
    if (id == null) return;
    if (!_tabList.any((t) => t.id == id)) _tabList.add((id: id, url: url, title: ''));
    await switchTab(id);
  }

  /// Closes tab [id]; the session's last tab stays.
  @override
  Future<void> closeTab(String id) async {
    if (_tabList.length < 2 || _browserSocket == null) return;
    await _sendOn(_browserSocket, 'Target.closeTarget', {'targetId': id});
  }

  /// Answers the page's dialog: OK ([accept]) or Cancel, with [text] for a prompt.
  @override
  Future<void> answerDialog({required bool accept, String? text}) async {
    final shown = dialog.value;
    if (shown == null) return;
    await _send('Page.handleJavaScriptDialog', {'accept': accept, 'promptText': ?text});
    // Chrome's javascriptDialogClosed clears it too; a newer dialog that came meanwhile stays.
    if (identical(dialog.value, shown)) dialog.value = null;
  }

  /// Gives the page's file picker (or the file input at [selector] or [ref]) the files at [paths].
  @override
  Future<void> setFiles(List<String> paths, {String? selector, String? ref}) async {
    await _start();
    final chooser = fileChooser.value;
    if (selector == null && ref == null) {
      if (chooser == null) throw const BrowserError('No file picker is open: name the file input by ref or selector.');
      fileChooser.value = null;
      await _send('DOM.setFileInputFiles', {'files': paths, 'backendNodeId': chooser.backendNodeId});
      return;
    }
    final find = ref != null
        ? 'window.__everyaiRefs && window.__everyaiRefs.get(${jsonEncode(ref)})'
        : 'document.querySelector(${jsonEncode(selector)})';
    final r = await _send('Runtime.evaluate', {'expression': find});
    final id = (r['result'] as Map<String, Object?>?)?['objectId'];
    if (id is! String) throw BrowserError('No element ${ref ?? selector} on the page now.');
    final isFile = await _send('Runtime.callFunctionOn', {
      'objectId': id,
      'functionDeclaration': 'function() { return this.tagName === "INPUT" && this.type === "file"; }',
      'returnByValue': true,
    });
    if ((isFile['result'] as Map<String, Object?>?)?['value'] != true) {
      throw BrowserError('${ref ?? selector} is not a file input.');
    }
    fileChooser.value = null;
    await _send('DOM.setFileInputFiles', {'files': paths, 'objectId': id});
  }

  /// Leaves the page's file picker without files.
  @override
  void cancelFileChooser() => fileChooser.value = null;

  /// What is at [x],[y] (CSS pixels), for the Preview's right-click menu; null when it can't be read.
  @override
  Future<PageContext?> contextAt(double x, double y) async {
    try {
      final v = await evaluate('($_contextAtJs)($x, $y)');
      if (v is! Map) return null;
      return (
        prevented: v['prevented'] == true,
        link: v['link'] as String?,
        image: v['image'] as String?,
        editable: v['editable'] == true,
        selection: '${v['selection'] ?? ''}',
        description: '${v['description'] ?? ''}',
      );
    } on BrowserError {
      return null;
    }
  }

  /// Finds [text] in the page from the selection on (wrapping), selecting and scrolling to it; how many times the
  /// page's text has it (0: none, nothing selected).
  @override
  Future<int> findText(String text, {bool backwards = false}) async {
    if (text.isEmpty) {
      await evaluate('getSelection().removeAllRanges()');
      return 0;
    }
    final v = await evaluate('''
(() => {
  const q = ${jsonEncode(text)};
  const body = (document.body && document.body.innerText || '').toLowerCase();
  let n = 0, i = 0;
  while ((i = body.indexOf(q.toLowerCase(), i)) >= 0) { n++; i += q.length; }
  if (n) window.find(q, false, $backwards, true, false, false, false);
  return n;
})()''');
    return v is num ? v.toInt() : 0;
  }

  /// Runs Chrome's editing [command] (`selectAll`, `cut`, `undo`…) in the focused field, for the Preview's menu.
  @override
  Future<void> userCommand(String command) async {
    await _start();
    await _userSend('Input.dispatchKeyEvent', {
      'type': 'rawKeyDown',
      'key': '',
      'code': '',
      'commands': [command],
    });
  }

  /// Attaches to the first window of the app at [endpoint] (see [HeadlessBrowser.attached]).
  Future<void> _attach(Uri endpoint) async {
    final browser = await WebSocket.connect(endpoint.toString());
    _browserSocket = browser;
    browser.listen(
      (f) => _onFrame(f, browser),
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
    final page = _socket!;
    page.listen((f) => _onFrame(f, page), onDone: _closed, onError: (Object _) => _closed());
    await Future.wait([_send('Page.enable'), _send('Runtime.enable'), _send('Log.enable'), _send('Network.enable')]);
    final size = await evaluate('[innerWidth, innerHeight]');
    if (size is List && size.length == 2) {
      width = (size[0] as num).round();
      height = (size[1] as num).round();
    }
    if (_casting) await _castStart();
  }

  /// A message on [from]: answers go to their calls whatever the socket; events only from the active page's socket
  /// or the browser's (a tab switched away from may still send a few).
  void _onFrame(Object? frame, WebSocket from) {
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
    if (!identical(from, _socket) && !identical(from, _browserSocket)) return;
    final method = msg['method'] as String? ?? '';
    final params = (msg['params'] as Map<String, Object?>?) ?? const {};
    switch (method) {
      case 'Page.screencastFrame':
        final m = params['metadata'] as Map<String, Object?>? ?? const {};
        // Acked on the socket it came from, whichever tab is active by then.
        final sid = (params['sessionId'] as num?)?.toInt();
        if (sid != null) _unacked[sid] = from;
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
          // The first page of an origin with stored storage: it gets its own storage, then reloads.
          final origin = webOrigin('${f['url'] ?? ''}');
          if (origin != null) _topOrigins.add(origin);
          if (origin != null && _restore.remove(origin)) unawaited(_restoreOrigin(origin));
        }
      case 'Page.navigatedWithinDocument':
        frames.moved();
        unawaited(_refreshPage(url: params['url'] as String?));
      case 'DOMStorage.domStorageItemAdded' ||
              'DOMStorage.domStorageItemUpdated' ||
              'DOMStorage.domStorageItemRemoved' ||
              'DOMStorage.domStorageItemsCleared'
          when jarHome != null && msg['sessionId'] == null:
        _storageChanged(method, params);
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
        if (jarHome != null) {
          unawaited(Future<void>.delayed(const Duration(seconds: 1), _readStorage));
        }
      case 'Target.targetInfoChanged':
        final t = params['targetInfo'] as Map<String, Object?>? ?? const {};
        if (t['targetId'] == _targetId) unawaited(_refreshPage(url: t['url'] as String?, title: t['title'] as String?));
        final i = _tabList.indexWhere((x) => x.id == t['targetId']);
        if (i >= 0) {
          _tabList[i] = (id: _tabList[i].id, url: '${t['url'] ?? ''}', title: '${t['title'] ?? ''}');
          _publishTabs();
        }
      case 'Target.targetCreated' when msg['sessionId'] == null:
        // A pop-up or a new tab one of the session's pages opened: it joins the session and becomes the active tab,
        // as in a browser. Other sessions' pages in the same Chrome are not ours.
        final t = params['targetInfo'] as Map<String, Object?>? ?? const {};
        final id = '${t['targetId']}';
        if (t['type'] == 'page' && _tabList.any((x) => x.id == t['openerId']) && !_tabList.any((x) => x.id == id)) {
          _tabList.add((id: id, url: '${t['url'] ?? ''}', title: '${t['title'] ?? ''}'));
          // Opened with a handle on its opener (window.open, a link without noopener): they share a renderer, so a
          // dialog in one holds up the other.
          if (t['canAccessOpener'] == true) _openerOf[id] = '${t['openerId']}';
          _publishTabs();
          _log.add('A new tab opened: ${t['url'] ?? ''} (now the active tab; tabs lists them).');
          unawaited(switchTab(id).catchError((Object _) {}));
        }
      case 'Target.targetDestroyed' when msg['sessionId'] == null:
        final id = params['targetId'];
        if (id != _targetId && _tabList.any((x) => x.id == id)) {
          _tabList.removeWhere((x) => x.id == id);
          _publishTabs();
        }
      case 'Page.javascriptDialogOpening' when msg['sessionId'] == null:
        final d = (
          type: '${params['type'] ?? 'alert'}',
          message: '${params['message'] ?? ''}',
          defaultPrompt: '${params['defaultPrompt'] ?? ''}',
        );
        dialog.value = d;
        _log.add('The page opened a${d.type == 'alert' ? 'n' : ''} ${d.type} dialog: "${d.message}".');
        // The page waits on it, and so would the calls in flight to it: they end now and say why. Not a tab switch's
        // own setup (Chrome tells a page's open dialog again on Page.enable), nor calls to the browser.
        if (_switching == null) {
          for (final e in [..._callSockets.entries]) {
            if (!identical(e.value, from)) continue;
            _callSockets.remove(e.key);
            final c = _calls.remove(e.key);
            if (c != null && !c.isCompleted) c.completeError(BrowserError(dialogWaitingText(d)));
          }
        }
      case 'Page.javascriptDialogClosed' when msg['sessionId'] == null:
        dialog.value = null;
      case 'Page.fileChooserOpened' when msg['sessionId'] == null:
        final node = (params['backendNodeId'] as num?)?.toInt();
        if (node != null) fileChooser.value = (backendNodeId: node, multiple: params['mode'] == 'selectMultiple');
      case 'Page.frameAttached':
        _ownFrames.add('${params['frameId']}');
      case 'Target.attachedToTarget':
        final t = params['targetInfo'] as Map<String, Object?>? ?? const {};
        if (t['type'] == 'iframe') {
          _frameSessions['${t['targetId']}'] = '${params['sessionId']}';
          // A frame of another site is a target of its own, with the frame's id.
          _ownFrames.add('${t['targetId']}');
        }
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
      // Downloads of other sessions' pages in the same Chrome are theirs. (Where downloads go is set for the whole
      // Chrome, so all of a project's sessions share it until each has a browser context of its own.)
      case 'Browser.downloadWillBegin' when !_ownsFrame('${p['frameId']}'):
        return;
      case 'Browser.downloadProgress' when !_downloads.containsKey('${p['guid']}'):
        return;
      case 'Browser.downloadWillBegin':
        _downloads['${p['guid']}'] = (name: '${p['suggestedFilename'] ?? 'download'}', done: Completer<void>());
        _download('${p['guid']}', name: '${p['suggestedFilename'] ?? 'download'}', state: 'inProgress');
      case 'Browser.downloadProgress':
        final state = p['state'];
        final total = (p['totalBytes'] as num?)?.toDouble() ?? 0;
        _download(
          '${p['guid']}',
          state: '$state',
          path: p['filePath'] as String?,
          progress: total > 0 ? ((p['receivedBytes'] as num?)?.toDouble() ?? 0) / total : 0,
        );
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

  void _download(String guid, {String? name, required String state, String? path, double progress = 0}) {
    final list = [...downloads.value];
    final i = list.indexWhere((d) => d.guid == guid);
    final was = i < 0 ? null : list[i];
    final d = (
      guid: guid,
      name: name ?? was?.name ?? 'download',
      path: path ?? was?.path,
      state: state,
      progress: state == 'completed' ? 1.0 : progress,
    );
    if (i < 0) {
      list.add(d);
    } else {
      list[i] = d;
    }
    downloads.value = list.length > 20 ? list.sublist(list.length - 20) : list;
  }

  void _closed() {
    // The page went (its last tab closed itself) or Chrome did (it crashed, or stopped for a sign-in window). While
    // the browser still answers, its cookies are read once more before its socket closes (which disposes the
    // context); otherwise the jar keeps its last reading.
    _jarTimer?.cancel();
    final context = _contextId, alive = _browserSocket;
    _contextId = null;
    // A dead browser has no sign-in to wait for; a sign-in window closed it on purpose, and that wait goes on.
    if (attachTo != null || !host.closedForSignIn) loginWall.stop();
    // Tabs still open (a switch to one failed) close with the session's browser instead of staying in Chrome.
    final browser = _browserSocket;
    if (browser != null && attachTo == null) {
      for (final t in _tabList) {
        unawaited(_sendOn(browser, 'Target.closeTarget', {'targetId': t.id}).then((_) {}, onError: (Object _) {}));
      }
    }
    _release();
    _socket = null;
    _targetId = null;
    // Late enough for the last cookie read above and the tabs' closes.
    unawaited(Future<void>.delayed(const Duration(milliseconds: 2500), () => browser?.close()));
    _browserSocket = null;
    _tabList.clear();
    _publishTabs();
    dialog.value = null;
    fileChooser.value = null;
    for (final d in _downloads.values) {
      d.done.complete();
    }
    _downloads.clear();
    _frameSessions.clear();
    _ownFrames.clear();
    for (final p in _parked.values) {
      unawaited(p.socket.close());
    }
    _parked.clear();
    for (final c in _calls.values) {
      if (!c.isCompleted) c.completeError(const BrowserError('The browser closed.'));
    }
    _calls.clear(); // After the calls above ended: this read is the last one.
    unawaited(() async {
      if (context != null && alive != null) {
        try {
          final r = await _sendOn(alive, 'Storage.getCookies', {
            'browserContextId': context,
          }).timeout(const Duration(seconds: 2));
          _jar = (
            cookies: [
              for (final c in (r['cookies'] as List?) ?? const [])
                if (c is Map) c.cast<String, Object?>(),
            ],
            storage: _jar.storage,
          );
        } on Object {
          // Gone already.
        }
      }
      await _writeJar();
    }());
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
    _callSockets[id] = socket;
    unawaited(c.future.then((_) {}, onError: (Object _) {}).whenComplete(() => _callSockets.remove(id)));
    socket.add(jsonEncode({'id': id, 'method': method, 'params': params, 'sessionId': ?session}));
    return c.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _calls.remove(id);
        _callSockets.remove(id);
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
  @override
  List<String> takeLog() {
    final out = [..._log];
    _logged.addAll(out);
    if (_logged.length > 50) _logged.removeRange(0, _logged.length - 50);
    _log.clear();
    return out;
  }

  final _logged = <String>[];

  /// The last 50 lines the page logged, read or not.
  @override
  List<String> get history => [..._logged, ..._log];

  @override
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

  /// The page's address and whether it shows a password field (for the login wall); null when it can't tell (a
  /// dialog, a page loading).
  @override
  Future<LoginProbe?> loginProbe() async {
    if (_socket == null || dialog.value != null) return null;
    try {
      final r = await _send('Runtime.evaluate', {
        'expression':
            '[location.href, [...document.querySelectorAll("input[type=password]")]'
            '.some(e => e.getClientRects().length > 0 && getComputedStyle(e).visibility !== "hidden")]',
        'returnByValue': true,
        'objectGroup': 'everyai-wall',
      }).timeout(const Duration(seconds: 3));
      final v = (r['result'] as Map<String, Object?>?)?['value'];
      if (v is List && v.length == 2 && v[0] is String) return (url: v[0] as String, password: v[1] == true);
    } on Object {
      // Unknown this time.
    }
    return null;
  }

  /// The page's address and title. [bare]: the address without its query and fragment (after a sign-in, where they
  /// can carry tokens).
  @override
  Future<String> describe({bool bare = false}) async {
    final v = await evaluate(
      bare
          ? 'JSON.stringify({url: location.origin + location.pathname, title: document.title})'
          : 'JSON.stringify({url: location.href, title: document.title})',
    );
    final m = jsonDecode(v as String) as Map<String, Object?>;
    return '${m['title']} — ${m['url']}';
  }

  @override
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
  @override
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
  @override
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
  @override
  Future<({double x, double y})> scrollOffset() async {
    final v = await evaluate('[scrollX, scrollY]');
    return v is List ? (x: (v[0] as num).toDouble(), y: (v[1] as num).toDouble()) : (x: 0.0, y: 0.0);
  }

  /// The page's elements now (see [pageSnapshotJs]), for what an action changed; empty when the page gives none.
  @override
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
  @override
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
  @override
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
  @override
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
  @override
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
  @override
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

  @override
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
  @override
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

  @override
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
  /// Closes the page. [captured]: the caller read the jar just now (at quit), so it is saved without reading it again.
  @override
  Future<void> close({bool captured = false}) async {
    _closing = true;
    try {
      await _close(captured: captured);
    } finally {
      _closing = false;
    }
  }

  Future<void> _close({bool captured = false}) async {
    await _switched();
    _jarTimer?.cancel();
    if (running && !_forget && !_noSave) {
      await saveJar(captured: captured).timeout(const Duration(seconds: 2), onTimeout: () {});
    }
    final targets = {for (final t in _tabList) t.id, ?_targetId};
    if (_browserSocket != null && attachTo == null) {
      for (final target in targets) {
        try {
          await _sendOn(_browserSocket, 'Target.closeTarget', {'targetId': target}).timeout(const Duration(seconds: 3));
        } on Object {
          // Gone already.
        }
      }
    }
    _tabList.clear();
    _publishTabs();
    dialog.value = null;
    fileChooser.value = null;
    final socket = _socket;
    _socket = null;
    _targetId = null;
    await socket?.close();
    final browserSocket = _browserSocket;
    _browserSocket = null;
    await browserSocket?.close();
    _contextId = null;
    if (attachTo == null) _release();
  }

  /// The page's size now, in CSS pixels.
  @override
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
  @override
  Future<void> startScreencast() async {
    _casting = true;
    await _start();
    await _castStart();
  }

  Future<void> _castStart() async {
    await _send('Page.startScreencast', {'format': 'jpeg', 'quality': 72, 'maxWidth': width, 'maxHeight': height});
    // Chrome sends frames on changes only: a still page would show nothing until it moves. One picture now.
    // A page waiting on a dialog paints nothing and runs no script: the picture would wait out the call's timeout.
    if (dialog.value != null || dialogHoldingThis != null) return;
    // Bounded: a dialog that opened just now isn't known yet, and a switch casts through here (it must end).
    try {
      final shot = await _send('Page.captureScreenshot', {
        'format': 'jpeg',
        'quality': 72,
      }).timeout(const Duration(seconds: 4));
      // Straight to the page, not through [evaluate]: that waits for a tab switch in flight, and a switch casts
      // through here (it would wait for itself).
      final r = await _send('Runtime.evaluate', {
        'expression': 'scrollY',
        'returnByValue': true,
      }).timeout(const Duration(seconds: 4));
      final scroll = (r['result'] as Map<String, Object?>?)?['value'];
      _screencast.add((
        jpeg: base64Decode(shot['data']! as String),
        width: width,
        height: height,
        scrollY: scroll is num ? scroll.toDouble() : 0,
        session: 0,
      ));
    } on TimeoutException {
      // The page is waiting on something (a dialog); Chrome's own frames follow once it paints.
    }
  }

  /// Starts the screencast again with a fresh picture (the Preview saw the page change and no frame came).
  @override
  Future<void> refreshScreencast() async {
    if (!_casting || _socket == null) return;
    try {
      await _send('Page.bringToFront');
      await _send('Page.stopScreencast');
      await _castStart();
    } on Object {
      // Closing.
    }
  }

  @override
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
  @override
  void ackFrame(int session) {
    // 0: the picture taken at the start, not one of Chrome's frames.
    if (_socket == null || session == 0) return;
    // The socket that sent the frame (a tab since left has stopped casting: its ack is dropped, and a stale id
    // must never reach the new tab's screencast).
    final from = _unacked.remove(session);
    if (from == null || !identical(from, _socket)) return;
    unawaited(
      _sendOn(from, 'Page.screencastFrameAck', {
        'sessionId': session,
      }).catchError((Object _) => const <String, Object?>{}),
    );
  }

  /// The socket each frame not yet acked came from, by its session number.
  final _unacked = <int, WebSocket>{};

  /// A mouse event from the user's view, in CSS pixels: `mouseMoved`, `mousePressed`, `mouseReleased`,
  /// `mouseWheel`.
  @override
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
    // A dialog holds the page: the user answers it first.
    if (dialog.value != null || dialogHoldingThis != null) return;
    await _start();
    await _userSend('Input.dispatchMouseEvent', {
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
  @override
  Future<void> userKey(
    String type, {
    required String key,
    required String code,
    int keyCode = 0,
    String? text,
    int modifiers = 0,
    List<String> commands = const [],
  }) async {
    if (dialog.value != null || dialogHoldingThis != null) return;
    await _start();
    await _userSend('Input.dispatchKeyEvent', {
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
  @override
  Future<void> userText(String text) async {
    if (dialog.value != null || dialogHoldingThis != null) return;
    await _start();
    await _userSend('Input.insertText', {'text': text});
  }

  /// [_send] for the user's own input: a tab that closed on it (a pop-up's Close button) is no error.
  Future<void> _userSend(String method, Map<String, Object?> params) async {
    try {
      await _send(method, params);
    } on TabClosedError {
      // Closed by this very input.
    }
  }

  /// The page's selected text (the user's copy).
  @override
  Future<String> selectedText() async {
    final v = await evaluate('String(getSelection ? getSelection() : "")');
    return v is String ? v : '';
  }

  /// Goes to [url] for the user (the address bar).
  @override
  Future<void> userOpen(String url) async {
    await _start();
    await _send('Page.navigate', {'url': url});
  }

  @override
  Future<void> back() => _history(-1);
  @override
  Future<void> forward() => _history(1);

  @override
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
  @override
  Future<void> setSize(int w, int h) async {
    await resize(w, h);
    if (_casting) await _castStart();
  }
}

/// Records, on every page, whether the page took the last right-click for its own menu (preventDefault): then the
/// Preview shows none of its own.
const _contextTrackerJs = '''
(() => {
  if (window.__everyaiCtxTracker) return;
  window.__everyaiCtxTracker = true;
  addEventListener('contextmenu', (e) => { window.__everyaiCtxPrevented = e.defaultPrevented; });
})()''';

/// What is at a point, for the right-click menu: a link, a picture, an editable field, the selection, and a short
/// description of the element (for "Ask the agent about this").
const _contextAtJs = r'''
(x, y) => {
  let el = document.elementFromPoint(x, y);
  while (el && el.shadowRoot) {
    const under = el.shadowRoot.elementFromPoint(x, y);
    if (!under || under === el) break;
    el = under;
  }
  if (!el) return null;
  const a = el.closest && el.closest('a[href]');
  const img = el.closest && el.closest('img');
  const field = el.closest && el.closest('input, textarea, [contenteditable=""], [contenteditable="true"]');
  const editable = !!field && !(field.readOnly || field.disabled);
  const path = [];
  for (let e = el; e && e.nodeType === 1 && path.length < 4; e = e.parentElement) {
    let part = e.tagName.toLowerCase();
    if (e.id) { path.unshift(part + '#' + e.id); break; }
    const cls = [...e.classList].slice(0, 2).join('.');
    if (cls) part += '.' + cls;
    path.unshift(part);
  }
  const text = (el.innerText || el.value || el.getAttribute('aria-label') || el.getAttribute('alt') || '')
    .trim().replace(/\s+/g, ' ').slice(0, 80);
  return {
    prevented: window.__everyaiCtxPrevented === true,
    link: a ? a.href : null,
    image: img ? (img.currentSrc || img.src) : null,
    editable,
    selection: String(getSelection()),
    description: '<' + el.tagName.toLowerCase() + '>' + (text ? ' "' + text + '"' : '') + ' (' + path.join(' > ') + ')',
  };
}''';

/// Page helpers for the guards (see [pageFieldGuardJs]); [_guard] looks into other origins' frames itself.
const _guardJs = pageFieldGuardJs;

/// The origin a DOMStorage event's [storageId] is the first-party local storage of, or null: session storage, and
/// storage partitioned under another top-level site (a key with a '^' part: a frame embedded in another site, even
/// one in the page's own renderer), are not that origin's own.
@visibleForTesting
String? storageEventOrigin(Map<String, Object?> storageId) {
  if (storageId['isLocalStorage'] != true) return null;
  final key = storageId['storageKey'];
  if (key is String && key.contains('^')) return null;
  return webOrigin('${storageId['securityOrigin'] ?? key ?? ''}');
}

/// Whether pages at [a] and [b] (in one browsing group) may run in one renderer: Chrome isolates sites, so pages of
/// different sites never do. Errs towards yes: a page with no web address (about:blank inherits its opener's), and
/// hosts whose last two labels match (a superset of one registrable domain).
@visibleForTesting
bool maySharePageProcess(String a, String b) {
  String? site(String url) {
    final u = Uri.tryParse(url);
    if (u == null || (u.scheme != 'http' && u.scheme != 'https') || u.host.isEmpty) return null;
    final host = u.host.toLowerCase();
    if (InternetAddress.tryParse(host) != null || !host.contains('.')) return host;
    final labels = host.split('.');
    return labels.sublist(labels.length - 2).join('.');
  }

  final x = site(a), y = site(b);
  return x == null || y == null || x == y;
}
