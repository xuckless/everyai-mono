// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../harness/everyai/browser_io.dart' show maySharePageProcess, pageContextAtJs;
import 'browser_jar.dart';
import 'browser_page.dart';
import 'frames.dart';
import 'key_map.dart';
import 'live_session.dart';
import 'login_wall.dart';
import 'page_snapshot.dart';
import 'webview_model.dart';
import 'webview_native.dart';
import 'webview_page_js.dart';

/// One tab of a [WebviewBrowser]: a native webview of its own (the plugin's), the session's page or one a page of
/// it opened. [life] says where its view is (see [TabLife]).
final class WebTab {
  WebTab._(this.id, this.token, {this.opener, this.windowId});

  final String id;

  /// What the page carries in our script world, for the native side to find this view.
  final String token;

  /// The tab that opened this one with a handle on it (window.open, a link without noopener).
  final String? opener;

  /// The plugin's window id when a page opened this tab.
  final int? windowId;

  /// Keeps the view alive while no widget shows it. Its id is the view's once the Preview first showed it.
  final keepAlive = InAppWebViewKeepAlive();

  HeadlessInAppWebView? _headless;

  /// The plugin's id of the view once the Preview showed it (its channel's name).
  Object? _viewId;
  InAppWebViewController? _controller;
  TabLife _life = TabLife.starting;
  TabLife get life => _life;

  String url = 'about:blank';
  String title = '';
  bool loading = false;
  bool canBack = false;
  bool canForward = false;

  /// The dialog the page waits on, and how it is answered.
  ({PageDialog dialog, Completer<({bool accept, String? text})> answer})? _pending;

  /// A dialog opening (a [PageDialog]) or the tab closing (`#closed`): calls in flight to it end.
  // Lives as long as the tab object.
  // ignore: close_sinks
  final _interrupts = StreamController<Object>.broadcast();

  /// Main-frame loads finishing (null) or failing (the error), for [WebviewBrowser.open].
  // ignore: close_sinks
  final _loads = StreamController<String?>.broadcast();

  /// Changes of [life], for the Preview waiting on a parked view.
  final lifeChanges = ValueNotifier<int>(0);
}

/// A Code session's browser in the OS webview (WKWebView on macOS, WebView2 on Windows), through flutter_inappwebview:
/// a real browser the user drives natively in the Preview (focus, IME, passkeys, copy and paste are the system's), and
/// the agent drives by script. Each tab is a native view of its own. A tab runs offscreen as the plugin's headless
/// webview until the Preview shows it; the Preview embeds the very same view (no reload), and when it lets go the
/// view goes back into the app's window offscreen ([WebviewNative.park]) so its timers, focus and drawing go on.
///
/// Each session's browser has a cookie store of its own (a non-persistent WebKit store on macOS, its own WebView2
/// user data folder on Windows), filled from and saved to the session's sealed jar, like the Chrome backend's
/// disposable browser context. The agent's helpers run in a script world of their own ("everyai"), which the
/// page's scripts can't see or change; its `eval` runs in the page's.
final class WebviewBrowser implements BrowserPage {
  WebviewBrowser({this.jarHome, WebviewNative? native, String? tempRoot})
    : _nativeOverride = native,
      _envRoot = tempRoot;

  final WebviewNative? _nativeOverride;
  final String? _envRoot;
  WebviewNative? _native;
  WebViewEnvironment? _env;
  Directory? _envDir;

  static bool get _mac => defaultTargetPlatform == TargetPlatform.macOS;

  static final _world = ContentWorld.world(name: 'everyai');

  @override
  final JarHome? jarHome;

  @override
  final control = LiveControl();

  @override
  final frames = FrameBook();

  @override
  final page = ValueNotifier<PageState>((url: '', title: '', canBack: false, canForward: false, loading: false));

  @override
  final tabs = ValueNotifier<List<BrowserTab>>(const []);

  @override
  final dialog = ValueNotifier<PageDialog?>(null);

  @override
  final fileChooser = ValueNotifier<FileChooser?>(null);

  @override
  final downloads = ValueNotifier<List<BrowserDownload>>(const []);

  @override
  final loginWall = LoginWall();

  @override
  final usedLogins = <String, String>{};

  @override
  String? downloadDir;

  // ------------------------------------------------------------------------------------------------- lifecycle

  final _life = ValueNotifier<WebviewLife>(const WebviewNotCreated());

  /// Where the browser is (see [WebviewLife]); the Preview follows it.
  ValueListenable<WebviewLife> get life => _life;

  /// Moves refused by [webviewEdge] (a bug if any): kept for tests and the report.
  final refusedMoves = <String>[];

  var _generation = 0;

  void _set(WebviewLife next) {
    if (!webviewEdge(_life.value, next)) {
      refusedMoves.add('${_life.value.runtimeType} → ${next.runtimeType}');
      assert(false, 'WebviewBrowser: refused ${_life.value.runtimeType} → ${next.runtimeType}');
      return;
    }
    _life.value = next;
  }

  void _moveTab(WebTab t, TabLife to) {
    if (!t._life.canMoveTo(to)) {
      refusedMoves.add('tab ${t.id}: ${t._life.name} → ${to.name}');
      return;
    }
    t._life = to;
    t.lifeChanges.value++;
  }

  @override
  bool get running => _life.value is WebviewRunning;

  Future<void> _start() async {
    while (true) {
      switch (_life.value) {
        case WebviewRunning():
          return;
        case WebviewStarting(:final ready):
          return ready;
        case WebviewClosing(:final done):
          await done;
        case WebviewNotCreated() || WebviewClosed():
          final gen = ++_generation;
          final ready = Completer<void>();
          ready.future.ignore();
          _set(WebviewStarting(gen, ready.future));
          try {
            await _launch(gen);
            ready.complete();
          } on Object catch (e, s) {
            if (gen == _generation && _life.value is WebviewStarting) _set(const WebviewClosed());
            ready.completeError(e is BrowserError ? e : BrowserError('The browser did not start: $e'), s);
          }
          return ready.future;
      }
    }
  }

  Future<void> _launch(int gen) async {
    if (!_mac) {
      // WebView2: a user data folder of the session's own is its own cookie store.
      final dir = await Directory(_envRoot ?? '${Directory.systemTemp.path}/everyai-webview')
          .create(recursive: true)
          .then((d) => d.createTemp('session-'));
      _envDir = dir;
      _env = await WebViewEnvironment.create(settings: WebViewEnvironmentSettings(userDataFolder: dir.path));
    }
    _native = _nativeOverride ?? WebviewNative.forPlatform(macOS: _mac, environment: _env);
    _nativeEvents ??= _native!.events.listen(_onNative);
    control.addListener(_syncLock);
    await _loadJar();
    _restore
      ..clear()
      ..addAll(_jar.storage.keys);
    final t = await _newTab();
    if (gen != _generation) throw const BrowserError('The browser was closed while it started.');
    _active = t;
    final cookies = [for (final c in _jar.cookies) ?nativeCookieOf(c)];
    if (cookies.isNotEmpty) await _native!.setCookies(t.token, cookies);
    _set(WebviewRunning(gen, shown: false));
    _publish();
    _jarTimer?.cancel();
    if (jarHome != null) _jarTimer = Timer.periodic(const Duration(seconds: 30), (_) => unawaited(_keepJar()));
  }

