// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../live/app_endpoints.dart';
import '../../live/app_sources.dart';
import '../../live/app_view.dart';
import '../../live/axe_install.dart';
import '../../live/flutter_app_io.dart';
import '../../live/ios_simulator_io.dart';
import '../../live/live_session.dart';
import '../../live/react_native_io.dart';

// The Preview's views of the session's running apps (see AppSources): a Flutter app's picture with taps and the
// wheel passed on, and a React Native app's element list.

/// The sources the Preview can show: the web page, then each app the session runs.
class PreviewSourceBar extends StatelessWidget {
  const PreviewSourceBar({super.key, required this.apps, required this.selected, required this.onSelect});

  final List<SessionApp> apps;

  /// The selected app's endpoint, or null for the web page.
  final AppEndpoint? selected;
  final ValueChanged<AppEndpoint?> onSelect;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          KitChip(label: 'Web', on: selected == null, onTap: () => onSelect(null)),
          for (final a in apps)
            KitChip(
              label: a.kind == AppKind.ios
                  ? a.label
                  : a.shell == null
                  ? a.kind.label
                  : '${a.kind.label} · ${a.shell!.id}',
              on: selected == a.endpoint,
              onTap: () => onSelect(a.endpoint),
            ),
        ],
      ),
    ),
  );
}

/// "Agent driving" / "You're driving" for an app, with the switch.
class AppDriverBar extends StatelessWidget {
  const AppDriverBar({super.key, required this.control, this.actions = const []});

