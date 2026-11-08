import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, visibleForTesting;
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:file_selector/file_selector.dart' show openFile, openFiles;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/motion/motion.dart';
import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/every_icons.dart';
import '../../code_providers.dart' show codeProjectsProvider, composerInsertProvider;
import '../../domain/code_session.dart';
import '../../domain/local_ports.dart';
import '../../git/git_service.dart';
import '../../harness/everyai/browser_io.dart';
import '../../harness/everyai/screen_tools_io.dart' show noteUserNavigation;
import '../../live/app_endpoints.dart';
import '../../live/app_sources.dart';
import '../../live/chrome_download.dart';
import '../../live/android_device_io.dart';
import '../../live/desktop_window_io.dart';
import '../../live/key_map.dart';
import '../../live/ios_simulator_io.dart';
import '../../live/live_browsers.dart';
import '../../live/live_session.dart';
import '../../panes/panes_providers.dart';
import '../../panes/processes.dart';
import '../../shells/shell_registry.dart';
import 'browser_overlays.dart';
import 'preview_apps.dart';

/// The page sizes the Preview offers (CSS pixels); phones and tablets get a device frame.
enum PreviewSize {
  desktop('Desktop', 1280, 800),
  laptop('Laptop', 1440, 900),
  tablet('Tablet', 820, 1180),
  phone('Phone', 390, 844);

  const PreviewSize(this.label, this.width, this.height);
  final String label;
  final int width;
  final int height;

  bool get device => this == tablet || this == phone;
}

/// The session's shared browser page, live: the agent's browser tool and the user drive the same page (the same
/// tabs, sign-ins and state). The picture is the page's screencast, painted while the tab shows; the user's
/// clicks, scrolls and keys go to the page. The user's first input takes control (the agent's browser actions
/// wait) until Give back.
class PreviewPane extends ConsumerStatefulWidget {
  const PreviewPane({super.key, required this.session});

  final CodeSessionInfo session;

  @override
  ConsumerState<PreviewPane> createState() => _PreviewPaneState();
}

class _PreviewPaneState extends ConsumerState<PreviewPane> with WidgetsBindingObserver {
  final _field = TextEditingController();
  final _fieldFocus = FocusNode();
  final _viewFocus = FocusNode(debugLabel: 'preview.page');
  HeadlessBrowser? _browser;
  StreamSubscription<ScreencastFrame>? _frames;
  StreamSubscription<String>? _made;
  StreamSubscription<LiveActivity>? _activity;
  ui.Image? _image;

  /// The page's screencast, kept in step with [_wantCast] by [_syncCasting]:
  ///
  /// ```text
  ///  off ──want──► starting ──ok──► on ──!want──► off
  ///                   └──fail──► off (+ _problem; the next change retries)
  /// ```
  /// Each start or stop takes a new [_castGen]; a reply for an older one is dropped, so a late failure can't undo a
  /// newer stop or leave the pane thinking it casts.
  var _cast = _Cast.off;
  var _castGen = 0;
  var _decoding = false;

  /// Set when the page changed; a frame clears it. Still set after a while: the picture is stale, start again.
  Timer? _staleCheck;
  DateTime _lastAck = DateTime.fromMillisecondsSinceEpoch(0);
  var _appVisible = true;
  var _size = PreviewSize.desktop;
  var _landscape = false;
  String? _problem;
  var _signingIn = false;
  double? _downloading;

  /// The find bar is open (⌘F).
  var _finding = false;

  /// A native file picker is open for the page's file input: one at a time.
  var _picking = false;

  /// The agent's last action, for the ghost cursor and caption.
  LiveActivity? _ghost;
  Timer? _ghostTimer;

  /// The apps the session runs (Flutter, React Native, Electron), and the one shown (null: the web page).
  List<SessionApp> _apps = const [];
  AppEndpoint? _source;
  var _autoPicked = false;
  StreamSubscription<Object?>? _shellChanges;
  StreamSubscription<void>? _appChanges;
  Timer? _scanTimer;