  // The browser object lives for the session; so does its subscription.
  // ignore: cancel_subscriptions
  StreamSubscription<WebviewNativeEvent>? _nativeEvents;

  // ------------------------------------------------------------------------------------------------- tabs

  final _tabs = <WebTab>[];
  WebTab? _active;
  var _tabSeq = 0;

  /// The tab the Preview shows and the agent acts on.
  WebTab? get activeWebTab => _active;

  @override
  String? get activeTab => _active?.id;

  static String _newToken() {
    final r = Random.secure();
    return List.generate(20, (_) => r.nextInt(36).toRadixString(36)).join();
  }

  /// Makes a tab running offscreen: the session's first page, or a page's pop-up ([windowId]).
  Future<WebTab> _newTab({int? windowId, String? opener}) async {
    final t = WebTab._('t${++_tabSeq}', _newToken(), opener: opener, windowId: windowId);
    _tabs.add(t);
    final created = Completer<void>();
    t._headless = HeadlessInAppWebView(
      initialSize: Size(_agentW.toDouble(), _agentH.toDouble()),
      windowId: windowId,
      webViewEnvironment: _env,
      initialSettings: _settings(),
      initialUserScripts: _scripts(),
      initialData: windowId == null
          ? InAppWebViewInitialData(data: '<!doctype html><title></title>', baseUrl: WebUri('about:blank'))
          : null,
      onWebViewCreated: (c) {
        t._controller = c;
        if (!created.isCompleted) created.complete();
      },
      onLoadStart: (c, url) => _onLoadStart(t, url),
      onLoadStop: (c, url) => _onLoadStop(t, url),
      onReceivedError: (c, req, err) => _onError(t, req, err),
      onReceivedHttpError: (c, req, res) => _onHttpError(t, req, res),
      onUpdateVisitedHistory: (c, url, reload) => _onHistory(t, url),
      onTitleChanged: (c, title) => _onTitle(t, title),
      onConsoleMessage: (c, m) => _onConsole(m),
      onCreateWindow: (c, a) => _onCreateWindow(t, a),
      onCloseWindow: (c) => _onCloseWindow(t),
      onJsAlert: (c, r) => _onAlert(t, r),
      onJsConfirm: (c, r) => _onConfirm(t, r),
      onJsPrompt: (c, r) => _onPrompt(t, r),
      onDownloadStartRequest: (c, r) => unawaited(_download(t, r.url, r.suggestedFilename)),
    );
    try {
      await t._headless!.run();
      await created.future.timeout(const Duration(seconds: 15));
    } on Object catch (e) {
      _tabs.remove(t);
      _moveTab(t, TabLife.closed);
      throw BrowserError('The webview did not start: $e');
    }
    _moveTab(t, TabLife.headless);
    await _bind(t);
    return t;
  }

  /// The Preview's view of [t]: the tab's own webview (made offscreen, or kept alive while hidden), with the same
  /// callbacks as offscreen. Shown with [onShown] once it is on screen.
  Widget tabView(WebTab t, {Key? key}) => InAppWebView(
    key: key,
    headlessWebView: t._headless?.isRunning() == true ? t._headless : null,
    keepAlive: t.keepAlive,
    webViewEnvironment: _env,
    initialSettings: _settings(),
    initialUserScripts: _scripts(),
    onWebViewCreated: (c) => _tabShown(t, c),
    onLoadStart: (c, url) => _onLoadStart(t, url),
    onLoadStop: (c, url) => _onLoadStop(t, url),
    onReceivedError: (c, req, err) => _onError(t, req, err),
    onReceivedHttpError: (c, req, res) => _onHttpError(t, req, res),
    onUpdateVisitedHistory: (c, url, reload) => _onHistory(t, url),
    onTitleChanged: (c, title) => _onTitle(t, title),
    onConsoleMessage: (c, m) => _onConsole(m),
    onCreateWindow: (c, a) => _onCreateWindow(t, a),
    onCloseWindow: (c) => _onCloseWindow(t),
    onJsAlert: (c, r) => _onAlert(t, r),
    onJsConfirm: (c, r) => _onConfirm(t, r),
    onJsPrompt: (c, r) => _onPrompt(t, r),
    onDownloadStartRequest: (c, r) => unawaited(_download(t, r.url, r.suggestedFilename)),
  );

  /// The Preview put [t]'s view on screen: its widget's controller drives it now.
  void _tabShown(WebTab t, InAppWebViewController c) {
    if (t._life == TabLife.closed) return;
    t._controller = c;
    t._viewId = c.getViewId();
    // The plugin made the headless view the widget's: it is no longer running offscreen.
    t._headless = null;
    _moveTab(t, TabLife.shown);
    _native?.setShown(t.token, true).ignore();
    _native?.setLocked(t.token, !control.phase.userMayAct).ignore();
    if (_life.value case WebviewRunning(:final generation, shown: false) when identical(t, _active)) {
      _set(WebviewRunning(generation, shown: true));
    }
  }

  /// The Preview let go of [t]'s view (its widget is gone): a controller of our own takes over its events, and the
  /// view goes back into the window offscreen.
  void tabHidden(WebTab t) {
    if (t._life != TabLife.shown) return;
    _moveTab(t, TabLife.parking);
    // The widget's controller stopped listening when it went; one of ours, on the same view, listens now.
    final params = (tabView(t) as InAppWebView).platform.params;
    t._controller = InAppWebViewController.fromPlatformCreationParams(
      params: PlatformInAppWebViewControllerCreationParams(id: t._viewId, webviewParams: params),
    );
    _native?.setShown(t.token, false).ignore();
    if (_life.value case WebviewRunning(:final generation, shown: true)) {
      _set(WebviewRunning(generation, shown: false));
    }
    unawaited(() async {
      final ok = await _native!.park(t.token, _agentW, _agentH).catchError((Object _) => false);
      if (t._life == TabLife.parking) _moveTab(t, ok ? TabLife.parked : TabLife.parked);
      if (!ok) _log.add('The tab ${t.id} could not be kept in the window offscreen; it may run slowly until shown.');
    }());
  }

  /// The Preview's view size (the pane's room): while the active tab is shown, the page takes this size.
  void paneSize(Size s) {
    final w = s.width.round(), h = s.height.round();
    if (w == _paneW && h == _paneH) return;
    _paneW = w;
    _paneH = h;
  }

  var _paneW = 0, _paneH = 0;

  bool get _shown => _active?._life == TabLife.shown;

  /// The size the agent asked for (or the Preview's size menu): the page's size offscreen.
  var _agentW = 1280, _agentH = 800;

  /// The size the Preview's size menu picked, for its box.
  final requestedSize = ValueNotifier<Size>(const Size(1280, 800));

  @override
  int get width => _shown && _paneW > 0 ? _paneW : _agentW;