  final LiveControl control;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return ListenableBuilder(
      listenable: control,
      builder: (context, _) {
        final user = control.userDriving;
        return Container(
          margin: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
          decoration: BoxDecoration(
            color: user ? theme.warningBg : theme.accentBg,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: user ? theme.warning : theme.accent, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  user ? "You're driving · the agent waits" : 'Agent driving · click the app to take over',
                  style: theme.type.caption.tint(theme.text),
                ),
              ),
              ...actions,
              const SizedBox(width: 4),
              AdaptiveButton(
                label: user ? 'Give back' : 'Take control',
                emphasis: ButtonEmphasis.secondary,
                onPressed: user ? control.giveBack : control.take,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A Flutter app's live picture (refreshed a few times a second while shown, and right after the agent acts), with
/// the user's taps and wheel passed on and the agent's ghost cursor on top.
class FlutterAppView extends StatefulWidget {
  const FlutterAppView({super.key, required this.app, required this.visible});

  final FlutterApp app;

  /// Whether the Preview shows (no pictures are taken while hidden).
  final bool visible;

  @override
  State<FlutterAppView> createState() => _FlutterAppViewState();
}

class _FlutterAppViewState extends State<FlutterAppView> {
  ui.Image? _image;
  Timer? _timer;
  var _busy = false;
  String? _problem;
  StreamSubscription<LiveActivity>? _activity;
  LiveActivity? _ghost;
  Timer? _ghostTimer;
  var _scale = 1.0;
  Offset? _downAt;
  var _reloading = false;

  FlutterApp get _app => widget.app;

  @override
  void initState() {
    super.initState();
    _listen();
    _sync();
  }

  @override
  void didUpdateWidget(FlutterAppView old) {
    super.didUpdateWidget(old);
    if (!identical(old.app, widget.app)) {
      unawaited(_activity?.cancel());
      _listen();
      _image?.dispose();
      _image = null;
    }
    _sync();
  }

  void _listen() {
    _activity = _app.control.activity.listen((a) {
      _ghostTimer?.cancel();
      setState(() => _ghost = a);
      _ghostTimer = Timer(const Duration(milliseconds: 1600), () {
        if (mounted) setState(() => _ghost = null);
      });
      // What the agent did shows soon after.
      Timer(const Duration(milliseconds: 350), _refresh);
    });
  }

  void _sync() {
    if (widget.visible && _timer == null) {
      _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _refresh());
      _refresh();
    } else if (!widget.visible) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ghostTimer?.cancel();
    unawaited(_activity?.cancel());
    _image?.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_busy || !mounted || !widget.visible) return;
    _busy = true;
    try {
      final png = await _app.previewShot();
      final codec = await ui.instantiateImageCodec(Uint8List.fromList(png));
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
    } on Object catch (e) {
      if (mounted) setState(() => _problem = e is AppError ? e.message : '$e');
    } finally {
      _busy = false;
    }
  }

  void _takeOver() {
    final c = _app.control;
    if (c.userDriving) return;
    c.take();
    showAdaptiveToast(context, "You're driving: the agent's app actions wait until you give it back.");
  }

  Future<void> _reload(bool restart) async {
    setState(() => _reloading = true);
    try {
      await _app.reload(restart: restart);
    } on AppError catch (e) {
      if (mounted) showAdaptiveToast(context, e.message);
    } finally {
      if (mounted) setState(() => _reloading = false);
      unawaited(_refresh());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final image = _image;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppDriverBar(
          control: _app.control,
          actions: [
            AdaptiveButton(
              label: 'Hot reload',
              emphasis: ButtonEmphasis.secondary,
              onPressed: _reloading ? null : () => _reload(false),
            ),
            const SizedBox(width: 4),
            AdaptiveButton(
              label: 'Restart',
              emphasis: ButtonEmphasis.secondary,
              onPressed: _reloading ? null : () => _reload(true),
            ),
          ],
        ),
        Expanded(
          child: image == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _problem ?? 'Connecting to the Flutter app…',
                      textAlign: TextAlign.center,
                      style: theme.type.callout.tint(theme.textMuted),
                    ),
                  ),
                )
              : LayoutBuilder(
                  builder: (context, box) {
                    final w = _app.width <= 0 ? image.width.toDouble() : _app.width;
                    final h = _app.height <= 0 ? image.height.toDouble() : _app.height;
                    _scale = ((box.maxWidth - 16) / w).clamp(0.05, 4.0);
                    if (h * _scale > box.maxHeight - 16) _scale = ((box.maxHeight - 16) / h).clamp(0.05, 4.0);
                    final ghost = _ghost;
                    return Center(
                      child: Listener(
                        onPointerDown: (e) => _downAt = e.localPosition,
                        onPointerUp: (e) {
                          final at = _downAt;
                          _downAt = null;
                          if (at == null || (e.localPosition - at).distance > 8) return;
                          _takeOver();
                          final p = e.localPosition / _scale;
                          unawaited(_app.userTap(p.dx, p.dy).then((_) => _refresh(), onError: (Object _) {}));
                        },
                        onPointerSignal: (s) {
                          if (s is! PointerScrollEvent) return;
                          _takeOver();
                          final p = s.localPosition / _scale;
                          unawaited(
                            _app
                                .userScroll(p.dx, p.dy, s.scrollDelta.dy / _scale)
                                .then((_) => _refresh(), onError: (Object _) {}),
                          );
                        },
                        child: SizedBox(
                          width: w * _scale,
                          height: h * _scale,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Positioned.fill(
                                child: RawImage(image: image, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
                              ),
                              if (ghost != null && ghost.x != null && ghost.y != null)
                                Positioned(
                                  left: ghost.x! * _scale - 14,
                                  top: ghost.y! * _scale - 14,
                                  child: IgnorePointer(
                                    child: Container(
                                      width: 28,
                                      height: 28,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        border: Border.all(color: theme.accent, width: 2),
                                        color: theme.accent.withValues(alpha: 0.18),
                                      ),
                                    ),
                                  ),
                                ),
                              if (ghost != null && ghost.caption.isNotEmpty)
                                Positioned(left: 0, right: 0, bottom: 10, child: _Caption('Agent: ${ghost.caption}')),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Text(
            'Taps and the wheel go to the app. Type in its own window.',
            style: theme.type.caption.tint(theme.textMuted),
          ),
        ),
      ],
    );
  }
}

class _Caption extends StatelessWidget {
  const _Caption(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return IgnorePointer(
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: theme.overlay.withValues(alpha: 0.88),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(text, style: theme.type.caption.tint(theme.text)),
        ),
      ),
    );
  }
}

/// A React Native app's element list, read again every two seconds while shown (the app draws in its simulator or
/// emulator; those views come later).
class ReactNativeAppView extends StatefulWidget {
  const ReactNativeAppView({super.key, required this.app, required this.visible});

  final ReactNativeApp app;
  final bool visible;