  String get _id => widget.session.id;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _field.text = ref.read(previewUrlProvider(_id)) ?? '';
    unawaited(loadDownloadedChrome().then((_) => mounted ? setState(() {}) : null));
    _attach(LiveBrowsers.of(_id));
    // The agent may make the page later (its first browser call).
    _made = LiveBrowsers.changes.where((s) => s == _id).listen((_) {
      if (_source?.kind != AppKind.electron) _attach(LiveBrowsers.of(_id));
    });
    final sessions = {_id, widget.session.billingTag};
    _shellChanges = ShellRegistry.instance.changes.where(sessions.contains).listen((_) => _scanApps());
    _appChanges = AppSources.changes.listen((_) => _scanApps());
    // An app prints its address a while after its shell starts.
    _scanTimer = Timer.periodic(const Duration(seconds: 2), (_) => _scanApps());
    WidgetsBinding.instance.addPostFrameCallback((_) => _scanApps());
  }

  void _scanApps() {
    if (!mounted) return;
    // Booted simulators are read in the background; the next scan sees them.
    unawaited(IosSimulators.refresh().then((_) {}, onError: (Object _) {}));
    unawaited(AndroidDevices.refresh().then((_) {}, onError: (Object _) {}));
    final apps = AppSources.running({_id, widget.session.billingTag});
    final same =
        apps.length == _apps.length &&
        [for (var i = 0; i < apps.length; i++) apps[i].endpoint == _apps[i].endpoint].every((x) => x);
    if (same) return;
    setState(() => _apps = apps);
    if (_source != null && !apps.any((a) => a.endpoint == _source)) {
      _select(null);
    } else if (_source == null && !_autoPicked && apps.isNotEmpty) {
      // The first app shows by itself when the web page has nothing.
      final page = _browser?.page.value.url ?? '';
      if (page.isEmpty || page == 'about:blank') {
        _autoPicked = true;
        _select(apps.last.endpoint);
      }
    }
  }

  void _select(AppEndpoint? source) {
    final was = _source;
    if (was == source) return;
    setState(() => _source = source);
    if (source?.kind == AppKind.electron) {
      _switchBrowser(AppSources.electron(source!.uri));
    } else if (was?.kind == AppKind.electron) {
      _switchBrowser(LiveBrowsers.of(_id));
    }
  }

  void _switchBrowser(HeadlessBrowser? b) {
    _detach();
    _image?.dispose();
    _image = null;
    _problem = null;
    if (b != null) {
      _attach(b);
    } else if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _made?.cancel();
    _shellChanges?.cancel();
    _appChanges?.cancel();
    _scanTimer?.cancel();
    _staleCheck?.cancel();
    _detach();
    _ghostTimer?.cancel();
    _image?.dispose();
    _field.dispose();
    _fieldFocus.dispose();
    _viewFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Minimised or hidden: no frames until it shows again.
    final visible = state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
    if (visible == _appVisible) return;
    // The app views read [_visible] when they build: rebuild them so they stop and start too.
    setState(() => _appVisible = visible);
    _syncCasting();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // TickerMode is off while the Preview tab is hidden (it stays built once shown).
    _syncCasting();
  }

  bool get _visible => mounted && TickerMode.valuesOf(context).enabled && _appVisible;

  Future<String> _profile() async {
    final info = widget.session;
    final project = ref.read(codeProjectsProvider).where((p) => p.id == info.projectId).firstOrNull?.path;
    return browserProfileDir(await GitService.dataDir(), project ?? info.workingDir);
  }

  /// The session's page, made now when the user opens something before the agent did.
  Future<HeadlessBrowser> _ensure() async {
    if (_browser case final b?) return b;
    final b = LiveBrowsers.forSession(_id, profileDir: await _profile());
    _attach(b);
    return b;
  }

  void _attach(HeadlessBrowser? b) {
    if (b == null || identical(b, _browser)) return;
    _detach();
    _browser = b;
    b.page.addListener(_pageChanged);
    b.control.addListener(_controlChanged);
    b.fileChooser.addListener(_fileChooserChanged);
    _activity = b.control.activity.listen(_showGhost);
    _frames = b.screencast.listen(_paint);
    _pageChanged();
    _syncCasting();
    if (mounted) setState(() {});
  }

  void _detach() {
    final b = _browser;
    if (b == null) return;
    b.page.removeListener(_pageChanged);
    b.control.removeListener(_controlChanged);
    b.fileChooser.removeListener(_fileChooserChanged);
    unawaited(_activity?.cancel());
    unawaited(_frames?.cancel());
    if (_cast != _Cast.off) unawaited(b.stopScreencast().catchError((Object _) {}));
    _castOff();
    _browser = null;
  }

  void _pageChanged() {
    _watchForFrame();
    final url = _browser?.page.value.url ?? '';
    if (!_fieldFocus.hasFocus && url.isNotEmpty && url != 'about:blank') _field.text = url;
    if (mounted) setState(() {});
    // The agent's first navigation is what makes the page worth casting.
    _syncCasting();
  }

  void _controlChanged() {
    if (mounted) setState(() {});
  }

  /// The page opened a file picker. When the user is driving (they clicked the file input), the system's picker
  /// opens and its files go to the page; the agent's picker waits for its upload action.
  Future<void> _fileChooserChanged() async {
    final b = _browser;
    final chooser = b?.fileChooser.value;
    if (b == null || chooser == null || _picking || !b.control.userDriving) return;
    _picking = true;
    try {
      final files = chooser.multiple ? await openFiles() : [?await openFile()];
      if (!identical(b.fileChooser.value, chooser)) return;
      if (files.isEmpty) {
        b.cancelFileChooser();
      } else {
        await b.setFiles([for (final f in files) f.path]);
      }
    } on Object catch (e) {
      if (mounted) showAdaptiveToast(context, "Couldn't give the page the files: $e");
    } finally {
      _picking = false;
    }
  }

  void _ask(String text) => ref.read(composerInsertProvider(_id).notifier).insert(text);

  /// Paints only while the Preview shows.
  bool _wantCast(HeadlessBrowser b) => _visible && (b.attachTo != null || b.page.value.url.isNotEmpty || b.running);

  void _syncCasting() {
    final b = _browser;
    if (b == null) return;
    final want = _wantCast(b);
    if (want == (_cast != _Cast.off)) return;
    if (!want) {
      _castOff();
      unawaited(b.stopScreencast().catchError((Object _) {}));
      return;
    }
    final gen = ++_castGen;
    _cast = _Cast.starting;
    b.startScreencast().then(
      (_) {
        if (gen == _castGen) _cast = _Cast.on;
      },
      onError: (Object e) {
        if (gen != _castGen) return;
        _cast = _Cast.off;
        if (mounted) setState(() => _problem = '$e');
      },
    );
  }

  /// The browser stopped casting (closed, detached, or told to stop); any start still answering is stale.
  void _castOff() {
    _castGen++;
    _cast = _Cast.off;
  }

  /// The page changed: a frame should follow. If none does within 1.5 s, the picture is restarted (safety net for
  /// a screencast Chrome stopped; see HeadlessBrowser's own window per page).
  void _watchForFrame() {
    if (_cast != _Cast.on) return;
    _staleCheck?.cancel();
    _staleCheck = Timer(const Duration(milliseconds: 1500), () {
      final b = _browser;
      if (mounted && b != null && _cast == _Cast.on) unawaited(b.refreshScreencast());
    });
  }

  Future<void> _paint(ScreencastFrame f) async {
    _staleCheck?.cancel();
    if (_decoding) {
      _browser?.ackFrame(f.session);
      return;
    }
    _decoding = true;
    try {
      final codec = await ui.instantiateImageCodec(Uint8List.fromList(f.jpeg));
      final frame = await codec.getNextFrame();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() {
        _image?.dispose();
        _image = frame.image;
        _problem = null;
      });
    } on Object {
      // A broken frame: wait for the next.
    } finally {
      _decoding = false;
      // At most 30 frames a second: Chrome sends the next one after the ack.
      final wait = const Duration(milliseconds: 33) - DateTime.now().difference(_lastAck);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      _lastAck = DateTime.now();
      _browser?.ackFrame(f.session);
    }
  }

  void _showGhost(LiveActivity a) {
    if (!mounted) return;
    _ghostTimer?.cancel();
    setState(() => _ghost = a);
    _ghostTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _ghost = null);
    });
  }

  Future<void> _go(String typed) async {
    final url = normalizePreviewUrl(typed);
    if (url == null) return;
    _field.text = url;
    ref.read(previewUrlProvider(_id).notifier).set(url);
    try {
      final b = await _ensure();
      // The user's own navigation: the agent's next look judges where the page is now.
      await b.userOpen(url);
      noteUserNavigation(b, url);
      _syncCasting();
      _viewFocus.requestFocus();
    } on BrowserError catch (e) {
      if (mounted) setState(() => _problem = e.message);
    }
  }

  Future<void> _openOutside(String url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  /// The user's input on the page: they drive now.
  void _takeOver() {
    final c = _browser?.control;
    if (c == null || c.userDriving) return;
    c.take();
    showAdaptiveToast(context, "You're driving: the agent's browser actions wait until you give it back.");
  }

  Future<void> _setSize(PreviewSize s, {bool? landscape}) async {
    setState(() {
      _size = s;
      _landscape = landscape ?? (s.device && _landscape);
    });
    final b = await _ensure();
    final w = _landscape ? s.height : s.width, h = _landscape ? s.width : s.height;
    await b.setSize(w, h);
  }

  Future<void> _signIn() async {
    if (_signingIn) return;
    setState(() => _signingIn = true);
    final HeadlessBrowser b;
    try {
      b = await _ensure();
    } on Object {
      if (mounted) setState(() => _signingIn = false);
      rethrow;
    }
    final url = b.page.value.url;
    try {
      await b.close();
      await b.host.signIn(url.isEmpty || url == 'about:blank' ? 'https://accounts.google.com' : url);
      if (url.isNotEmpty) await b.userOpen(url);
    } on BrowserError catch (e) {
      if (mounted) setState(() => _problem = e.message);
    } finally {
      if (mounted) setState(() => _signingIn = false);
      // close() ended the cast.
      _castOff();
      _syncCasting();
    }
  }

  Future<void> _clearProfile() async {
    final ok = await showAdaptiveConfirm(
      context,
      title: 'Clear the browser data?',
      message:
          "Signs out of every site in this project's Preview browser and deletes its cookies and storage. Every "
          'session of the project shares it.',
      confirmLabel: 'Clear',
      destructive: true,
    );
    if (ok != true) return;
    final b = await _ensure();
    await b.close();
    await b.host.clear();
    _castOff();
    if (!mounted) return;
    setState(() {
      _image?.dispose();
      _image = null;
    });
    _syncCasting();
  }

  Future<void> _download() async {
    setState(() => _downloading = 0);
    try {
      await downloadChromeForTesting(
        onProgress: (p) {
          if (mounted) setState(() => _downloading = p);
        },
      );
      if (mounted) setState(() => _problem = null);
    } on Object catch (e) {
      if (mounted) setState(() => _problem = "Couldn't download the browser: $e");
    } finally {
      if (mounted) setState(() => _downloading = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final asked = ref.watch(previewUrlProvider(_id));
    // A port chip in Processes (or the terminal) picked an address: open it.
    ref.listen(previewUrlProvider(_id), (_, next) {
      if (next != null && next != _browser?.page.value.url) unawaited(_go(next));
    });
    final candidates = previewCandidates(
      printed: ref.watch(sessionTerminalProvider(_id).select((t) => t.urls)),
      ports: [for (final p in ref.watch(sessionProcessesProvider(_id)).value ?? const <SessionProcess>[]) ...p.ports],
    );
    final b = _browser;
    final page = b?.page.value;
    final blank = page == null || page.url.isEmpty || page.url == 'about:blank';
    // The first server that shows up opens by itself, unless the page is somewhere already.
    if (asked == null && blank && candidates.isNotEmpty && chromeAvailable) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ref.read(previewUrlProvider(_id)) == null) unawaited(_go(candidates.first));
      });
    }
    final control = b?.control;
    final sourceBar = _apps.isEmpty ? null : PreviewSourceBar(apps: _apps, selected: _source, onSelect: _select);
    if (_source case final src?) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ?sourceBar,
          if (src.kind == AppKind.electron && control != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: _DriverBar(userDriving: control.userDriving, onTake: control.take, onGiveBack: control.giveBack),
            ),
          Expanded(
            child: switch (src.kind) {
              // Keyed by source: each view's state (stream, picture, pending input) belongs to one target.
              AppKind.flutter => FlutterAppView(
                key: ValueKey(src),
                app: AppSources.flutter(src.uri),
                visible: _visible,
              ),
              AppKind.reactNative => ReactNativeAppView(
                key: ValueKey(src),
                app: AppSources.reactNative(src.uri),
                visible: _visible,
              ),
              AppKind.ios => IosSimulatorView(
                key: ValueKey(src),
                sim: IosSimulators.driver(src.uri.path),
                visible: _visible,
              ),
              AppKind.android => AndroidDeviceView(
                key: ValueKey(src),
                device: AndroidDevices.driver(src.uri.path),
                visible: _visible,
              ),
              AppKind.desktop => DesktopWindowView(
                key: ValueKey(src),
                window: DesktopWindows.driver(int.parse(src.uri.path)),
                visible: _visible,
              ),
              AppKind.electron =>
                b == null || (_image == null && _problem != null)
                    ? _Note(_problem ?? 'Connecting to the app…')
                    : PreviewPageView(
                        image: _image,
                        browser: b,
                        focus: _viewFocus,
                        device: null,
                        ghost: _ghost,
                        onInput: _takeOver,
                      ),
            },
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ?sourceBar,
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
          child: Row(
            children: [
              AdaptiveIconButton(
                icon: EveryIcon.chevronLeft,
                tooltip: 'Back',
                size: 16,
                onPressed: page?.canBack ?? false ? () => b!.back() : null,
              ),
              AdaptiveIconButton(
                icon: EveryIcon.chevronRight,
                tooltip: 'Forward',
                size: 16,
                onPressed: page?.canForward ?? false ? () => b!.forward() : null,
              ),
              AdaptiveIconButton(
                icon: EveryIcon.retry,
                tooltip: 'Reload',
                size: 16,
                onPressed: blank ? null : () => b!.reload(),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: AdaptiveTextField(
                  controller: _field,
                  focusNode: _fieldFocus,
                  placeholder: 'localhost:3000',
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.go,
                  onSubmitted: _go,
                ),
              ),
              if (candidates.isNotEmpty)
                AdaptiveMenuButton(
                  tooltip: 'Detected servers',
                  actions: [
                    for (final c in candidates) MenuAction(label: c, checked: c == page?.url, onSelected: () => _go(c)),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.all(7),
                    child: Icon(EveryIcon.globe.of(theme.design), size: 16, color: theme.accent),
                  ),
                ),
              if (b != null) BrowserDownloadsButton(browser: b),
              AdaptiveMenuButton(
                tooltip: 'Page size',
                actions: [
                  for (final s in PreviewSize.values)
                    MenuAction(
                      label: '${s.label}  ${s.width}×${s.height}',
                      checked: s == _size,
                      onSelected: () => _setSize(s),
                    ),
                  if (_size.device)
                    MenuAction(
                      label: _landscape ? 'Portrait' : 'Landscape',
                      onSelected: () => _setSize(_size, landscape: !_landscape),
                    ),
                ],
                child: Padding(
                  padding: const EdgeInsets.all(7),
                  child: Text(_size.label, style: theme.type.caption.tint(theme.textMuted)),
                ),
              ),
              AdaptiveMenuButton(
                tooltip: 'More',
                actions: [
                  if (!blank) MenuAction(label: 'Open in my browser', onSelected: () => _openOutside(page.url)),
                  MenuAction(label: 'Sign in to a site…', onSelected: _signIn),
                  MenuAction(label: 'Clear browser data…', destructive: true, onSelected: _clearProfile),
                ],
                child: Padding(
                  padding: const EdgeInsets.all(7),
                  child: Icon(EveryIcon.more.of(theme.design), size: 16, color: theme.textMuted),
                ),
              ),
            ],
          ),
        ),
        if (b != null) BrowserTabStrip(browser: b),
        if (_finding && b != null) BrowserFindBar(browser: b, onClose: () => setState(() => _finding = false)),
        if (control != null && !blank)
          _DriverBar(userDriving: control.userDriving, onTake: control.take, onGiveBack: control.giveBack),
        Expanded(
          child: _withDialog(
            b,
            !chromeAvailable
                ? _NeedsBrowser(progress: _downloading, problem: _problem, onDownload: _download)
                : _signingIn
                ? const _Note(
                    'Sign in in the Chrome window that opened, then close it. The Preview and the agent use the new sign-ins.',
                  )
                : _problem != null && _image == null
                ? _Note(_problem!)
                : blank && _image == null
                ? _Empty(candidates: candidates, onPick: _go)
                : PreviewPageView(
                    image: _image,
                    browser: b!,
                    focus: _viewFocus,
                    device: _size.device ? _size : null,
                    ghost: _ghost,
                    onInput: _takeOver,
                    onFind: () => setState(() => _finding = true),
                    onAddressBar: () {
                      _fieldFocus.requestFocus();
                      _field.selection = TextSelection(baseOffset: 0, extentOffset: _field.text.length);
                    },
                    onAsk: _ask,
                  ),
          ),
        ),
      ],
    );
  }

  /// [page] with the page's dialog over it, while the page waits on one.
  Widget _withDialog(HeadlessBrowser? b, Widget page) {
    if (b == null) return page;
    return ValueListenableBuilder<PageDialog?>(
      valueListenable: b.dialog,
      builder: (context, d, _) => d == null
          ? page
          : Stack(
              fit: StackFit.expand,
              children: [
                page,
                ColoredBox(
                  color: const Color(0x55000000),
                  child: PageDialogPanel(key: ValueKey(d), browser: b, dialog: d),
                ),
              ],
            ),
    );
  }
}