  @override
  int get height => _shown && _paneH > 0 ? _paneH : _agentH;

  @override
  ViewGeometry get geometry => ViewGeometry(width, height);

  Future<void> _bind(WebTab t) async {
    for (var attempt = 0; attempt < 4; attempt++) {
      try {
        await t._controller?.evaluateJavascript(
          source: 'window.__everyaiToken = ${jsonEncode(t.token)}; true',
          contentWorld: _world,
        );
        if (await _native!.bind(t.token)) return;
      } on Object {
        // Loading: try again.
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    _log.add('The tab ${t.id} could not be found by the app (its cookies and offscreen running may not work).');
  }

  InAppWebViewSettings _settings() => InAppWebViewSettings(
    // A store of the session's own on macOS (non-persistent; pop-ups share their opener's); on Windows the
    // environment's folder is.
    incognito: _mac,
    javaScriptEnabled: true,
    javaScriptCanOpenWindowsAutomatically: true,
    supportMultipleWindows: true,
    useOnDownloadStart: true,
    isInspectable: kDebugMode,
    allowsBackForwardNavigationGestures: true,
    mediaPlaybackRequiresUserGesture: true,
    userAgent: _mac ? safariUserAgent(_macOSMajor()) : null,
    transparentBackground: false,
  );

  static int _macOSMajor() {
    final m = RegExp(r'Version (\d+)').firstMatch(Platform.operatingSystemVersion);
    return int.tryParse(m?[1] ?? '') ?? 26;
  }

  UnmodifiableListView<UserScript> _scripts() => UnmodifiableListView([
    UserScript(source: errorReportJs, injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START),
  ]);

  void _publish() {
    final a = _active;
    page.value = a == null
        ? (url: '', title: '', canBack: false, canForward: false, loading: false)
        : (url: a.url, title: a.title, canBack: a.canBack, canForward: a.canForward, loading: a.loading);
    tabs.value = List.unmodifiable([for (final t in _tabs) (id: t.id, url: t.url, title: t.title)]);
    dialog.value = a?._pending?.dialog;
  }

  WebTab? _tab(String id) => _tabs.where((t) => t.id == id).firstOrNull;

  Future<WebTab> _activeTab() async {
    await _start();
    final t = _active;
    if (t == null) throw const BrowserError('The browser is not running.');
    return t;
  }

  @override
  Future<void> switchTab(String id) async {
    final t = _tab(id);
    if (t == null || identical(t, _active)) return;
    _active = t;
    fileChooser.value = null;
    frames.moved();
    _publish();
  }

  @override
  Future<void> openTab(String url) async {
    final from = await _activeTab();
    final made = Completer<WebTab>();
    _opening = made;
    try {
      await _jsOn(from, 'window.open(a.url, "_blank", "noopener"); return true;', {'url': url}, dialogs: false);
      final t = await made.future.timeout(const Duration(seconds: 10));
      await switchTab(t.id);
    } on TimeoutException {
      throw const BrowserError('The new tab did not open.');
    } finally {
      if (identical(_opening, made)) _opening = null;
    }
  }

  Completer<WebTab>? _opening;

  @override
  Future<void> closeTab(String id) async {
    final t = _tab(id);
    if (t == null || _tabs.length < 2) return;
    await _closeTab(t);
  }

  Future<void> _closeTab(WebTab t, {bool disposing = true}) async {
    if (t._life == TabLife.closed) return;
    final wasActive = identical(t, _active);
    _moveTab(t, TabLife.closed);
    t._interrupts.add(#closed);
    t._pending?.answer.complete((accept: false, text: null));
    t._pending = null;
    _tabs.remove(t);
    if (wasActive) {
      // As in a browser, the page that opened the closed tab comes back; else the newest tab.
      _active = _tab(t.opener ?? '') ?? (_tabs.isEmpty ? null : _tabs.last);
      frames.moved();
    }
    _publish();
    if (disposing) await _disposeView(t);
    if (_tabs.isEmpty && _life.value is WebviewRunning) await close();
  }

  /// Ends [t]'s native view; one the Preview shows goes once its widget has (a frame later).
  Future<void> _disposeView(WebTab t) async {
    await Future<void>.delayed(const Duration(milliseconds: 120));
    try {
      _native?.release(t.token).ignore();
      if (t._headless case final h? when h.isRunning()) {
        await h.dispose();
      } else {
        await InAppWebViewController.disposeKeepAlive(t.keepAlive);
      }
    } on Object {
      // Gone already.
    }
  }

  @override
  ({int tab, PageDialog dialog})? get dialogHoldingThis {
    final here = _active;
    if (here == null) return null;
    String group(WebTab t) {
      var at = t;
      for (var hops = 0; hops < 20; hops++) {
        final up = _tab(at.opener ?? '');
        if (up == null) break;
        at = up;
      }
      return at.id;
    }

    for (final (i, t) in _tabs.indexed) {
      if (identical(t, here)) continue;
      if (t._pending case final p? when group(t) == group(here) && maySharePageProcess(here.url, t.url)) {
        return (tab: i + 1, dialog: p.dialog);
      }
    }
    return null;
  }

  @override
  ({int tab, PageDialog dialog})? get dialogElsewhere {
    for (final (i, t) in _tabs.indexed) {
      if (identical(t, _active)) continue;
      if (t._pending case final p?) return (tab: i + 1, dialog: p.dialog);
    }
    return null;
  }

  // ------------------------------------------------------------------------------------------------- events

  void _changed(WebTab t) {
    if (identical(t, _active)) {
      _publish();
    } else {
      tabs.value = List.unmodifiable([for (final x in _tabs) (id: x.id, url: x.url, title: x.title)]);
    }
  }

  void _onLoadStart(WebTab t, WebUri? url) {
    t.loading = true;
    if (url != null) t.url = url.toString();
    if (identical(t, _active)) frames.moved();
    _changed(t);
  }

  void _onLoadStop(WebTab t, WebUri? url) {
    t.loading = false;
    if (url != null) t.url = url.toString();
    t._loads.add(null);
    unawaited(_refreshNav(t));
    final origin = webOrigin(t.url);
    if (origin != null) {
      _topOrigins.add(origin);
      if (_restore.remove(origin)) unawaited(_restoreOrigin(t, origin));
      if (jarHome != null) unawaited(Future<void>.delayed(const Duration(seconds: 1), () => _readStorage(t)));
    }
  }

  void _onError(WebTab t, WebResourceRequest req, WebResourceError err) {
    if (req.isForMainFrame == false) {
      _addLog('Request failed: ${err.description} (${req.url})');
      return;
    }
    // A navigation cancelled by another (a click that loads a new page) is no failure.
    if (err.type == WebResourceErrorType.CANCELLED) return;
    t.loading = false;
    _addLog('Request failed: ${err.description} (${req.url})');
    t._loads.add(err.description);
    _changed(t);
  }

  void _onHttpError(WebTab t, WebResourceRequest req, WebResourceResponse res) {
    final status = res.statusCode ?? 0;
    if (status >= 400) _addLog('HTTP $status: ${req.url}');
  }

  void _onHistory(WebTab t, WebUri? url) {
    if (url != null) t.url = url.toString();
    if (identical(t, _active)) frames.moved();
    unawaited(_refreshNav(t));
    _changed(t);
  }

  void _onTitle(WebTab t, String? title) {
    t.title = title ?? '';
    _changed(t);
  }

  Future<void> _refreshNav(WebTab t) async {
    final c = t._controller;
    if (c == null || t._pending != null) return;
    try {
      t.canBack = await c.canGoBack();
      t.canForward = await c.canGoForward();
      _changed(t);
    } on Object {
      // Closing.
    }
  }

  void _onConsole(ConsoleMessage m) {
    final level = switch (m.messageLevel) {
      ConsoleMessageLevel.ERROR => 'error',
      ConsoleMessageLevel.WARNING => 'warn',
      ConsoleMessageLevel.DEBUG => 'debug',
      _ => 'log',
    };
    _addLog('console.$level: ${m.message}');
  }

  Future<bool?> _onCreateWindow(WebTab from, CreateWindowAction a) async {
    if (_life.value is! WebviewRunning) return false;
    final made = _opening;
    try {
      final t = await _newTab(windowId: a.windowId, opener: made == null ? from.id : null);
      _addLog('A new tab opened: ${a.request.url ?? ''} (now the active tab; tabs lists them).');
      if (made != null && !made.isCompleted) {
        made.complete(t);
      } else {
        await switchTab(t.id);
      }
      return true;
    } on Object catch (e) {
      _addLog('A pop-up could not open: $e');
      return false;
    }
  }

  void _onCloseWindow(WebTab t) {
    if (_tabs.length < 2) return;
    unawaited(_closeTab(t));
  }

  Future<({bool accept, String? text})> _dialogOn(WebTab t, PageDialog d) {
    final answer = Completer<({bool accept, String? text})>();
    t._pending = (dialog: d, answer: answer);
    t._interrupts.add(d);
    _addLog('The page opened a${d.type == 'alert' ? 'n' : ''} ${d.type} dialog: "${d.message}".');
    _changed(t);
    return answer.future;
  }

  Future<JsAlertResponse> _onAlert(WebTab t, JsAlertRequest r) async {
    await _dialogOn(t, (type: 'alert', message: r.message ?? '', defaultPrompt: ''));
    return JsAlertResponse(handledByClient: true, action: JsAlertResponseAction.CONFIRM);
  }

  Future<JsConfirmResponse> _onConfirm(WebTab t, JsConfirmRequest r) async {
    final a = await _dialogOn(t, (type: 'confirm', message: r.message ?? '', defaultPrompt: ''));
    return JsConfirmResponse(
      handledByClient: true,
      action: a.accept ? JsConfirmResponseAction.CONFIRM : JsConfirmResponseAction.CANCEL,
    );
  }

  Future<JsPromptResponse> _onPrompt(WebTab t, JsPromptRequest r) async {
    final a = await _dialogOn(t, (type: 'prompt', message: r.message ?? '', defaultPrompt: r.defaultValue ?? ''));
    return JsPromptResponse(
      handledByClient: true,
      action: a.accept ? JsPromptResponseAction.CONFIRM : JsPromptResponseAction.CANCEL,
      value: a.accept ? (a.text ?? r.defaultValue ?? '') : null,
    );
  }

  @override
  Future<void> answerDialog({required bool accept, String? text}) async {
    final t = _active;
    final p = t?._pending;
    if (t == null || p == null) return;
    t._pending = null;
    p.answer.complete((accept: accept, text: text));
    _changed(t);
    unawaited(_refreshNav(t));
  }

  // ---------------------------------------------------------------------------------------- native and control

  final _shortcuts = StreamController<String>.broadcast();
  final _asks = StreamController<String>.broadcast();

  /// Browser shortcuts typed in the shown view (`l`, `r`, `[`, `]`, `f`), for the Preview.
  Stream<String> get shortcuts => _shortcuts.stream;

  /// "Ask the agent about this" from the view's own context menu: the line for the composer.
  Stream<String> get asks => _asks.stream;

  void _onNative(WebviewNativeEvent e) {
    if (!_tabs.any((t) => t.token == e.token)) return;
    switch (e.kind) {
      case 'shortcut':
        _shortcuts.add(e.key);
      case 'blocked':
        control.mayAct();
      case 'ask':
        unawaited(
          contextAt(e.x, e.y).then((at) {
            if (at != null) _asks.add('In the Preview at ${page.value.url}, ${at.description}: ');
          }),
        );
    }
  }

  /// Keys are kept from the views while the agent has them.
  void _syncLock() {
    final locked = !control.phase.userMayAct;
    for (final t in _tabs) {
      if (t._life.live) _native?.setLocked(t.token, locked).ignore();
    }
  }

  // ------------------------------------------------------------------------------------------------- calls

  /// Runs [call] on [t]'s view. A dialog the page opens meanwhile ends it (the page runs no script until it is
  /// answered), and so does the tab closing.
  Future<T> _on<T>(WebTab t, Future<T> Function(InAppWebViewController c) call, {bool dialogs = true}) async {
    if (t._life == TabLife.closed) throw const TabClosedError();
    if (dialogs && t._pending != null) throw BrowserError(dialogWaitingText(t._pending!.dialog));
    final c = t._controller;
    if (c == null) throw const BrowserError('The browser is not running.');
    final r = Completer<T>();
    final sub = t._interrupts.stream.listen((e) {
      if (r.isCompleted) return;
      if (e is PageDialog) {
        if (dialogs) r.completeError(BrowserError(dialogWaitingText(e)));
      } else {
        r.completeError(const TabClosedError());
      }
    });
    unawaited(
      call(c).then(
        (v) {
          if (!r.isCompleted) r.complete(v);
        },
        onError: (Object e, StackTrace s) {
          if (!r.isCompleted) r.completeError(e is BrowserError ? e : BrowserError('$e'), s);
        },
      ),
    );
    try {
      return await r.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw const BrowserError('The page took longer than 30 s to answer.'),
      );
    } finally {
      await sub.cancel();
    }
  }

  /// Runs [body] (a function body reading `a`) in our script world on [t].
  Future<Object?> _js(WebTab t, String body, [Map<String, Object?> a = const {}]) => _jsOn(t, body, a);

  Future<Object?> _jsOn(WebTab t, String body, Map<String, Object?> a, {bool dialogs = true}) => _on(t, (c) async {
    final r = await c.callAsyncJavaScript(functionBody: body, arguments: {'a': a}, contentWorld: _world);
    if (r == null) return null;
    if (r.error case final e? when e.isNotEmpty) throw BrowserError('The script threw: $e', fromPage: true);
    return r.value;
  }, dialogs: dialogs);

  /// The value of [expression] in our script world on [t].
  Future<Object?> _expr(WebTab t, String expression) => _js(t, 'return await ($expression\n);');

  @override
  Future<Object?> evaluate(String script) async {
    final t = await _activeTab();
    return _on(t, (c) async {
      // An expression (awaited if it is a promise); a script of statements gives its last value.
      final r = await c.callAsyncJavaScript(functionBody: 'return await (\n$script\n);');
      final error = r?.error;
      if (error == null || error.isEmpty) return r?.value;
      if (!error.contains('SyntaxError')) throw BrowserError('The script threw: $error', fromPage: true);
      try {
        return await c.evaluateJavascript(source: script);
      } on Object catch (e) {
        throw BrowserError('The script threw: $e', fromPage: true);
      }
    });
  }

  @override
  Future<String> open(String url) async {
    final t = await _activeTab();
    final loaded = t._loads.stream.first.timeout(const Duration(seconds: 20), onTimeout: () => null);
    await _on(t, (c) => c.loadUrl(urlRequest: URLRequest(url: WebUri(url))));
    final failed = await loaded;
    if (failed != null) throw BrowserError('Could not open $url: $failed');
    // A moment for scripts that run after load (frameworks mounting).
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return describe();
  }

  @override
  Future<String> describe({bool bare = false}) async {
    final t = await _activeTab();
    final v = await _expr(
      t,
      bare
          ? '({url: location.origin + location.pathname, title: document.title})'
          : '({url: location.href, title: document.title})',
    );
    if (v is! Map) return '${t.title} — ${t.url}';
    return '${v['title']} — ${v['url']}';
  }

  @override
  Future<LoginProbe?> loginProbe() async {
    final t = _active;
    if (t == null || !running || t._pending != null) return null;
    try {
      final v = await _expr(
        t,
        '[location.href, [...document.querySelectorAll("input[type=password]")]'
        '.some(e => e.getClientRects().length > 0 && getComputedStyle(e).visibility !== "hidden")]',
      ).timeout(const Duration(seconds: 3));
      if (v is List && v.length == 2 && v[0] is String) return (url: v[0] as String, password: v[1] == true);
    } on Object {
      // Unknown this time.
    }
    return null;
  }

  // ------------------------------------------------------------------------------------------------- pictures

  /// The viewport's picture as the platform takes it.
  Future<ui.Image> _capture(WebTab t) async {
    final png = await _on(
      t,
      (c) => c.takeScreenshot(screenshotConfiguration: ScreenshotConfiguration(compressFormat: CompressFormat.PNG)),
    );
    if (png == null) throw const BrowserError('The page gave no picture.');
    final codec = await ui.instantiateImageCodec(png);
    return (await codec.getNextFrame()).image;
  }

  /// [region] (CSS pixels; null: the whole view) of [shot] as a PNG of [w]×[h].
  Future<Uint8List> _scaled(ui.Image shot, ViewRect? region, int w, int h) async {
    final k = shot.width / max(1, width);
    final src = region == null
        ? Rect.fromLTWH(0, 0, shot.width.toDouble(), shot.height.toDouble())
        : Rect.fromLTWH(region.left * k, region.top * k, region.width * k, region.height * k);
    final rec = ui.PictureRecorder();
    Canvas(rec).drawImageRect(
      shot,
      src,
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..filterQuality = FilterQuality.high,
    );
    final img = await rec.endRecording().toImage(w, h);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    return bytes!.buffer.asUint8List();
  }

  @override
  Future<List<int>> screenshot({bool fullPage = false}) async {
    final t = await _activeTab();
    final shot = await _capture(t);
    try {
      // The OS webview takes the viewport only: a whole long page is read with the element list instead.
      if (fullPage) _addLog('A full-page picture is not available in this browser: this is the viewport.');
      return await _scaled(shot, null, width, height);
    } finally {
      shot.dispose();
    }
  }

  @override
  Future<(List<int>, AgentFrame)> frameShot({ViewRect? region}) async {
    final t = await _activeTab();
    final g = geometry;
    final r = region ?? (left: 0.0, top: 0.0, width: g.width.toDouble(), height: g.height.toDouble());
    final size = agentImageSize(r.width, r.height, scale: region == null ? 1.0 : 2.0);
    final scroll = await scrollOffset();
    final shot = await _capture(t);
    final Uint8List png;
    try {
      png = await _scaled(shot, region, size.width, size.height);
    } finally {
      shot.dispose();
    }
    final f = frames.record(
      imageWidth: size.width,
      imageHeight: size.height,
      geometry: g,
      region: region,
      scrollX: scroll.x,
      scrollY: scroll.y,
    );
    return (png, f);
  }

  @override
  Future<({double x, double y})> scrollOffset() async {
    final v = await _expr(await _activeTab(), '[scrollX, scrollY]');
    return v is List ? (x: (v[0] as num).toDouble(), y: (v[1] as num).toDouble()) : (x: 0.0, y: 0.0);
  }

  @override
  Future<List<PageElement>> elements() async {
    try {
      final v = await _expr(await _activeTab(), pageSnapshotJs);
      if (v is! Map) return const [];
      return [for (final i in (v['items'] as List?) ?? const []) ?PageElement.fromJson(i)];
    } on BrowserError {
      return const [];
    }
  }

  @override
  Future<String> snapshot() async {
    final v = await _expr(await _activeTab(), pageSnapshotJs);
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

  @override
  Future<({double x, double y})> refCentre(String ref) async {
    final v = await _expr(await _activeTab(), refCentreJs(ref));
    if (v is! Map) throw BrowserError('No element $ref on the page now: take a new snapshot.');
    if (v['w'] == 0 && v['h'] == 0) throw BrowserError('$ref has no size now (hidden?).');
    return (x: (v['x'] as num).toDouble(), y: (v['y'] as num).toDouble());
  }

  Future<({double x, double y})> _centre(WebTab t, String selector) async {
    final v = await _js(t, centreJs, {'selector': selector});
    if (v is! Map) throw BrowserError('No element matches $selector.');
    if (v['w'] == 0 && v['h'] == 0) throw BrowserError('$selector matches an element with no size (hidden?).');
    return (x: (v['x'] as num).toDouble(), y: (v['y'] as num).toDouble());
  }

  // ------------------------------------------------------------------------------------------------- acting

  /// The password, one-time code and payment field guard: throws a refusal when [check] (a function body over the
  /// page guard helpers, returning why or null) finds one. The one place the guard lives; callers skip it with
  /// `guarded: false` (the user's switch).
  Future<void> _refuse(WebTab t, String check, {bool focus = true}) async {
    final why = await _js(t, guardScript(check, focus: focus));
    if (why is! String) return;
    throw BrowserError(
      'Refused: $why. The browser tool doesn\'t type passwords, one-time codes or payment details nor submit their '
      'forms unless the user allows it in Settings: the user does that. To test a sign-in or checkout of the app you '
      'build, check it another way (a test, or its API) or ask the user.',
    );
  }

  Future<({String url, String title})> _here(WebTab t) async {
    try {
      final v = await _expr(t, '[location.href, document.title]');
      return v is List ? (url: '${v[0]}', title: '${v[1]}') : (url: '', title: '');
    } on BrowserError {
      return (url: t.url, title: t.title);
    }
  }

  /// Script events are untrusted: what they can't do is said in the click's result.
  @override
  Future<String> click({
    String? selector,
    String? ref,
    double? x,
    double? y,
    int count = 1,
    bool guarded = true,
  }) async {
    final t = await _activeTab();
    final at = ref != null
        ? await refCentre(ref)
        : selector != null
        ? await _centre(t, selector)
        : (x: x ?? 0, y: y ?? 0);
    control.report(LiveActivity('click', x: at.x, y: at.y, caption: count > 1 ? 'Double-clicking' : 'Clicking'));
    if (guarded) {
      await _refuse(t, '''
const w = submits(deep(${at.x}, ${at.y}));
return w ? 'that button submits a form with ' + w : null;''', focus: false);
    }
    final hit = await _js(t, hitJs, {'x': at.x, 'y': at.y});
    final what = hit is Map && hit['hit'] != null ? ' on ${hit['hit']}' : '';
    if (hit is Map && hit['file'] == true) {
      fileChooser.value = (backendNodeId: 0, multiple: hit['multiple'] == true);
      return 'Clicked at (${at.x.round()}, ${at.y.round()})$what: a file input. Its picker opens for the user only.';
    }
    final before = await _here(t);
    final running = {..._downloading.keys};
    await _js(t, clickJs, {'x': at.x, 'y': at.y, 'count': count});
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await _settleDownloads(running);
    final after = t._life == TabLife.closed ? before : await _here(t);
    final moved = after.url != before.url
        ? ' The page went to ${after.url} (${after.title}).'
        : after.title != before.title
        ? ' The title is now "${after.title}".'
        : '';
    final select = hit is Map && hit['select'] == true
        ? ' It is a select: its list doesn\'t open for script; pick an option with type (the option\'s text).'
        : '';
    return 'Clicked at (${at.x.round()}, ${at.y.round()})$what.$moved$select';
  }

  @override
  Future<String> type(String text, {String? selector, String? ref, bool submit = false, bool guarded = true}) async {
    final t = await _activeTab();
    if (selector != null || ref != null) await click(selector: selector, ref: ref, guarded: guarded);
    control.report(const LiveActivity('type', caption: 'Typing'));
    if (guarded) {
      await _refuse(
        t,
        '''
const el = focused();
const f = $submit && el && (el.form || (el.closest && el.closest('form')));
return sensitive(el) ? 'the field is ' + sensitive(el) : f && sensitiveForm(f) ? 'its form has ' + sensitiveForm(f) : null;''',
      );
    }
    final r = await _js(t, typeJs, {'text': text, 'keys': true});
    if (r is Map && r['error'] is String) throw BrowserError(r['error'] as String);
    if (r is Map && r['picked'] is String) {
      final did = 'Picked "${r['picked']}" in the select.';
      return submit ? '$did ${await press('Enter', guarded: guarded)}' : did;
    }
    if (submit) await press('Enter', guarded: guarded);
    return 'Typed ${text.length} characters${submit ? ' and pressed Enter' : ''}.';
  }

  @override
  Future<String> typeSecret(String value, {String? selector, String? ref, bool submit = false}) async {
    final t = await _activeTab();
    if (selector != null || ref != null) await click(selector: selector, ref: ref, guarded: false);
    control.report(const LiveActivity('type', caption: 'Filling a saved login'));
    final Object? r;
    try {
      // What the field holds is selected first, so the value replaces it.
      r = await _js(t, typeJs, {'text': value, 'keys': false, 'select': true});
    } on BrowserError catch (e) {
      // Never the value: only what kind of failure it was.
      throw BrowserError(e is TabClosedError ? e.message : 'The field could not be filled.');
    }
    if (r is Map && r['error'] is String) {
      final e = r['error'] as String;
      throw BrowserError(e.startsWith('The select') ? 'The focused element is a select, not a text field.' : e);
    }
    if (submit) await press('Enter', guarded: false);
    return 'Filled the field${submit ? ' and pressed Enter' : ''}.';
  }

  @override
  Future<String?> focusedFieldKind() async {
    final v = await _js(await _activeTab(), focusedKindJs);
    return v is String ? v : null;
  }

  @override
  Future<String> press(String key, {bool guarded = true}) async {
    final t = await _activeTab();
    final k = parseKeyPress(key);
    if (k == null) {
      throw BrowserError(
        'Unknown key "$key". Use a key name (Enter, Tab, Escape, Backspace, Delete, Space, ArrowUp/Down/Left/Right, '
        'Home, End, PageUp, PageDown, F1-F12), one character, or a combination such as Shift+Tab or Control+a.',
      );
    }
    final text = k.text ?? '';
    if (guarded && (k.code == 'Enter' || k.code == 'NumpadEnter')) {
      await _refuse(t, '''
const el = focused();
const f = el && (el.form || (el.closest && el.closest('form')));
return f && sensitiveForm(f) ? 'Enter would submit a form with ' + sensitiveForm(f) : null;''');
    } else if (guarded && text.isNotEmpty) {
      await _refuse(
        t,
        '''
const el = focused();
const w = ${k.code == 'Space'} && submits(el);
return sensitive(el) ? 'the field is ' + sensitive(el) : w ? 'Space would press a button that submits a form with ' + w : null;''',
      );
    }
    final before = {..._downloading.keys};
    final r = await _js(t, pressJs, {
      'key': k.key,
      'code': k.code,
      'vk': k.vk,
      'text': text == '\r' ? '' : text,
      'shift': k.modifiers & cdpShift != 0,
      'ctrl': k.modifiers & cdpControl != 0,
      'alt': k.modifiers & cdpAlt != 0,
      'meta': k.modifiers & cdpMeta != 0,
      'action': keyDefaultOf(k).name,
    });
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await _settleDownloads(before);
    final did = r is Map && r['did'] is String ? ': ${r['did']}' : '';
    final prevented = r is Map && r['prevented'] == true ? ' (the page handled it)' : '';
    return 'Pressed $key$prevented$did.';
  }

  @override
  Future<String> scroll(double dy, {double? x, double? y}) async {
    final t = await _activeTab();
    final px = x ?? width / 2, py = y ?? height / 2;
    control.report(LiveActivity('scroll', x: px, y: py, caption: 'Scrolling'));
    final pos = await _js(t, scrollJs, {'dy': dy, 'x': px, 'y': py});
    if (pos is! List) return 'Scrolled.';
    return 'Scrolled; the page is at y=${pos[0]}${pos[0] == pos[1]
        ? ' (the bottom)'
        : pos[0] == 0
        ? ' (the top)'
        : ' of ${pos[1]}'}.';
  }

  @override
  Future<String> wait({String? selector, int ms = 5000}) async {
    final t = await _activeTab();
    if (selector == null) {
      await Future<void>.delayed(Duration(milliseconds: ms.clamp(0, 30000)));
      return 'Waited ${ms}ms.';
    }
    final end = DateTime.now().add(Duration(milliseconds: ms.clamp(0, 30000)));
    while (DateTime.now().isBefore(end)) {
      if (await _js(t, 'return !!document.querySelector(a.s);', {'s': selector}) == true) return '$selector is there.';
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw BrowserError('$selector did not appear within ${ms}ms.');
  }

  @override
  Future<String> resize(int w, int h) async {
    _agentW = w.clamp(200, 3840);
    _agentH = h.clamp(200, 2400);
    await _start();
    for (final t in _tabs) {
      switch (t._life) {
        case TabLife.headless:
          await t._headless?.setSize(Size(_agentW.toDouble(), _agentH.toDouble()));
        case TabLife.parked:
          await _native?.park(t.token, _agentW, _agentH);
        case TabLife.starting || TabLife.shown || TabLife.parking || TabLife.closed:
          break;
      }
    }
    if (_shown) {
      return 'The Preview shows the page, so it is $width×$height (the pane\'s size) until the Preview closes; then '
          'it is $_agentW×$_agentH.';
    }
    return 'The viewport is $_agentW×$_agentH.';
  }

  @override
  Future<void> setSize(int w, int h) async {
    requestedSize.value = Size(w.toDouble(), h.toDouble());
    await resize(w, h);
  }

  // ------------------------------------------------------------------------------------------------- downloads

  final _downloading = <String, ({String name, Completer<void> done})>{};
  var _downloadSeq = 0;

  @visibleForTesting
  Duration downloadWait = const Duration(seconds: 20);

  /// The page started a download (the OS webview hands it over): the app fetches it with the session's cookies.
  Future<void> _download(WebTab t, WebUri url, String? suggested) async {
    final segs = url.pathSegments.where((s) => s.isNotEmpty);
    final name = (suggested?.isNotEmpty == true ? suggested! : (segs.isEmpty ? 'download' : segs.last)).replaceAll(
      RegExp(r'[/\\:\x00]'),
      '_',
    );
    final dir = downloadDir;
    if (dir == null) {
      _addLog('Download canceled: $name (this browser takes no downloads)');
      return;
    }
    final guid = 'w${++_downloadSeq}';
    final done = Completer<void>();
    _downloading[guid] = (name: name, done: done);
    _downloadState(guid, name: name, state: 'inProgress');
    try {
      final List<int> bytes;
      final u = Uri.parse(url.toString());
      switch (u.scheme) {
        case 'data':
          bytes = UriData.fromUri(u).contentAsBytes();
        case 'blob':
          final b64 = await _js(
            t,
            '''
const r = await fetch(a.url); const b = new Uint8Array(await r.arrayBuffer());
let s = ''; for (let i = 0; i < b.length; i += 32768) s += String.fromCharCode(...b.subarray(i, i + 32768));
return btoa(s);''',
            {'url': u.toString()},
          );
          bytes = base64Decode('$b64');
        default:
          bytes = await _fetch(t, u, guid);
      }
      await Directory(dir).create(recursive: true);
      var path = '$dir/$name';
      for (var n = 1; File(path).existsSync(); n++) {
        final dot = name.lastIndexOf('.');
        path = dot > 0 ? '$dir/${name.substring(0, dot)} ($n)${name.substring(dot)}' : '$dir/$name ($n)';
      }
      await File(path).writeAsBytes(bytes);
      _downloadState(guid, state: 'completed', path: path);
      _addLog('Downloaded $path');
    } on Object catch (e) {
      _downloadState(guid, state: 'canceled');
      _addLog('Download failed: $name ($e)');
    } finally {
      _downloading.remove(guid);
      done.complete();
    }
  }

  Future<List<int>> _fetch(WebTab t, Uri u, String guid) async {
    final client = HttpClient()..userAgent = _mac ? safariUserAgent(_macOSMajor()) : null;
    try {
      final req = await client.getUrl(u);
      final cookies = [
        for (final c in await _native!.cookies(t.token, urls: [u]))
          if (cookieMatches(c, u)) '${c.name}=${c.value}',
      ];
      if (cookies.isNotEmpty) req.headers.set(HttpHeaders.cookieHeader, cookies.join('; '));
      if (webOrigin(t.url) != null) req.headers.set(HttpHeaders.refererHeader, t.url);
      final res = await req.close();
      if (res.statusCode >= 400) throw BrowserError('HTTP ${res.statusCode}');
      final total = res.contentLength;
      final out = BytesBuilder(copy: false);
      await for (final chunk in res) {
        out.add(chunk);
        if (total > 0) _downloadState(guid, state: 'inProgress', progress: out.length / total);
      }
      return out.takeBytes();
    } finally {
      client.close(force: true);
    }
  }

  void _downloadState(String guid, {String? name, required String state, String? path, double progress = 0}) {
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

  Future<void> _settleDownloads(Set<String> before) async {
    final mine = [
      for (final e in _downloading.entries)
        if (!before.contains(e.key)) e.value,
    ];
    if (mine.isEmpty) return;
    await Future.wait([for (final d in mine) d.done.future]).timeout(
      downloadWait,
      onTimeout: () {
        for (final d in mine) {
          if (!d.done.isCompleted) _addLog('Download still running: ${d.name}');
        }
        return const [];
      },
    );
  }

  // ------------------------------------------------------------------------------------------------- files

  @override
  Future<void> setFiles(List<String> paths, {String? selector, String? ref}) async {
    final t = await _activeTab();
    if (selector == null && ref == null && fileChooser.value == null) {
      throw const BrowserError('No file picker is open: name the file input by ref or selector.');
    }
    final files = [
      for (final p in paths)
        {
          'name': p.split(Platform.pathSeparator).last,
          'type': _mime(p),
          'data': base64Encode(File(p).readAsBytesSync()),
        },
    ];
    final why = await _js(t, setFilesJs, {'files': files, 'ref': ref, 'selector': selector});
    if (why is String) throw BrowserError(why);
    fileChooser.value = null;
  }

  static String _mime(String path) => switch (path.split('.').last.toLowerCase()) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'svg' => 'image/svg+xml',
    'pdf' => 'application/pdf',
    'txt' || 'md' => 'text/plain',
    'csv' => 'text/csv',
    'json' => 'application/json',
    'html' => 'text/html',
    'zip' => 'application/zip',
    _ => 'application/octet-stream',
  };

  @override
  void cancelFileChooser() => fileChooser.value = null;

  // ------------------------------------------------------------------------------------------------- log

  final _log = <String>[];
  final _logged = <String>[];

  void _addLog(String line) {
    _log.add(line.length > 600 ? '${line.substring(0, 600)}…' : line);
    if (_log.length > 200) _log.removeRange(0, _log.length - 200);
  }

  @override
  List<String> takeLog() {
    final out = [..._log];
    _logged.addAll(out);
    if (_logged.length > 50) _logged.removeRange(0, _logged.length - 50);
    _log.clear();
    return out;
  }

  @override
  List<String> get history => [..._logged, ..._log];

  // ------------------------------------------------------------------------------------------------- navigation

  @override
  Future<void> back() async {
    final t = await _activeTab();
    await _on(t, (c) => c.goBack());
  }

  @override
  Future<void> forward() async {
    final t = await _activeTab();
    await _on(t, (c) => c.goForward());
  }

  @override
  Future<void> reload() async {
    final t = await _activeTab();
    await _on(t, (c) => c.reload());
  }

  @override
  Future<void> userOpen(String url) async {
    final t = await _activeTab();
    await _on(t, (c) => c.loadUrl(urlRequest: URLRequest(url: WebUri(url))));
  }

  // ------------------------------------------------------------------------------------------------- the user's

  @override
  Future<PageContext?> contextAt(double x, double y) async {
    try {
      final v = await _expr(await _activeTab(), '($pageContextAtJs)($x, $y)');
      if (v is! Map) return null;
      return (
        prevented: false,
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

  @override
  Future<int> findText(String text, {bool backwards = false}) async {
    final t = await _activeTab();
    if (text.isEmpty) {
      await _expr(t, 'getSelection().removeAllRanges()');
      return 0;
    }
    final v = await _js(
      t,
      '''
const q = a.q;
const body = (document.body && document.body.innerText || '').toLowerCase();
let n = 0, i = 0;
while ((i = body.indexOf(q.toLowerCase(), i)) >= 0) { n++; i += q.length; }
if (n) window.find(q, false, a.back, true, false, false, false);
return n;''',
      {'q': text, 'back': backwards},
    );
    return v is num ? v.toInt() : 0;
  }

  @override
  Future<String> selectedText() async {
    final v = await _expr(await _activeTab(), 'String(getSelection ? getSelection() : "")');
    return v is String ? v : '';
  }

  @override
  Future<void> userCommand(String command) async {
    await _js(await _activeTab(), 'document.execCommand(a.c); return true;', {'c': command});
  }

  @override
  Future<void> userText(String text) async {
    await _js(await _activeTab(), 'document.execCommand("insertText", false, a.t); return true;', {'t': text});
  }

  // ------------------------------------------------------------------------------------------------- the jar

  JarData _jar = emptyJar;
  Future<void>? _jarLoad;
  var _jarLoaded = false;
  var _jarUnreadable = false;
  final _restore = <String>{};
  final _topOrigins = <String>{};
  Future<void>? _writing;
  Timer? _jarTimer;
  var _forget = false;

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
      _jarLoad = null;
      return;
    }
    _jarLoaded = true;
  }

  Future<void> _restoreOrigin(WebTab t, String origin) async {
    final items = _jar.storage[origin];
    if (items == null || items.isEmpty) return;
    try {
      await _js(
        t,
        '''
if (location.origin !== a.origin) return false;
for (const [k, v] of Object.entries(a.items)) localStorage.setItem(k, v);
return true;''',
        {'origin': origin, 'items': items},
      );
      await _on(t, (c) => c.reload());
    } on Object {
      _restore.add(origin);
    }
  }

  Future<void> _readStorage(WebTab t) async {
    if (t._pending != null || !t._life.live) return;
    try {
      final v = await _expr(t, storageReadJs).timeout(const Duration(seconds: 3));
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
      // Busy or gone.
    }
  }

  Iterable<Uri> get _knownUrls =>
      {for (final o in _topOrigins) o, for (final t in _tabs) ?webOrigin(t.url)}.map(Uri.parse);

  @override
  Future<JarData> captureJar() async {
    final t = _active;
    if (running && t != null && _native != null) {
      try {
        final cookies = await _native!.cookies(t.token, urls: _knownUrls).timeout(const Duration(seconds: 3));
        _jar = (cookies: [for (final c in cookies) jarCookieOf(c)], storage: _jar.storage);
      } on Object {
        // Keep the last reading.
      }
      for (final x in [..._tabs]) {
        await _readStorage(x);
      }
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

  @override
  Future<void> saveJar({bool captured = false}) async {
    if (!_jarLoaded) await _loadJar();
    if (running && !captured) await captureJar();
    await _writeJar();
  }

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

  @override
  Future<void> applyJar(JarData data, {String? site, String? loginId}) async {
    await _loadJar();
    _jar = jarMerged(_jar, data);
    if (site != null && loginId != null) usedLogins[site] = loginId;
    final t = _active;
    if (running && t != null) {
      final cookies = [for (final c in data.cookies) ?nativeCookieOf(c)];
      if (cookies.isNotEmpty) await _native!.setCookies(t.token, cookies);
      _restore.addAll(data.storage.keys);
      final origin = webOrigin(t.url);
      if (origin != null && _restore.remove(origin)) {
        await _restoreOrigin(t, origin);
      } else if (data.cookies.isNotEmpty) {
        await reload();
      }
    }
    await _writeJar();
  }

  @override
  Future<void> clearJar({String? site}) async {
    await _loadJar();
    final t = _active;
    final live = running && t != null;
    final all = live ? await captureJar() : _jar;
    if (live) {
      if (site == null) {
        await _native!.clearData(t.token);
      } else {
        final gone = [for (final c in jarForSite(all, site).cookies) ?nativeCookieOf(c)];
        await _native!.deleteCookies(t.token, gone);
        for (final x in _tabs) {
          final u = Uri.tryParse(x.url);
          if (u != null && u.hasAuthority && siteOf(u.host) == site) {
            await _js(
              x,
              'try { localStorage.clear(); sessionStorage.clear(); } catch (_) {} return true;',
            ).catchError((Object _) => null);
          }
        }
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
    if (live) await reload();
  }

  @override
  List<String> get signedInSites => jarSites(_jar);

  /// The webview has no shared project profile (that is the Chrome backend's "Sign in in a window").
  @override
  Future<JarData> profileSignIns({String? site}) async => emptyJar;

  // ------------------------------------------------------------------------------------------------- closing

  @override
  Future<void> close({bool captured = false}) async {
    switch (_life.value) {
      case WebviewClosing(:final done):
        return done;
      case WebviewNotCreated() || WebviewClosed():
        return;
      case WebviewStarting():
        _generation++;
      case WebviewRunning():
        break;
    }
    final done = Completer<void>();
    final wasRunning = _life.value is WebviewRunning;
    _set(WebviewClosing(done.future));
    try {
      _jarTimer?.cancel();
      if (wasRunning && !_forget) {
        await saveJar(captured: captured).timeout(const Duration(seconds: 2), onTimeout: () {});
      }
      loginWall.stop();
      final all = [..._tabs];
      for (final t in all) {
        await _closeTab(t, disposing: false);
      }
      // A frame for the Preview to let go of a shown view first.
      await Future.wait([for (final t in all) _disposeView(t)]);
      control.removeListener(_syncLock);
      _active = null;
      _publish();
      fileChooser.value = null;
      for (final d in _downloading.values) {
        if (!d.done.isCompleted) d.done.complete();
      }
      final env = _env, dir = _envDir;
      _env = null;
      _envDir = null;
      await env?.dispose().catchError((Object _) {});
      if (dir != null) await dir.delete(recursive: true).catchError((Object _) => dir);
    } finally {
      _set(const WebviewClosed());
      done.complete();
    }
  }
}