  @override
  State<ReactNativeAppView> createState() => _ReactNativeAppViewState();
}

class _ReactNativeAppViewState extends State<ReactNativeAppView> {
  String? _text;
  String? _problem;
  Timer? _timer;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(ReactNativeAppView old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.visible && _timer == null) {
      _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
      _refresh();
    } else if (!widget.visible) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_busy || !mounted) return;
    _busy = true;
    try {
      final text = await widget.app.snapshot();
      if (mounted) {
        setState(() {
          _text = text;
          _problem = null;
        });
      }
    } on Object catch (e) {
      if (mounted) setState(() => _problem = e is AppError ? e.message : '$e');
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppDriverBar(
          control: widget.app.control,
          actions: [
            AdaptiveButton(
              label: 'Reload',
              emphasis: ButtonEmphasis.secondary,
              onPressed: () => widget.app.reload().then((_) => _refresh(), onError: (Object _) {}),
            ),
          ],
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
            child: Text(
              _problem ?? _text ?? 'Reading the app…',
              style: theme.type.caption.mono.tint(_problem == null ? theme.text : theme.textMuted),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Text(
            "React Native draws in its simulator or emulator: this is the app's element list, as the agent reads it.",
            style: theme.type.caption.tint(theme.textMuted),
          ),
        ),
      ],
    );
  }
}

/// An iOS Simulator's live screen (AXe's stream while shown), with taps and the wheel passed on as touches and
/// swipes, a Home button, and the agent's ghost on top. Offers to download AXe when it isn't there.
class IosSimulatorView extends StatefulWidget {
  const IosSimulatorView({super.key, required this.sim, required this.visible});

  final IosSimulator sim;
  final bool visible;

  @override
  State<IosSimulatorView> createState() => _IosSimulatorViewState();
}

class _IosSimulatorViewState extends State<IosSimulatorView> {
  ui.Image? _image;
  StreamSubscription<Uint8List>? _frames;
  StreamSubscription<LiveActivity>? _activity;
  var _decoding = false;
  String? _problem;
  double? _installing;
  LiveActivity? _ghost;
  Timer? _ghostTimer;
  Offset? _downAt;
  var _scale = 1.0;
  var _wheel = 0.0;
  Offset _wheelAt = Offset.zero;
  Timer? _wheelTimer;

  IosSimulator get _sim => widget.sim;

  @override
  void initState() {
    super.initState();
    _activity = _sim.control.activity.listen((a) {
      _ghostTimer?.cancel();
      setState(() => _ghost = a);
      _ghostTimer = Timer(const Duration(milliseconds: 1600), () {
        if (mounted) setState(() => _ghost = null);
      });
    });
    _sync();
  }

  @override
  void didUpdateWidget(IosSimulatorView old) {
    super.didUpdateWidget(old);
    if (!identical(old.sim, widget.sim)) _stop();
    _sync();
  }

  @override
  void dispose() {
    _stop();
    unawaited(_activity?.cancel());
    _ghostTimer?.cancel();
    _wheelTimer?.cancel();
    _image?.dispose();
    super.dispose();
  }

  void _stop() {
    unawaited(_frames?.cancel());
    _frames = null;
  }

  void _sync() {
    if (!widget.visible || axePath() == null) {
      _stop();
      return;
    }
    if (_frames != null) return;
    // Its size in points, for mapping touches.
    if (_sim.width <= 0) unawaited(_sim.tree().then((_) => mounted ? setState(() {}) : null, onError: (Object _) {}));
    _frames = _sim.stream().listen(
      _paint,
      onError: (Object e) {
        if (mounted) setState(() => _problem = e is AppError ? e.message : '$e');
      },
      onDone: () => _frames = null,
    );
  }

  Future<void> _paint(Uint8List jpeg) async {
    if (_decoding) return;
    _decoding = true;
    try {
      final codec = await ui.instantiateImageCodec(jpeg);
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
      // A broken frame: the next one.
    } finally {
      _decoding = false;
    }
  }

  Future<void> _install() async {
    setState(() => _installing = 0);
    try {
      await installAxe(onProgress: (p) => mounted ? setState(() => _installing = p) : null);
      if (mounted) setState(() => _problem = null);
    } on Object catch (e) {
      if (mounted) setState(() => _problem = "Couldn't download AXe: $e");
    } finally {
      if (mounted) setState(() => _installing = null);
      _sync();
    }
  }

  void _takeOver() {
    final c = _sim.control;
    if (c.userDriving) return;
    c.take();
    showAdaptiveToast(context, "You're driving: the agent's simulator actions wait until you give it back.");
  }