/// "Agent driving" or "You're driving", with the control to switch.
class _DriverBar extends StatelessWidget {
  const _DriverBar({required this.userDriving, required this.onTake, required this.onGiveBack});

  final bool userDriving;
  final VoidCallback onTake;
  final VoidCallback onGiveBack;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 6),
      padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
      decoration: BoxDecoration(
        color: userDriving ? theme.warningBg : theme.accentBg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: userDriving ? theme.warning : theme.accent, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              userDriving ? "You're driving · the agent waits" : 'Agent driving · click the page to take over',
              style: theme.type.caption.tint(theme.text),
            ),
          ),
          AdaptiveButton(
            label: userDriving ? 'Give back' : 'Take control',
            emphasis: ButtonEmphasis.secondary,
            onPressed: userDriving ? onGiveBack : onTake,
          ),
        ],
      ),
    );
  }
}

/// The page's picture, scaled into the pane, with the user's input forwarded (in the page's CSS pixels) and the
/// agent's ghost cursor on top.
@visibleForTesting
class PreviewPageView extends StatefulWidget {
  const PreviewPageView({
    super.key,
    required this.image,
    required this.browser,
    required this.focus,
    required this.device,
    required this.ghost,
    required this.onInput,
    this.onFind,
    this.onAddressBar,
    this.onAsk,
  });

