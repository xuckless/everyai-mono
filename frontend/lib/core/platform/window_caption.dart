import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import '../motion/motion.dart';
import '../theme/every_theme.dart';
import '../ui/every_icons.dart';

/// Windows and Linux windows have no native title bar: the app draws its own strip with minimize, maximize and
/// close, in the app's colours, so no system frame (a white or black band) shows around it. macOS keeps its traffic
/// lights over the sidebar.
bool get hasCustomCaption =>
    !kIsWeb && (defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.linux);

/// Height of the caption strip above the content panel.
const windowCaptionHeight = 36.0;

/// Width the window buttons take at the strip's right.
double get windowButtonsWidth => defaultTargetPlatform == TargetPlatform.windows ? 46.0 * 3 : 6 * 2 + 30.0 * 3;

/// The draggable strip a layout keeps at its top: drag it to move the window, double-click it to maximize or
/// restore. The buttons themselves float above everything ([WindowButtonsOverlay]); the strip leaves room for them.
class WindowCaption extends StatelessWidget {
  const WindowCaption({super.key});

  @override
  Widget build(BuildContext context) => SizedBox(
    height: windowCaptionHeight,
    child: Padding(
      padding: EdgeInsets.only(right: windowButtonsWidth),
      child: const WindowDragArea(key: ValueKey('caption.drag'), child: SizedBox.expand()),
    ),
  );
}

/// [child] as a handle for the window on Windows and Linux: dragging its empty parts moves the window and a
/// double-click maximizes or restores it; buttons inside still get their clicks. [child] alone elsewhere.
class WindowDragArea extends StatefulWidget {
  const WindowDragArea({super.key, required this.child});

  final Widget child;

  @override
  State<WindowDragArea> createState() => _WindowDragAreaState();
}

class _WindowDragAreaState extends State<WindowDragArea> {
  Duration? _lastDown;

  @override
  Widget build(BuildContext context) {
    if (!hasCustomCaption) return widget.child;
    // A raw Listener, not a double-tap recognizer, so a double-click doesn't delay single clicks.
    return Listener(
      onPointerDown: (e) {
        if (e.kind == PointerDeviceKind.mouse && e.buttons != kPrimaryMouseButton) return;
        final last = _lastDown;
        _lastDown = e.timeStamp;
        if (last != null && e.timeStamp - last < kDoubleTapTimeout) {
          _lastDown = null;
          _toggleMaximize();
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => windowManager.startDragging(),
        child: widget.child,
      ),
    );
  }
}

Future<void> _toggleMaximize() async =>
    await windowManager.isMaximized() ? windowManager.unmaximize() : windowManager.maximize();

/// Puts the window buttons over [child] at the top right, above routes and dialogs (the app's root builder), on
/// Windows and Linux only.
class WindowButtonsOverlay extends StatelessWidget {
  const WindowButtonsOverlay({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!hasCustomCaption) return child;
    return WindowResizeEdges(
      child: Stack(
        children: [
          Positioned.fill(child: child),
          const Positioned(top: 0, right: 0, height: windowCaptionHeight, child: WindowButtons()),
        ],
      ),
    );
  }
}

/// Minimize, maximize (restore while maximized) and close. Windows: flat 46pt cells, red under the pointer on
/// close; Linux: small round buttons.
class WindowButtons extends StatefulWidget {
  const WindowButtons({super.key});

  @override
  State<WindowButtons> createState() => _WindowButtonsState();
}

class _WindowButtonsState extends State<WindowButtons> with WindowListener {
  bool _maximized = false;
  bool _focused = true;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then((v) {
      if (mounted) setState(() => _maximized = v);
    }, onError: (_) {});
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  @override
  void onWindowFocus() => setState(() => _focused = true);

  @override
  void onWindowBlur() => setState(() => _focused = false);

