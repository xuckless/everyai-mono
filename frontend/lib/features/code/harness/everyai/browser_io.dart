// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueNotifier, visibleForTesting;

import '../../live/frames.dart';
import '../../live/browser_jar.dart';
import '../../live/key_map.dart';
import '../../live/login_wall.dart';
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

/// A tab of a session's browser: the session's own page, or one a page of it opened (a pop-up, a link to a new tab).
typedef BrowserTab = ({String id, String url, String title});

/// A dialog the page opened and waits on (`alert`, `confirm`, `prompt`, `beforeunload`).
typedef PageDialog = ({String type, String message, String defaultPrompt});

/// A file picker the page opened (a click on a file input): what to set the files on.
typedef FileChooser = ({int backendNodeId, bool multiple});

/// A download of the session's browser, newest last.
typedef BrowserDownload = ({String guid, String name, String? path, String state, double progress});

/// What is under the pointer for the Preview's right-click menu.
typedef PageContext = ({
  bool prevented,
  String? link,
  String? image,
  bool editable,
  String selection,
  String description,
});

/// A headless Chrome the session owns, driven over the DevTools protocol:
/// its own profile under the session's scratch folder (never the user's
/// browser or cookies), started on first use and stopped with the session.
/// The agent opens pages (`http://localhost…`, `file://…`), clicks and types
/// like a user (real mouse and key events), takes screenshots, runs scripts
/// and reads what the page logged. It never types into password or payment
/// fields nor submits their forms ([_guardJs]), and its downloads land in
/// [downloadDir].
final class HeadlessBrowser {
  HeadlessBrowser({required this.profileDir, this.executable, this.jarHome}) : attachTo = null;

  /// Drives a page of a Chromium-based app that is already running (an Electron app started with
  /// `--remote-debugging-port`), at its browser-level DevTools [endpoint]: the app's own window, at its own size.
  /// Closing detaches; the app keeps running.
  HeadlessBrowser.attached(Uri endpoint) : attachTo = endpoint, profileDir = '', executable = null, jarHome = null;

  /// Where the session's own cookie jar is kept: with one, the browser runs in a context of its own in the
  /// project's Chrome (cookies and storage apart from other sessions'), started from the jar and saved back to it.
  /// Without one, it uses the profile's shared cookies.
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
  final usedLogins = <String, String>{};

  /// Keeps the jar current while running (a Chrome that stops all at once loses at most this much).
  Timer? _jarTimer;

  /// Set by [forgetJar]: the session is gone, so its jar is deleted rather than saved.
  var _forget = false;

  /// The login wall: the agent's call waits on a sign-in page until the user signs in or skips.
  final loginWall = LoginWall();

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

  /// The session's tabs, in the order they opened; the active one is [activeTab].
  final tabs = ValueNotifier<List<BrowserTab>>(const []);

  /// The dialog the active page waits on, or null.
  final dialog = ValueNotifier<PageDialog?>(null);

  /// The file picker the active page opened, or null.
  final fileChooser = ValueNotifier<FileChooser?>(null);

  /// This session's downloads (the last 20).
  final downloads = ValueNotifier<List<BrowserDownload>>(const []);

  /// The tab the agent and the Preview act on.
  String? get activeTab => _targetId;