  /// ⌘F (Ctrl+F): find in the page; ⌘L: the address bar; the right-click menu's "Ask the agent about this".
  final VoidCallback? onFind;
  final VoidCallback? onAddressBar;
  final void Function(String text)? onAsk;

  final ui.Image? image;
  final HeadlessBrowser browser;
  final FocusNode focus;
  final PreviewSize? device;
  final LiveActivity? ghost;
  final VoidCallback onInput;

  @override
  State<PreviewPageView> createState() => _PreviewPageViewState();
}

class _PreviewPageViewState extends State<PreviewPageView> {
  /// The `key` each held key went down with, for its key-up (which carries no character).
  final _downKeys = <PhysicalKeyboardKey, String>{};

  /// The right-click menu: where (in [_area]'s coordinates) and its items; null when closed.
  ({Offset at, List<PageMenuItem> items})? _menu;
  final _area = GlobalKey();

  /// Right-clicks answered late (the page was asked what is under the pointer) are dropped once another came.
  var _menuGen = 0;

  Future<void> _openMenu(Offset global, Offset page) async {
    final gen = ++_menuGen;
    // The page's own handler runs first: a page with its own menu shows it, and ours stays closed.
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final at = await _b.contextAt(page.dx, page.dy);
    if (!mounted || gen != _menuGen || at == null || at.prevented) return;
    final box = _area.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    setState(
      () => _menu = (
        at: box.globalToLocal(global),
        items: pageMenuItems(_b, at, ask: (text) => widget.onAsk?.call(text)),
      ),
    );
  }