  @override
  Widget build(BuildContext context) {
    final windows = defaultTargetPlatform == TargetPlatform.windows;
    final buttons = [
      _CaptionButton(
        key: const ValueKey('caption.minimize'),
        icon: EveryIcon.minus,
        tooltip: 'Minimize',
        windows: windows,
        dimmed: !_focused,
        onTap: windowManager.minimize,
      ),
      _CaptionButton(
        key: const ValueKey('caption.maximize'),
        icon: _maximized ? EveryIcon.copy : EveryIcon.stop,
        tooltip: _maximized ? 'Restore' : 'Maximize',
        windows: windows,
        dimmed: !_focused,
        onTap: _toggleMaximize,
      ),
      _CaptionButton(
        key: const ValueKey('caption.close'),
        icon: EveryIcon.close,
        tooltip: 'Close',
        windows: windows,
        dimmed: !_focused,
        close: true,
        onTap: windowManager.close,
      ),
    ];
    return SizedBox(
      width: windowButtonsWidth,
      child: windows
          ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: buttons)
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                children: [
                  for (final b in buttons) Padding(padding: const EdgeInsets.symmetric(horizontal: 3), child: b),
                ],
              ),
            ),
    );
  }
}

class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.windows,
    required this.onTap,
    this.dimmed = false,
    this.close = false,
  });

  final EveryIcon icon;
  final String tooltip;
  final bool windows;
  final bool dimmed;
  final bool close;
  final VoidCallback onTap;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hover = false;
  bool _down = false;

  /// The Windows close button's red (Fluent's caption close colour).
  static const _closeRed = Color(0xFFC42B1C);

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final red = widget.windows && widget.close && (_hover || _down);
    final fill = red
        ? (_down ? _closeRed.withValues(alpha: 0.85) : _closeRed)
        : _down
        ? theme.pressed
        : _hover
        ? theme.hover
        : widget.windows
        ? null
        : theme.hover.withValues(alpha: theme.isDark ? 0.9 : 0.7);
    final fg = red ? const Color(0xFFFFFFFF) : (widget.dimmed ? theme.textSubtle : theme.textMuted);
    final cell = AnimatedContainer(
      duration: Motion.reduced(context) ? Duration.zero : const Duration(milliseconds: 120),
      width: widget.windows ? 46 : 24,
      height: widget.windows ? windowCaptionHeight : 24,
      decoration: BoxDecoration(color: fill, shape: widget.windows ? BoxShape.rectangle : BoxShape.circle),
      alignment: Alignment.center,
      child: Icon(widget.icon.data, size: widget.windows ? 14 : 13, color: fg),
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _down = true),
        onTapCancel: () => setState(() => _down = false),
        onTap: () {
          setState(() => _down = false);
          widget.onTap();
        },
        child: Semantics(
          button: true,
          label: widget.tooltip,
          child: Center(child: cell),
        ),
      ),
    );
  }
}

/// Resize handles for a window without a native frame: every edge on Linux (an undecorated GTK window has none),
/// the top edges on Windows (the hidden caption took them). None while maximized.
class WindowResizeEdges extends StatefulWidget {
  const WindowResizeEdges({super.key, required this.child});

  final Widget child;

  @override
  State<WindowResizeEdges> createState() => _WindowResizeEdgesState();
}

class _WindowResizeEdgesState extends State<WindowResizeEdges> with WindowListener {
  bool _full = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then((v) {
      if (mounted) setState(() => _full = v);
    }, onError: (_) {});
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _full = true);

  @override
  void onWindowUnmaximize() => setState(() => _full = false);

  @override
  void onWindowEnterFullScreen() => setState(() => _full = true);

  @override
  void onWindowLeaveFullScreen() => setState(() => _full = false);

  @override
  Widget build(BuildContext context) {
    if (!hasCustomCaption) return widget.child;
    return DragToResizeArea(
      resizeEdgeSize: 6,
      enableResizeEdges: _full
          ? const []
          : defaultTargetPlatform == TargetPlatform.windows
          ? const [ResizeEdge.topLeft, ResizeEdge.top, ResizeEdge.topRight]
          : null,
      child: widget.child,
    );
  }
}

/// [child] under the draggable strip on Windows and Linux (screens outside the shell: sign-in, onboarding, the
/// full-window Settings); [child] alone elsewhere.
class WithWindowCaption extends StatelessWidget {
  const WithWindowCaption({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => hasCustomCaption
      ? Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const WindowCaption(),
            Expanded(child: child),
          ],
        )
      : child;
}