  void _wheelBy(Offset at, double dy) {
    _takeOver();
    _wheel += dy;
    _wheelAt = at;
    _wheelTimer?.cancel();
    _wheelTimer = Timer(const Duration(milliseconds: 180), () {
      final d = _wheel;
      _wheel = 0;
      unawaited(_sim.userScroll(_wheelAt.dx, _wheelAt.dy, d).catchError((Object _) {}));
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    if (axePath() == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Seeing and driving the simulator needs AXe (MIT, 8 MB), downloaded once from its GitHub release and '
                'checked against a pinned hash. The agent downloads it too on first use.',
                textAlign: TextAlign.center,
                style: theme.type.callout.tint(theme.textMuted),
              ),
              const SizedBox(height: 12),
              if (_installing != null)
                Text('Downloading… ${(_installing! * 100).round()}%', style: theme.type.caption)
              else
                AdaptiveButton(label: 'Install simulator support', onPressed: _install),
              if (_problem != null) ...[
                const SizedBox(height: 8),
                Text(_problem!, style: theme.type.caption.tint(theme.danger)),
              ],
            ],
          ),
        ),
      );
    }
    final image = _image;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppDriverBar(
          control: _sim.control,
          actions: [
            AdaptiveButton(
              label: 'Home',
              emphasis: ButtonEmphasis.secondary,
              onPressed: () => _sim.home().catchError((Object _) => ''),
            ),
          ],
        ),
        Expanded(
          child: image == null
              ? Center(
                  child: Text(
                    _problem ?? 'Starting the simulator view…',
                    textAlign: TextAlign.center,
                    style: theme.type.callout.tint(theme.textMuted),
                  ),
                )
              : LayoutBuilder(
                  builder: (context, box) {
                    // Points: the tree's size, else the picture's proportions.
                    final w = _sim.width > 0 ? _sim.width : image.width.toDouble();
                    final h = _sim.width > 0 ? _sim.height : image.height.toDouble();
                    _scale = ((box.maxWidth - 24) / w).clamp(0.05, 4.0);
                    if (h * _scale > box.maxHeight - 24) _scale = ((box.maxHeight - 24) / h).clamp(0.05, 4.0);
                    final ghost = _ghost;
                    return Center(
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: const Color(0xFF111114),
                          borderRadius: BorderRadius.circular(34),
                          border: Border.all(color: theme.borderStrong),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(28),
                          child: Listener(
                            onPointerDown: (e) => _downAt = e.localPosition,
                            onPointerUp: (e) {
                              final at = _downAt;
                              _downAt = null;
                              if (at == null) return;
                              _takeOver();
                              final from = at / _scale, to = e.localPosition / _scale;
                              final move = (e.localPosition - at).distance;
                              unawaited(
                                (move > 12
                                        ? _sim.drag(from.dx, from.dy, to.dx, to.dy)
                                        : _sim.userTap(from.dx, from.dy).then((_) => ''))
                                    .catchError((Object _) => ''),
                              );
                            },
                            onPointerSignal: (s) {
                              if (s is PointerScrollEvent) {
                                _wheelBy(s.localPosition / _scale, s.scrollDelta.dy / _scale);
                              }
                            },
                            child: SizedBox(
                              width: w * _scale,
                              height: h * _scale,
                              child: Stack(
                                children: [
                                  Positioned.fill(
                                    child: RawImage(
                                      image: image,
                                      fit: BoxFit.fill,
                                      filterQuality: FilterQuality.medium,
                                    ),
                                  ),
                                  if (ghost != null && ghost.x != null && ghost.y != null)
                                    Positioned(
                                      left: ghost.x! * _scale - 14,
                                      top: ghost.y! * _scale - 14,
                                      child: IgnorePointer(
                                        child: Container(
                                          width: 28,
                                          height: 28,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            border: Border.all(color: theme.accent, width: 2),
                                            color: theme.accent.withValues(alpha: 0.18),
                                          ),
                                        ),
                                      ),
                                    ),
                                  if (ghost != null && ghost.caption.isNotEmpty)
                                    Positioned(
                                      left: 0,
                                      right: 0,
                                      bottom: 14,
                                      child: _Caption('Agent: ${ghost.caption}'),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Text(
            'Click to tap, drag to swipe, the wheel scrolls. Type on your keyboard in the Simulator app, or ask the agent.',
            style: theme.type.caption.tint(theme.textMuted),
          ),
        ),
      ],
    );
  }
}