  void _closeMenu() {
    _menuGen++;
    if (_menu != null) setState(() => _menu = null);
    widget.focus.requestFocus();
  }

  /// The picture's place in the pane: its offset and how many pane points one CSS pixel takes.
  var _offset = Offset.zero;
  var _scale = 1.0;
  var _buttons = 0;
  var _clicks = 0;
  DateTime _lastDown = DateTime.fromMillisecondsSinceEpoch(0);
  Offset _lastDownAt = Offset.zero;

  HeadlessBrowser get _b => widget.browser;

  Offset _toPage(Offset local) => (local - _offset) / _scale;

  static int _modifiers() {
    final k = HardwareKeyboard.instance;
    return (k.isAltPressed ? 1 : 0) |
        (k.isControlPressed ? 2 : 0) |
        (k.isMetaPressed ? 4 : 0) |
        (k.isShiftPressed ? 8 : 0);
  }

  static String _button(int buttons) => buttons & kSecondaryMouseButton != 0
      ? 'right'
      : buttons & kMiddleMouseButton != 0
      ? 'middle'
      : 'left';

  void _down(PointerDownEvent e) {
    widget.onInput();
    widget.focus.requestFocus();
    final p = _toPage(e.localPosition);
    final now = DateTime.now();
    final again = now.difference(_lastDown) < const Duration(milliseconds: 450) && (p - _lastDownAt).distance < 6;
    _clicks = again ? _clicks + 1 : 1;
    _lastDown = now;
    _lastDownAt = p;
    _buttons = e.buttons;
    unawaited(
      _b.userMouse(
        'mousePressed',
        p.dx,
        p.dy,
        button: _button(e.buttons),
        buttons: e.buttons,
        clickCount: _clicks,
        modifiers: _modifiers(),
      ),
    );
  }