  /// The browser's DevTools address (to connect to another tab).
  Uri? _endpointUri;

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
      _enablePage(),
      _sendOn(_browserSocket, 'Target.setDiscoverTargets', {'discover': true}),
      _sendOn(_browserSocket, 'Browser.setDownloadBehavior', {
        'behavior': dir == null ? 'deny' : 'allow',
        'downloadPath': ?dir,
        'eventsEnabled': true,
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
      // No keychain (a test without one), or no jar yet: a clean start.
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

  /// The jar as it is now: the context's cookies and the storage read from its pages.
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

  /// Saves the jar now (captured first while running).
  Future<void> saveJar() async {
    if (running) await captureJar();
    await _writeJar();
  }

  /// The session was removed: its jar is deleted, and nothing is saved when the browser closes.
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

  /// Signs the session out of [site] (null: every site): its cookies and storage leave the jar and the browser.
  Future<void> clearJar({String? site}) async {
    await _loadJar();
    if (running && _browserSocket != null && _contextId != null) {
      final all = await captureJar();
      final gone = site == null ? all.cookies : jarForSite(all, site).cookies;
      if (site == null) {
        await _sendOn(_browserSocket, 'Storage.clearCookies', {'browserContextId': _contextId});
      } else {
        for (final c in gone) {
          await _send('Network.deleteCookies', {
            'name': c['name'],
            'domain': c['domain'],
            'path': c['path'],
            if (c['partitionKey'] case final Map<String, Object?> k) 'partitionKey': k,
          });
        }
      }
      final here = Uri.tryParse(page.value.url);
      if (here != null && here.hasAuthority && (site == null || siteOf(here.host) == site)) {
        await _send('Runtime.evaluate', {
          'expression': 'try { localStorage.clear(); sessionStorage.clear(); } catch (_) {}',
        });
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
    if (running) await reload();
  }

  /// The sites this session is signed in to (it has cookies for), from the last reading.
  List<String> get signedInSites => jarSites(_jar);

  /// The sign-ins in the project's shared profile (the "Sign in in a window" Chrome, and sign-ins made before
  /// sessions had jars of their own): its cookies for [site], or for every site.
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
      _send('Page.addScriptToEvaluateOnNewDocument', {'source': _contextTrackerJs}),
    ]);
    // Not waited for: a page that shows a dialog runs no script until it is answered.
    unawaited(_send('Runtime.evaluate', {'expression': _contextTrackerJs}).then((_) {}, onError: (Object _) {}));
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
    if (!identical(_socket, socket) || _closing) return;
    final gone = _targetId;
    _tabList.removeWhere((t) => t.id == gone);
    _publishTabs();
    if (_tabList.isNotEmpty && _browserSocket != null) {
      _socket = null;
      unawaited(switchTab(_tabList.last.id).catchError((Object _) => _closed()));
      return;
    }
    _closed();
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
  Future<void> switchTab(String id) {
    final prev = _switching;
    late final Future<void> done;
    done = () async {
      if (prev != null) await prev.then((_) {}, onError: (Object _) {});
      final e = _endpointUri;
      if (e == null || _closing || !_tabList.any((t) => t.id == id)) return;
      if (id == _targetId && _socket != null) return;
      await _switchTo(id, e);
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
    _socket = null;
    _targetId = id;
    dialog.value = null;
    fileChooser.value = null;
    if (old != null) unawaited(_retire(old));
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
    await _enablePage();
    await _viewport();
    await _sendOn(_browserSocket, 'Target.activateTarget', {'targetId': id});
    frames.moved();
    await _refreshPage();
    _publishTabs();
    if (_casting) await _castStart();
  }

  /// Opens [url] in a new tab of the session and makes it active (the Preview's "Open link in new tab").
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
  Future<void> closeTab(String id) async {
    if (_tabList.length < 2 || _browserSocket == null) return;
    await _sendOn(_browserSocket, 'Target.closeTarget', {'targetId': id});
  }

  /// Answers the page's dialog: OK ([accept]) or Cancel, with [text] for a prompt.
  Future<void> answerDialog({required bool accept, String? text}) async {
    if (dialog.value == null) return;
    dialog.value = null;
    await _send('Page.handleJavaScriptDialog', {'accept': accept, 'promptText': ?text});
  }

  /// Gives the page's file picker (or the file input at [selector] or [ref]) the files at [paths].
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
  void cancelFileChooser() => fileChooser.value = null;

  /// What is at [x],[y] (CSS pixels), for the Preview's right-click menu; null when it can't be read.
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
          if (origin != null && _restore.remove(origin)) unawaited(_restoreOrigin(origin));
        }
      case 'Page.navigatedWithinDocument':
        frames.moved();
        unawaited(_refreshPage(url: params['url'] as String?));
      case 'Page.frameStartedLoading':
        // The page is about to go: what it stored last (a token an OAuth callback wrote before it redirected).
        if (jarHome != null && params['frameId'] == _targetId) unawaited(_readStorage());
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
      // Downloads of other sessions' pages in the same Chrome are theirs.
      case 'Browser.downloadWillBegin' when !_tabList.any((t) => t.id == p['frameId']):
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
    // Chrome went at once (it crashed, or stopped for a sign-in window): the jar keeps its last reading.
    _jarTimer?.cancel();
    _contextId = null;
    unawaited(_writeJar());
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
    unawaited(Future<void>.delayed(const Duration(milliseconds: 200), () => browser?.close()));
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

  /// The page's address and whether it shows a password field (for the login wall); null when it can't tell (a
  /// dialog, a page loading).
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
    _closing = true;
    try {
      await _close();
    } finally {
      _closing = false;
    }
  }

  Future<void> _close() async {
    await _switched();
    _jarTimer?.cancel();
    if (running && !_forget) await saveJar().timeout(const Duration(seconds: 2), onTimeout: () {});
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

  /// Starts the screencast again with a fresh picture (the Preview saw the page change and no frame came).
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
    // A dialog holds the page: the user answers it first.
    if (dialog.value != null) return;
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
  Future<void> userKey(
    String type, {
    required String key,
    required String code,
    int keyCode = 0,
    String? text,
    int modifiers = 0,
    List<String> commands = const [],
  }) async {
    if (dialog.value != null) return;
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
  Future<void> userText(String text) async {
    if (dialog.value != null) return;
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

/// What the agent is told while the page waits on [d].
String dialogWaitingText(PageDialog d) {
  final what = switch (d.type) {
    'beforeunload' => 'asks whether to leave the page',
    'confirm' => 'asks to confirm',
    'prompt' => 'asks for text',
    _ => 'shows an alert',
  };
  return 'The page $what: "${d.message}". It waits until the dialog is answered: browser {action: "dialog", '
      'accept: true or false${d.type == 'prompt' ? ', text' : ''}}, or the user answers it in the Preview.';
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

class BrowserError implements Exception {
  const BrowserError(this.message, {this.fromPage = false});
  final String message;

  /// The message quotes the page (a script's exception), so it goes in the page's untrusted block.
  final bool fromPage;
  @override
  String toString() => message;
}

/// [url]'s origin when it is a web page (http or https), else null (file:, about:, data:).
String? webOrigin(String url) {
  final u = Uri.tryParse(url);
  return u != null && (u.scheme == 'http' || u.scheme == 'https') && u.host.isNotEmpty ? u.origin : null;
}

/// The tab a call went to closed before it answered (a pop-up that closed itself on the click).
final class TabClosedError extends BrowserError {
  const TabClosedError() : super('The tab closed before it answered.');
}
