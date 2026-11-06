import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/every_icons.dart';
import '../../code_providers.dart' show codeProjectsProvider;
import '../../domain/code_session.dart';
import '../../domain/local_ports.dart';
import '../../git/git_service.dart';
import '../../harness/everyai/browser_io.dart';
import '../../harness/everyai/screen_tools_io.dart' show noteUserNavigation;
import '../../live/chrome_download.dart';
import '../../live/live_browsers.dart';
import '../../live/live_session.dart';
import '../../panes/panes_providers.dart';
import '../../panes/processes.dart';

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
  var _casting = false;
  var _decoding = false;
  DateTime _lastAck = DateTime.fromMillisecondsSinceEpoch(0);
  var _appVisible = true;
  var _size = PreviewSize.desktop;
  var _landscape = false;
  String? _problem;
  var _signingIn = false;
  double? _downloading;

  /// The agent's last action, for the ghost cursor and caption.
  LiveActivity? _ghost;
  Timer? _ghostTimer;

  String get _id => widget.session.id;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _field.text = ref.read(previewUrlProvider(_id)) ?? '';
    unawaited(loadDownloadedChrome().then((_) => mounted ? setState(() {}) : null));
    _attach(LiveBrowsers.of(_id));
    // The agent may make the page later (its first browser call).
    _made = LiveBrowsers.changes.where((s) => s == _id).listen((_) => _attach(LiveBrowsers.of(_id)));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _made?.cancel();
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
    _appVisible = state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
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
    unawaited(_activity?.cancel());
    unawaited(_frames?.cancel());
    if (_casting) unawaited(b.stopScreencast());
    _casting = false;
    _browser = null;
  }

  void _pageChanged() {
    final url = _browser?.page.value.url ?? '';
    if (!_fieldFocus.hasFocus && url.isNotEmpty && url != 'about:blank') _field.text = url;
    if (mounted) setState(() {});
  }

  void _controlChanged() {
    if (mounted) setState(() {});
  }

  /// Paints only while the Preview shows.
  void _syncCasting() {
    final b = _browser;
    if (b == null) return;
    final want = _visible && (b.page.value.url.isNotEmpty || b.running);
    if (want == _casting) return;
    _casting = want;
    unawaited(
      (want ? b.startScreencast() : b.stopScreencast()).catchError((Object e) {
        if (mounted) setState(() => _problem = '$e');
      }),
    );
  }

  Future<void> _paint(ScreencastFrame f) async {
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
    final b = await _ensure();
    setState(() => _signingIn = true);
    final url = b.page.value.url;
    try {
      await b.close();
      await b.host.signIn(url.isEmpty || url == 'about:blank' ? 'https://accounts.google.com' : url);
      if (url.isNotEmpty) await b.userOpen(url);
    } on BrowserError catch (e) {
      if (mounted) setState(() => _problem = e.message);
    } finally {
      if (mounted) setState(() => _signingIn = false);
      _casting = false;
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
    _casting = false;
    if (mounted) setState(() => _image = null);
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
        if (control != null && !blank)
          _DriverBar(userDriving: control.userDriving, onTake: control.take, onGiveBack: control.giveBack),
        Expanded(
          child: !chromeAvailable
              ? _NeedsBrowser(progress: _downloading, problem: _problem, onDownload: _download)
              : _signingIn
              ? const _Note(
                  'Sign in in the Chrome window that opened. Close that window when you are done: the Preview '
                  'and the agent then use the new sign-ins.',
                )
              : _problem != null && _image == null
              ? _Note(_problem!)
              : blank && _image == null
              ? _Empty(candidates: candidates, onPick: _go)
              : _PageView(
                  image: _image,
                  browser: b!,
                  focus: _viewFocus,
                  device: _size.device ? _size : null,
                  ghost: _ghost,
                  onInput: _takeOver,
                ),
        ),
      ],
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
class _PageView extends StatefulWidget {
  const _PageView({
    required this.image,
    required this.browser,
    required this.focus,
    required this.device,
    required this.ghost,
    required this.onInput,
  });

  final ui.Image? image;
  final HeadlessBrowser browser;
  final FocusNode focus;
  final PreviewSize? device;
  final LiveActivity? ghost;
  final VoidCallback onInput;

  @override
  State<_PageView> createState() => _PageViewState();
}

class _PageViewState extends State<_PageView> {
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
    // The clipboard and editing shortcuts headless Chrome doesn't map from keys itself.
    if (meta && down) {
      if (k == LogicalKeyboardKey.keyV) {
        unawaited(Clipboard.getData(Clipboard.kTextPlain).then((d) => d?.text == null ? null : _b.userText(d!.text!)));
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.keyC || k == LogicalKeyboardKey.keyX) {
        unawaited(_b.selectedText().then((t) => Clipboard.setData(ClipboardData(text: t))));
        if (k == LogicalKeyboardKey.keyC) return KeyEventResult.handled;
      }
    }
    final dom = domKeyOf(e);
    final commands = meta && down
        ? editingCommands(k, shift: HardwareKeyboard.instance.isShiftPressed)
        : const <String>[];
    final text = !meta && down && e.character != null && e.character!.isNotEmpty && !_controlChar(e.character!)
        ? e.character
        : null;
    unawaited(
      _b.userKey(
        !down ? 'keyUp' : (text != null ? 'keyDown' : 'rawKeyDown'),
        key: dom.key,
        code: dom.code,
        keyCode: dom.keyCode,
        text: text,
        modifiers: _modifiers(),
        commands: commands,
      ),
    );
    return KeyEventResult.handled;
  }

  static bool _controlChar(String s) => s.codeUnits.every((c) => c < 0x20 || c == 0x7F);

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
        return Center(child: pageBox);
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
      final t = Curves.easeOut.transform(_c.value);
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
              'No Chrome, Edge, Brave or Chromium was found. EveryAI can download Chrome for Testing '
              '(about 200 MB, kept in its own folder), or set EVERYAI_CHROME to a browser of yours.',
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
              'Start a dev server in the Terminal, or ask the agent to; its address shows up here. You can also type '
              'one above. The agent and you share this page.',
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

/// The DOM `key`, `code` and Windows key code of a Flutter key event, for Chrome's key events.
({String key, String code, int keyCode}) domKeyOf(KeyEvent e) {
  final k = e.logicalKey;
  final table = <LogicalKeyboardKey, (String, int)>{
    LogicalKeyboardKey.enter: ('Enter', 13),
    LogicalKeyboardKey.numpadEnter: ('Enter', 13),
    LogicalKeyboardKey.backspace: ('Backspace', 8),
    LogicalKeyboardKey.tab: ('Tab', 9),
    LogicalKeyboardKey.escape: ('Escape', 27),
    LogicalKeyboardKey.space: (' ', 32),
    LogicalKeyboardKey.delete: ('Delete', 46),
    LogicalKeyboardKey.arrowUp: ('ArrowUp', 38),
    LogicalKeyboardKey.arrowDown: ('ArrowDown', 40),
    LogicalKeyboardKey.arrowLeft: ('ArrowLeft', 37),
    LogicalKeyboardKey.arrowRight: ('ArrowRight', 39),
    LogicalKeyboardKey.home: ('Home', 36),
    LogicalKeyboardKey.end: ('End', 35),
    LogicalKeyboardKey.pageUp: ('PageUp', 33),
    LogicalKeyboardKey.pageDown: ('PageDown', 34),
    LogicalKeyboardKey.shiftLeft: ('Shift', 16),
    LogicalKeyboardKey.shiftRight: ('Shift', 16),
    LogicalKeyboardKey.controlLeft: ('Control', 17),
    LogicalKeyboardKey.controlRight: ('Control', 17),
    LogicalKeyboardKey.altLeft: ('Alt', 18),
    LogicalKeyboardKey.altRight: ('Alt', 18),
    LogicalKeyboardKey.metaLeft: ('Meta', 91),
    LogicalKeyboardKey.metaRight: ('Meta', 91),
  };
  if (table[k] case (final key, final code)) {
    final dom = key == ' ' ? 'Space' : key;
    return (
      key: key,
      code: dom == 'Shift' || dom == 'Control' || dom == 'Alt' || dom == 'Meta' ? '${dom}Left' : dom,
      keyCode: code,
    );
  }
  final ch = e.character ?? k.keyLabel;
  if (ch.length == 1) {
    final up = ch.toUpperCase();
    final c = up.codeUnitAt(0);
    if (c >= 0x41 && c <= 0x5A) return (key: ch, code: 'Key$up', keyCode: c);
    if (c >= 0x30 && c <= 0x39) return (key: ch, code: 'Digit$up', keyCode: c);
    return (key: ch, code: '', keyCode: c);
  }
  return (key: k.keyLabel, code: '', keyCode: 0);
}

/// The editing commands Chrome runs for ⌘/Ctrl+[k] (headless Chrome doesn't map them from keys).
List<String> editingCommands(LogicalKeyboardKey k, {required bool shift}) {
  if (k == LogicalKeyboardKey.keyA) return const ['selectAll'];
  if (k == LogicalKeyboardKey.keyZ) return shift ? const ['redo'] : const ['undo'];
  if (k == LogicalKeyboardKey.keyY) return const ['redo'];
  if (k == LogicalKeyboardKey.keyX) return const ['cut'];
  return const [];
}