  void _up(PointerUpEvent e) {
    final p = _toPage(e.localPosition);
    unawaited(
      _b.userMouse(
        'mouseReleased',
        p.dx,
        p.dy,
        button: _button(_buttons),
        clickCount: _clicks,
        modifiers: _modifiers(),
      ),
    );
    if (_buttons & kSecondaryMouseButton != 0) unawaited(_openMenu(e.position, p));
    _buttons = 0;
  }

  void _move(Offset local, int buttons) {
    final p = _toPage(local);
    unawaited(
      _b.userMouse('mouseMoved', p.dx, p.dy, button: buttons == 0 ? 'none' : _button(buttons), buttons: buttons),
    );
  }

  void _wheel(Offset local, Offset delta) {
    widget.onInput();
    final p = _toPage(local);
    unawaited(_b.userMouse('mouseWheel', p.dx, p.dy, deltaX: delta.dx / _scale, deltaY: delta.dy / _scale));
  }

  KeyEventResult _key(FocusNode node, KeyEvent e) {
    if (e is KeyRepeatEvent || e is KeyDownEvent || e is KeyUpEvent) widget.onInput();
    final meta = HardwareKeyboard.instance.isMetaPressed || HardwareKeyboard.instance.isControlPressed;
    final k = e.logicalKey;
    final down = e is! KeyUpEvent;
    // The browser's own shortcuts: find, the address bar, reload, back and forward.
    if (meta && down && !HardwareKeyboard.instance.isAltPressed) {
      final VoidCallback? shortcut = switch (k) {
        LogicalKeyboardKey.keyF => widget.onFind,
        LogicalKeyboardKey.keyL => widget.onAddressBar,
        LogicalKeyboardKey.keyR => () => unawaited(_b.reload().catchError((Object _) {})),
        LogicalKeyboardKey.bracketLeft => () => unawaited(_b.back().catchError((Object _) {})),
        LogicalKeyboardKey.bracketRight => () => unawaited(_b.forward().catchError((Object _) {})),
        _ => null,
      };
      if (shortcut != null) {
        shortcut();
        return KeyEventResult.handled;
      }
    }
    // The clipboard and editing shortcuts headless Chrome doesn't map from keys itself. Not with Alt: Ctrl+Alt is
    // AltGr on Windows and Linux, which types (AltGr+C is 'ć' on a Polish keyboard).
    if (meta && down && !HardwareKeyboard.instance.isAltPressed) {
      if (k == LogicalKeyboardKey.keyV) {
        unawaited(Clipboard.getData(Clipboard.kTextPlain).then((d) => d?.text == null ? null : _b.userText(d!.text!)));
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.keyC || k == LogicalKeyboardKey.keyX) {
        unawaited(_b.selectedText().then((t) => Clipboard.setData(ClipboardData(text: t))));
        if (k == LogicalKeyboardKey.keyC) return KeyEventResult.handled;
      }
    }
    final c = cdpKeyEvent(
      e,
      modifiers: _modifiers(),
      shift: HardwareKeyboard.instance.isShiftPressed,
      macOS: defaultTargetPlatform == TargetPlatform.macOS,
      down: down ? null : _downKeys[e.physicalKey],
    );
    if (down) {
      _downKeys[e.physicalKey] = c.key;
    } else {
      _downKeys.remove(e.physicalKey);
    }
    unawaited(
      _b.userKey(
        c.type,
        key: c.key,
        code: c.code,
        keyCode: c.keyCode,
        text: c.text,
        modifiers: c.modifiers,
        commands: c.commands,
      ),
    );
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final image = widget.image;
    return LayoutBuilder(
      builder: (context, box) {
        final g = _b.geometry;
        final pad = widget.device == null ? 0.0 : 14.0;
        final room = Size(box.maxWidth - 2 * pad - 16, box.maxHeight - 2 * pad - 16);
        _scale = (room.width / g.width).clamp(0.05, 4.0);
        if (g.height * _scale > room.height) _scale = (room.height / g.height).clamp(0.05, 4.0);
        final size = Size(g.width * _scale, g.height * _scale);
        _offset = Offset.zero;
        final ghost = widget.ghost;
        Widget pageBox = SizedBox.fromSize(
          size: size,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: image == null
                    ? ColoredBox(color: theme.well)
                    : RawImage(image: image, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
              ),
              if (ghost != null && ghost.x != null && ghost.y != null)
                Positioned(
                  left: ghost.x! * _scale - 14,
                  top: ghost.y! * _scale - 14,
                  child: IgnorePointer(
                    child: _Ripple(key: ValueKey(ghost), color: theme.accent),
                  ),
                ),
              if (ghost != null && ghost.caption.isNotEmpty)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 10,
                  child: IgnorePointer(
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: theme.overlay.withValues(alpha: 0.88),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text('Agent: ${ghost.caption}', style: theme.type.caption.tint(theme.text)),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
        pageBox = Focus(
          focusNode: widget.focus,
          onKeyEvent: _key,
          child: Listener(
            onPointerDown: _down,
            onPointerUp: _up,
            onPointerMove: (e) => _move(e.localPosition, e.buttons),
            onPointerHover: (e) => _move(e.localPosition, 0),
            onPointerSignal: (s) {
              if (s is PointerScrollEvent) _wheel(s.localPosition, s.scrollDelta);
            },
            onPointerPanZoomUpdate: (e) => _wheel(e.localPosition, -e.panDelta),
            child: MouseRegion(cursor: SystemMouseCursors.basic, child: pageBox),
          ),
        );
        if (widget.device != null) {
          pageBox = Container(
            padding: EdgeInsets.all(pad),
            decoration: BoxDecoration(
              color: const Color(0xFF111114),
              borderRadius: BorderRadius.circular(widget.device == PreviewSize.phone ? 40 : 26),
              border: Border.all(color: theme.borderStrong),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(widget.device == PreviewSize.phone ? 28 : 14),
              child: pageBox,
            ),
          );
        }
        final menu = _menu;
        return Stack(
          key: _area,
          children: [
            Center(child: pageBox),
            if (menu != null) ...[
              // A tap anywhere else closes the menu (and isn't a click on the page).
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (_) => _closeMenu(),
                  onSecondaryTapDown: (_) => _closeMenu(),
                ),
              ),
              Positioned(
                left: menu.at.dx.clamp(0, (box.maxWidth - 224).clamp(0, double.infinity)),
                top: menu.at.dy.clamp(0, (box.maxHeight - 40.0 * menu.items.length - 12).clamp(0, double.infinity)),
                child: PageContextMenu(items: menu.items, onClose: _closeMenu),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// A click ripple where the agent clicked.
class _Ripple extends StatefulWidget {
  const _Ripple({super.key, required this.color});
  final Color color;

  @override
  State<_Ripple> createState() => _RippleState();
}

class _RippleState extends State<_Ripple> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (context, _) {
      final t = Motion.easeOut.transform(_c.value);
      return SizedBox(
        width: 28,
        height: 28,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 28 * (0.4 + t),
              height: 28 * (0.4 + t),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: widget.color.withValues(alpha: 1 - t), width: 2),
              ),
            ),
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
            ),
          ],
        ),
      );
    },
  );
}

