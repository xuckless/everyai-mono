// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../../core/theme/every_theme.dart';
import '../../live/live_session.dart';
import '../../live/webview_browser.dart';
import '../../live/webview_model.dart';
import 'preview_pane.dart' show AgentRipple, PreviewSize;

/// The session's page in the OS webview, embedded: the tab's own native view (the one the agent drives offscreen),
/// with the user's input going to it natively while they have control (typing, IME, copy and paste, right-click,
/// drag, pinch). While the agent has it the view is watch-only: a layer over it takes every click and wheel (each
/// hints at Take control), and the native side keeps the keyboard from it ([WebviewBrowser] locks the view).
class WebviewPageView extends StatefulWidget {
  const WebviewPageView({
    super.key,
    required this.browser,
    required this.focus,
    required this.device,
    required this.ghost,
    this.onFind,
    this.onAddressBar,
    this.onAsk,
  });

  final WebviewBrowser browser;
  final FocusNode focus;
  final PreviewSize? device;
  final LiveActivity? ghost;
  final VoidCallback? onFind;
  final VoidCallback? onAddressBar;
  final void Function(String text)? onAsk;

  @override
  State<WebviewPageView> createState() => _WebviewPageViewState();
}

class _WebviewPageViewState extends State<WebviewPageView> {
  StreamSubscription<String>? _shortcuts;
  StreamSubscription<String>? _asks;

  WebviewBrowser get _b => widget.browser;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(WebviewPageView old) {
    super.didUpdateWidget(old);
    if (!identical(old.browser, widget.browser)) {
      _unlisten(old.browser);
      _listen();
    }
  }

  void _listen() {
    _b.tabs.addListener(_changed);
    _b.life.addListener(_changed);
    _b.requestedSize.addListener(_changed);
    _b.control.addListener(_controlChanged);
    _shortcuts = _b.shortcuts.listen(_shortcut);
    _asks = _b.asks.listen((text) => widget.onAsk?.call(text));
  }

  void _unlisten(WebviewBrowser b) {
    b.tabs.removeListener(_changed);
    b.life.removeListener(_changed);
    b.requestedSize.removeListener(_changed);
    b.control.removeListener(_controlChanged);
    unawaited(_shortcuts?.cancel());
    unawaited(_asks?.cancel());
  }

  @override
  void dispose() {
    _unlisten(_b);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _controlChanged() {
    // The agent took the view back: the keyboard comes to the Preview (the native side lets go of it too).
    if (!_b.control.phase.userMayAct) widget.focus.requestFocus();
    _changed();
  }

  void _shortcut(String key) {
    final may = _b.control.phase.userMayAct;
    switch (key) {
      case 'f':
        widget.onFind?.call();
      case 'l':
        widget.onAddressBar?.call();
      case 'r' when may:
        unawaited(_b.reload().catchError((Object _) {}));
      case '[' when may:
        unawaited(_b.back().catchError((Object _) {}));
      case ']' when may:
        unawaited(_b.forward().catchError((Object _) {}));
    }
  }

  /// Keys while the Preview (not the page) has the keyboard: the browser's shortcuts, and copying the selection.
  KeyEventResult _key(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = HardwareKeyboard.instance;
    if (!(k.isMetaPressed || k.isControlPressed) || k.isAltPressed) {
      _b.control.mayAct();
      return KeyEventResult.ignored;
    }
    final key = switch (e.logicalKey) {
      LogicalKeyboardKey.keyF => 'f',
      LogicalKeyboardKey.keyL => 'l',
      LogicalKeyboardKey.keyR => 'r',
      LogicalKeyboardKey.bracketLeft => '[',
      LogicalKeyboardKey.bracketRight => ']',
      LogicalKeyboardKey.keyC => 'c',
      _ => null,
    };
    if (key == null) return KeyEventResult.ignored;
    if (key == 'c') {
      unawaited(_b.selectedText().then((t) => Clipboard.setData(ClipboardData(text: t))).catchError((Object _) {}));
    } else {
      _shortcut(key);
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final tab = _b.activeWebTab;
    final may = _b.control.phase.userMayAct;
    return LayoutBuilder(
      builder: (context, box) {
        final pad = widget.device == null ? 0.0 : 14.0;
        final want = _b.requestedSize.value;
        // The pane's room wins over the size picked (the page takes the view's size).
        final size = Size(
          math.max(200, math.min(want.width, box.maxWidth - 2 * pad - 16)),
          math.max(200, math.min(want.height, box.maxHeight - 2 * pad - 16)),
        );
        _b.paneSize(size);
        final ghost = widget.ghost;
        Widget pageBox = SizedBox.fromSize(
          size: size,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: tab == null
                    ? ColoredBox(color: theme.well)
                    : _TabHost(key: ValueKey(tab.id), browser: _b, tab: tab, well: theme.well),
              ),
              // Watch-only: Flutter paints over the native view, so the engine sends clicks and the wheel here
              // instead of to the view (its hit test skips what Flutter draws on top).
              if (!may)
                Positioned.fill(
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: (_) {
                      widget.focus.requestFocus();
                      _b.control.mayAct();
                    },
                    onPointerSignal: (s) {
                      if (s is PointerScrollEvent) _b.control.mayAct();
                    },
                    onPointerPanZoomStart: (_) => _b.control.mayAct(),
                    child: const ColoredBox(color: Color(0x01000000)),
                  ),
                ),
              if (ghost != null && ghost.x != null && ghost.y != null)
                Positioned(
                  left: ghost.x! - 14,
                  top: ghost.y! - 14,
                  child: IgnorePointer(
                    child: AgentRipple(key: ValueKey(ghost), color: theme.accent),
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
        pageBox = Focus(focusNode: widget.focus, onKeyEvent: _key, child: pageBox);
        if (widget.device != null) {
          pageBox = Container(
            padding: EdgeInsets.all(pad),
            decoration: BoxDecoration(
              color: const Color(0xFF111114),
              borderRadius: BorderRadius.circular(widget.device == PreviewSize.phone ? 40 : 26),
              border: Border.all(color: theme.borderStrong),
            ),
            child: pageBox,
          );
        }
        return Center(child: pageBox);
      },
    );
  }
}

/// One tab's native view on screen. A view the Preview let go of a moment ago is still being parked: it is shown
/// again once that's done (the platform view can't be handed over twice in one frame).
class _TabHost extends StatefulWidget {
  const _TabHost({super.key, required this.browser, required this.tab, required this.well});

  final WebviewBrowser browser;
  final WebTab tab;
  final Color well;

  @override
  State<_TabHost> createState() => _TabHostState();
}

class _TabHostState extends State<_TabHost> {
  @override
  void initState() {
    super.initState();
    widget.tab.lifeChanges.addListener(_changed);
  }

  @override
  void dispose() {
    widget.tab.lifeChanges.removeListener(_changed);
    widget.browser.tabHidden(widget.tab);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => switch (widget.tab.life) {
    TabLife.headless ||
    TabLife.parked ||
    TabLife.unparked ||
    TabLife.shown => widget.browser.tabView(widget.tab, key: GlobalObjectKey(widget.tab)),
    TabLife.starting || TabLife.parking || TabLife.closed => ColoredBox(color: widget.well),
  };
}