/// No Chromium here: the Chrome for Testing download.
class _NeedsBrowser extends StatelessWidget {
  const _NeedsBrowser({required this.progress, required this.problem, required this.onDownload});

  final double? progress;
  final String? problem;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Preview needs a browser', style: theme.type.headline.tint(theme.text)),
            const SizedBox(height: 6),
            Text(
              'No Chrome, Edge, Brave or Chromium found. Download Chrome for Testing (about 200 MB), or set EVERYAI_CHROME.',
              textAlign: TextAlign.center,
              style: theme.type.callout.tint(theme.textMuted),
            ),
            const SizedBox(height: 12),
            if (progress != null)
              Text('Downloading… ${(progress! * 100).round()}%', style: theme.type.caption.tint(theme.textMuted))
            else
              AdaptiveButton(label: 'Download Chrome for Testing', onPressed: onDownload),
            if (problem != null) ...[
              const SizedBox(height: 8),
              Text(problem!, textAlign: TextAlign.center, style: theme.type.caption.tint(theme.danger)),
            ],
          ],
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(text, textAlign: TextAlign.center, style: theme.type.callout.tint(theme.textMuted)),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.candidates, required this.onPick});

  final List<String> candidates;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Start a dev server, or ask the agent to. Its address shows up here, or type one above.',
              textAlign: TextAlign.center,
              style: theme.type.callout.tint(theme.textMuted),
            ),
            for (final c in candidates) ...[
              const SizedBox(height: 8),
              AdaptiveButton(label: c, emphasis: ButtonEmphasis.secondary, onPressed: () => onPick(c)),
            ],
          ],
        ),
      ),
    );
  }
}

/// The DOM `key`, physical `code` and Windows key code of [e], from its physical key ([keysByUsage]); [down] is the
/// `key` its key-down had (a key-up carries no character).
({String key, String code, int keyCode}) domKeyOf(KeyEvent e, {String? down}) {
  final info = keysByUsage[e.physicalKey.usbHidUsage];
  final ch = e.character;
  final printable = ch != null && ch.isNotEmpty && !_controlChar(ch);
  final key =
      down ??
      (printable ? ch : null) ??
      info?.named ??
      info?.plain ??
      (e.logicalKey.keyLabel.isEmpty ? 'Unidentified' : e.logicalKey.keyLabel);
  return (key: key, code: info?.code ?? '', keyCode: info?.vk ?? 0);
}

/// The DevTools key event for the user's key event [e] in the Preview: [modifiers] as CDP bits ([cdpShift]…),
/// [shift] for the editing commands, [down] the `key` of [e]'s key-down when [e] is its key-up. ⌘, or Ctrl, makes a
/// shortcut instead of text, except Ctrl+Alt off macOS, which is AltGr typing a character (@ on German keyboards).
({String type, String key, String code, int keyCode, String? text, int modifiers, List<String> commands}) cdpKeyEvent(
  KeyEvent e, {
  required int modifiers,
  required bool shift,
  bool macOS = false,
  String? down,
}) {
  final isDown = e is! KeyUpEvent;
  final ch = e.character;
  final printable = ch != null && ch.isNotEmpty && !_controlChar(ch);
  final altGr = !macOS && printable && modifiers & cdpAlt != 0 && modifiers & cdpMeta == 0;
  final command = modifiers & cdpMeta != 0 || (modifiers & cdpControl != 0 && !altGr);
  final dom = domKeyOf(e, down: isDown ? null : down);
  final commands = command && isDown ? editingCommands(e.logicalKey, shift: shift) : const <String>[];
  final text = !command && isDown && printable ? ch : null;
  return (
    type: !isDown ? 'keyUp' : (text != null ? 'keyDown' : 'rawKeyDown'),
    key: dom.key,
    code: dom.code,
    keyCode: dom.keyCode,
    text: text,
    modifiers: modifiers,
    commands: commands,
  );
}

bool _controlChar(String s) => s.codeUnits.every((c) => c < 0x20 || c == 0x7F);

/// The editing commands Chrome runs for ⌘/Ctrl+[k] (headless Chrome doesn't map them from keys).
List<String> editingCommands(LogicalKeyboardKey k, {required bool shift}) {
  if (k == LogicalKeyboardKey.keyA) return const ['selectAll'];
  if (k == LogicalKeyboardKey.keyZ) return shift ? const ['redo'] : const ['undo'];
  if (k == LogicalKeyboardKey.keyY) return const ['redo'];
  if (k == LogicalKeyboardKey.keyX) return const ['cut'];
  return const [];
}

enum _Cast { off, starting, on }
