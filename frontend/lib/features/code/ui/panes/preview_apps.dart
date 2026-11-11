// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../../core/motion/motion.dart';
import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../live/adb_io.dart';
import '../../live/android_device_io.dart';
import '../../live/app_endpoints.dart';
import '../../live/app_sources.dart';
import '../../live/app_view.dart';
import '../../live/axe_install.dart';
import '../../live/desktop_window_io.dart';
import '../../live/flutter_app_io.dart';
import '../../live/h264_texture.dart';
import '../../live/ios_simulator_io.dart';
import '../../live/live_session.dart';
import '../../live/react_native_io.dart';
import '../../live/scrcpy_io.dart';
import '../../../../core/ui/image_decode.dart';

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

/// The one bar above every live view: who has it, and the only control that changes that. The view is watch-only
/// until Take control; [noun] is what the view shows ("page", "app", "device", "window").
class LiveDriverBar extends StatelessWidget {
  const LiveDriverBar({super.key, required this.control, this.noun = 'page', this.actions});

  final LiveControl control;
  final String noun;
  final List<Widget> Function(bool mayAct)? actions;

  /// The bar's words per phase.
  static String textFor(LiveControlPhase phase, String noun) => switch (phase) {
    LiveControlPhase.agentDriving => 'Agent is using this $noun',
    LiveControlPhase.userDriving => 'You have control',
    LiveControlPhase.agentWaiting => 'Agent is waiting · you have control',
  };

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return ListenableBuilder(
      listenable: control,
      builder: (context, _) {
        final phase = control.phase;
        final user = phase.userMayAct;
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
              Expanded(child: Text(textFor(phase, noun), style: theme.type.caption.tint(theme.text))),
              ...?actions?.call(user),
              const SizedBox(width: 4),
              ValueListenableBuilder<int>(
                valueListenable: control.takeHints,
                builder: (context, hints, button) =>
                    SuccessPulse(trigger: hints, radius: 8, color: theme.accent, child: button!),
                child: AdaptiveButton(
                  label: user ? 'Give back' : 'Take control',
                  emphasis: ButtonEmphasis.secondary,
                  onPressed: user ? control.giveBack : control.take,
                ),
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
      if (!mounted) return;
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
      final frame = (image: await decodeFirstFrame(Uint8List.fromList(png)));
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

  /// Input reaches the source only while the user has control; else Take control pulses.
  bool _mayAct() => _app.control.mayAct();

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
        LiveDriverBar(
          noun: 'app',
          control: _app.control,
          actions: (may) => [
            AdaptiveButton(
              label: 'Hot reload',
              emphasis: ButtonEmphasis.secondary,
              onPressed: _reloading || !may ? null : () => _reload(false),
            ),
            const SizedBox(width: 4),
            AdaptiveButton(
              label: 'Restart',
              emphasis: ButtonEmphasis.secondary,
              onPressed: _reloading || !may ? null : () => _reload(true),
            ),
          ],
        ),
        // The app stopped answering: the last picture stays, with why.
        if (image != null && _problem != null) _StreamNotice(message: _problem!),
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
                          if (!_mayAct()) return;
                          final p = e.localPosition / _scale;
                          unawaited(_app.userTap(p.dx, p.dy).then((_) => _refresh(), onError: (Object _) {}));
                        },
                        onPointerSignal: (s) {
                          if (s is! PointerScrollEvent) return;
                          if (!_mayAct()) return;
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
        LiveDriverBar(
          noun: 'app',
          control: widget.app.control,
          actions: (may) => [
            AdaptiveButton(
              label: 'Reload',
              emphasis: ButtonEmphasis.secondary,
              onPressed: !may ? null : () => widget.app.reload().then((_) => _refresh(), onError: (Object _) {}),
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
            "The app's element list, as the agent reads it.",
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
  var _stream = _PictureStream.off;
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
      if (!mounted) return;
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
    _stream = _PictureStream.off;
  }

  void _retry() {
    setState(() {
      _stream = _PictureStream.off;
      _problem = null;
    });
    _sync();
  }

  void _sync() {
    if (!widget.visible || axePath() == null) {
      _stop();
      return;
    }
    // Ended streams wait for Retry instead of respawning on every rebuild.
    if (_stream != _PictureStream.off) return;
    _stream = _PictureStream.live;
    // Its size in points, for mapping touches.
    if (_sim.width <= 0) unawaited(_sim.tree().then((_) => mounted ? setState(() {}) : null, onError: (Object _) {}));
    _frames = _sim.stream().listen(
      _paint,
      onError: (Object e) {
        if (mounted) setState(() => _problem = e is AppError ? e.message : '$e');
      },
      onDone: () {
        if (!mounted || _stream != _PictureStream.live) return;
        setState(() {
          _frames = null;
          _stream = _PictureStream.ended;
        });
      },
    );
  }

  Future<void> _paint(Uint8List jpeg) async {
    if (_decoding) return;
    _decoding = true;
    try {
      final frame = (image: await decodeFirstFrame(jpeg));
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

  /// Input reaches the source only while the user has control; else Take control pulses.
  bool _mayAct() => _sim.control.mayAct();

  void _wheelBy(Offset at, double dy) {
    if (!_mayAct()) return;
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
                'The simulator view needs AXe (8 MB, downloaded once and checked).',
                textAlign: TextAlign.center,
                style: theme.type.callout.tint(theme.textMuted),
              ),
              const SizedBox(height: 12),
              if (_installing != null)
                Text('Downloading… ${(_installing! * 100).round()}%', style: theme.type.caption.tint(theme.textMuted))
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
        LiveDriverBar(
          noun: 'device',
          control: _sim.control,
          actions: (may) => [
            AdaptiveButton(
              label: 'Home',
              emphasis: ButtonEmphasis.secondary,
              onPressed: !may ? null : () => _sim.home().catchError((Object _) => ''),
            ),
          ],
        ),
        if (_stream == _PictureStream.ended || (image != null && _problem != null))
          _StreamNotice(
            message: _stream == _PictureStream.ended ? 'The live view stopped.' : _problem!,
            onRetry: _stream == _PictureStream.ended ? _retry : null,
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
                              if (!_mayAct()) return;
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
            'Click to tap, drag to swipe, scroll with the wheel. Type in the Simulator app.',
            style: theme.type.caption.tint(theme.textMuted),
          ),
        ),
      ],
    );
  }
}

/// An Android device's live screen: scrcpy's H.264 stream decoded into a texture (macOS), else screenshots every
/// second. Touches, drags, the wheel and the keyboard go to the device through scrcpy's control socket (adb input
/// when scrcpy isn't there); Back, Home and Recents buttons; the agent's ghost on top.
class AndroidDeviceView extends StatefulWidget {
  const AndroidDeviceView({super.key, required this.device, required this.visible});

  final AndroidDevice device;
  final bool visible;

  @override
  State<AndroidDeviceView> createState() => _AndroidDeviceViewState();
}

/// What the device view runs:
///
/// ```text
///  idle ──visible──► starting ──decoder + scrcpy──► streaming ──stream ended──► polling
///   ▲                   └──otherwise───────────────────────────────────────────► polling
///   └──────────── hidden, another device, or disposed (from any state) ───────────┘
/// ```
/// [_Starting] carries a generation: a start that finishes after the view moved on gives its pieces back.
sealed class _DeviceFeed {
  const _DeviceFeed();
}

final class _FeedIdle extends _DeviceFeed {
  const _FeedIdle();
}

final class _FeedStarting extends _DeviceFeed {
  const _FeedStarting(this.gen);
  final int gen;
}

final class _FeedStreaming extends _DeviceFeed {
  _FeedStreaming(this.scrcpy, this.texture, this.packets);
  final ScrcpyConnection scrcpy;
  final H264Texture texture;
  final StreamSubscription<VideoPacket> packets;
}

/// Screenshots each second; touches still go through [scrcpy] when it connected.
final class _FeedPolling extends _DeviceFeed {
  _FeedPolling(this.scrcpy, this.timer);
  final ScrcpyConnection? scrcpy;
  final Timer timer;
}

class _AndroidDeviceViewState extends State<AndroidDeviceView> {
  _DeviceFeed _feed = const _FeedIdle();
  var _gen = 0;
  StreamSubscription<LiveActivity>? _activity;
  ui.Image? _still;
  String? _problem;
  LiveActivity? _ghost;
  Timer? _ghostTimer;
  final _focus = FocusNode(debugLabel: 'android-device');
  Offset? _downAt;
  var _scale = 1.0;
  var _pollBusy = false;

  AndroidDevice get _device => widget.device;
  ScrcpyConnection? get _scrcpy => switch (_feed) {
    _FeedStreaming(:final scrcpy) => scrcpy,
    _FeedPolling(:final scrcpy) => scrcpy,
    _ => null,
  };
  H264Texture? get _texture => switch (_feed) {
    _FeedStreaming(:final texture) => texture,
    _ => null,
  };

  @override
  void initState() {
    super.initState();
    _listenActivity();
    _sync();
  }

  void _listenActivity() {
    unawaited(_activity?.cancel());
    _activity = _device.control.activity.listen((a) {
      if (!mounted) return;
      _ghostTimer?.cancel();
      setState(() => _ghost = a);
      _ghostTimer = Timer(const Duration(milliseconds: 1600), () {
        if (mounted) setState(() => _ghost = null);
      });
    });
  }

  @override
  void didUpdateWidget(AndroidDeviceView old) {
    super.didUpdateWidget(old);
    if (!identical(old.device, widget.device)) {
      _stop();
      _listenActivity();
      _still?.dispose();
      _still = null;
      _problem = null;
    }
    _sync();
  }

  @override
  void dispose() {
    _stop();
    unawaited(_activity?.cancel());
    _ghostTimer?.cancel();
    _focus.dispose();
    _still?.dispose();
    super.dispose();
  }

  /// Back to idle at once (so the next [_sync] may start again); the old feed's pieces close in the background.
  void _stop() {
    final was = _feed;
    _gen++;
    _feed = const _FeedIdle();
    switch (was) {
      case _FeedStreaming(:final packets, :final texture):
        unawaited(packets.cancel().whenComplete(texture.dispose));
      case _FeedPolling(:final timer):
        timer.cancel();
      case _FeedIdle() || _FeedStarting():
        break;
    }
  }

  void _sync() {
    if (!widget.visible) {
      if (_feed is! _FeedIdle) _stop();
      return;
    }
    if (_feed is _FeedIdle) unawaited(_start());
  }

  Future<void> _start() async {
    final gen = ++_gen;
    _feed = _FeedStarting(gen);
    bool current() => mounted && gen == _gen;
    if (_device.width <= 0) await _device.tree().catchError((Object _) => const <AppNode>[]);
    final texture = await H264Texture.create();
    ScrcpyConnection? c;
    try {
      c = await _device.scrcpy();
    } on Object catch (e) {
      if (current()) setState(() => _problem = e is AppError ? e.message : '$e');
    }
    if (!current()) {
      await texture?.dispose();
      return;
    }
    if (texture != null && c != null && !c.closed) {
      final scrcpy = c;
      texture.size.addListener(() => mounted ? setState(() {}) : null);
      // A decoder joining a running stream starts from the parameter sets and the last key frame.
      if (scrcpy.config case final p?) unawaited(texture.feed(p.data, config: true));
      if (scrcpy.keyFrame case final p?) unawaited(texture.feed(p.data));
      // Cancelled by _stop, which owns the feed.
      // ignore: cancel_subscriptions
      final packets = scrcpy.packets.listen(
        (p) => unawaited(texture.feed(p.data, config: p.config)),
        // The device rebooted, was unplugged, or its server died: fall back to screenshots and say so.
        onDone: () {
          if (!current() || _feed is! _FeedStreaming) return;
          _gen++;
          unawaited(texture.dispose());
          setState(() {
            _problem = 'The live view stopped; showing a picture each second.';
            _poll(null);
          });
        },
      );
      setState(() {
        _feed = _FeedStreaming(scrcpy, texture, packets);
        _problem = null;
      });
    } else {
      await texture?.dispose();
      setState(() => _poll(c));
    }
  }

  void _poll(ScrcpyConnection? c) {
    _feed = _FeedPolling(c, Timer.periodic(const Duration(seconds: 1), (_) => _pollOnce()));
    unawaited(_pollOnce());
  }

  Future<void> _pollOnce() async {
    if (_pollBusy || !mounted) return;
    _pollBusy = true;
    final gen = _gen;
    try {
      final png = await _device.screenshot();
      final frame = (image: await decodeFirstFrame(png));
      // Hidden or another device meanwhile: this picture is stale.
      if (!mounted || gen != _gen) {
        frame.image.dispose();
        return;
      }
      setState(() {
        _still?.dispose();
        _still = frame.image;
      });
    } on Object catch (e) {
      if (mounted && gen == _gen) setState(() => _problem = e is AppError ? e.message : '$e');
    } finally {
      _pollBusy = false;
    }
  }

  /// Input reaches the source only while the user has control; else Take control pulses.
  bool _mayAct() => _device.control.mayAct();

  /// A point in the view as the scrcpy video's coordinates, and as the device's pixels.
  Offset _video(Offset local) => local / _scale;
  Offset _pixels(Offset local) {
    final c = _scrcpy;
    final v = _video(local);
    if (c == null || c.width == 0 || _device.width <= 0) return v;
    return Offset(v.dx * _device.width / c.width, v.dy * _device.height / c.height);
  }

  void _key(int code) {
    if (!_mayAct()) return;
    final c = _scrcpy;
    if (c != null && !c.closed) {
      c.key(code);
    } else {
      unawaited(AndroidSdk.shell(_device.serial, ['input', 'keyevent', '$code']).catchError((Object _) => ''));
    }
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final c = _scrcpy;
    if (c == null || c.closed) return KeyEventResult.ignored;
    final code = switch (e.logicalKey) {
      LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter => 66,
      LogicalKeyboardKey.backspace => 67,
      LogicalKeyboardKey.delete => 112,
      LogicalKeyboardKey.tab => 61,
      LogicalKeyboardKey.arrowUp => 19,
      LogicalKeyboardKey.arrowDown => 20,
      LogicalKeyboardKey.arrowLeft => 21,
      LogicalKeyboardKey.arrowRight => 22,
      LogicalKeyboardKey.escape => 4,
      _ => null,
    };
    if (!_mayAct()) return KeyEventResult.handled;
    if (code != null) {
      c.key(code);
      return KeyEventResult.handled;
    }
    final ch = e.character;
    if (ch == null || ch.isEmpty || ch.codeUnitAt(0) < 0x20) return KeyEventResult.ignored;
    if (RegExp(r'^[\x20-\x7e]$').hasMatch(ch)) {
      c.text(ch);
    } else {
      c.paste(ch);
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final texture = _texture;
    final still = _still;
    final videoSize = texture?.size.value;
    final c = _scrcpy;
    // The picture's own size: the video's (scrcpy scales the screen), else the screenshot's.
    final w = videoSize?.width ?? (c != null && c.width > 0 ? c.width.toDouble() : still?.width.toDouble());
    final h = videoSize?.height ?? (c != null && c.height > 0 ? c.height.toDouble() : still?.height.toDouble());
    Widget picture;
    if (w == null || h == null || (texture == null && still == null)) {
      picture = Center(
        child: Text(
          _problem ?? 'Starting the device view…',
          textAlign: TextAlign.center,
          style: theme.type.callout.tint(theme.textMuted),
        ),
      );
    } else {
      picture = LayoutBuilder(
        builder: (context, box) {
          _scale = ((box.maxWidth - 24) / w).clamp(0.05, 4.0);
          if (h * _scale > box.maxHeight - 24) _scale = ((box.maxHeight - 24) / h).clamp(0.05, 4.0);
          // The ghost's place: device pixels to the view.
          final ghost = _ghost;
          final perPixel = _device.width > 0 ? w * _scale / _device.width : _scale;
          return Center(
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFF111114),
                borderRadius: BorderRadius.circular(30),
                border: Border.all(color: theme.borderStrong),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: Focus(
                  focusNode: _focus,
                  onKeyEvent: _onKey,
                  child: Listener(
                    onPointerDown: (e) {
                      _focus.requestFocus();
                      if (!_mayAct()) return;
                      _downAt = e.localPosition;
                      final v = _video(e.localPosition);
                      if (c != null && !c.closed) c.touch(0, v.dx, v.dy);
                    },
                    onPointerMove: (e) {
                      if (_downAt == null) return;
                      final v = _video(e.localPosition);
                      if (c != null && !c.closed) c.touch(2, v.dx, v.dy);
                    },
                    onPointerUp: (e) {
                      final at = _downAt;
                      _downAt = null;
                      if (at == null) return;
                      final v = _video(e.localPosition);
                      if (c != null && !c.closed) {
                        c.touch(1, v.dx, v.dy);
                      } else {
                        final from = _pixels(at), to = _pixels(e.localPosition);
                        unawaited(
                          ((e.localPosition - at).distance > 12
                                  ? _device.drag(from.dx, from.dy, to.dx, to.dy)
                                  : _device.userTap(from.dx, from.dy).then((_) => ''))
                              .catchError((Object _) => ''),
                        );
                      }
                    },
                    onPointerSignal: (s) {
                      if (s is PointerScrollEvent && c != null && !c.closed) {
                        if (!_mayAct()) return;
                        final v = _video(s.localPosition);
                        c.scroll(v.dx, v.dy, -s.scrollDelta.dy / 40);
                      }
                    },
                    child: SizedBox(
                      width: w * _scale,
                      height: h * _scale,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: texture != null
                                ? Texture(textureId: texture.id, filterQuality: FilterQuality.medium)
                                : RawImage(image: still, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
                          ),
                          if (ghost != null && ghost.x != null && ghost.y != null)
                            Positioned(
                              left: ghost.x! * perPixel - 14,
                              top: ghost.y! * perPixel - 14,
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
                            Positioned(left: 0, right: 0, bottom: 14, child: _Caption('Agent: ${ghost.caption}')),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LiveDriverBar(
          noun: 'device',
          control: _device.control,
          actions: (may) => [
            AdaptiveButton(label: 'Back', emphasis: ButtonEmphasis.secondary, onPressed: may ? () => _key(4) : null),
            AdaptiveButton(label: 'Home', emphasis: ButtonEmphasis.secondary, onPressed: may ? () => _key(3) : null),
            AdaptiveButton(
              label: 'Recents',
              emphasis: ButtonEmphasis.secondary,
              onPressed: may ? () => _key(187) : null,
            ),
          ],
        ),
        Expanded(child: picture),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Text(
            c == null
                ? "Click to tap, drag to swipe. Screenshots each second (scrcpy isn't running)."
                : 'Click, drag and scroll as on the device. Click it, then type.',
            style: theme.type.caption.tint(theme.textMuted),
          ),
        ),
      ],
    );
  }
}

/// A desktop app's window, live (ScreenCaptureKit through the window helper). A click is pressed through
/// accessibility when the element there can be pressed, else sent to the app's process; Bring to front raises the
/// real window for anything else.
class DesktopWindowView extends StatefulWidget {
  const DesktopWindowView({super.key, required this.window, required this.visible});

  final DesktopWindow window;
  final bool visible;

  @override
  State<DesktopWindowView> createState() => _DesktopWindowViewState();
}

class _DesktopWindowViewState extends State<DesktopWindowView> {
  ui.Image? _image;
  StreamSubscription<Uint8List>? _frames;
  var _stream = _PictureStream.off;
  StreamSubscription<LiveActivity>? _activity;
  var _decoding = false;
  String? _problem;
  LiveActivity? _ghost;
  Timer? _ghostTimer;
  var _scale = 1.0;

  DesktopWindow get _window => widget.window;

  @override
  void initState() {
    super.initState();
    _activity = _window.control.activity.listen((a) {
      if (!mounted) return;
      _ghostTimer?.cancel();
      setState(() => _ghost = a);
      _ghostTimer = Timer(const Duration(milliseconds: 1600), () {
        if (mounted) setState(() => _ghost = null);
      });
    });
    _sync();
  }

  @override
  void didUpdateWidget(DesktopWindowView old) {
    super.didUpdateWidget(old);
    if (!identical(old.window, widget.window)) _stop();
    _sync();
  }

  @override
  void dispose() {
    _stop();
    unawaited(_activity?.cancel());
    _ghostTimer?.cancel();
    _image?.dispose();
    super.dispose();
  }

  void _stop() {
    unawaited(_frames?.cancel());
    _frames = null;
    _stream = _PictureStream.off;
  }

  void _retry() {
    setState(() {
      _stream = _PictureStream.off;
      _problem = null;
    });
    _sync();
  }

  void _sync() {
    if (!widget.visible) {
      _stop();
      return;
    }
    // Ended streams wait for Retry instead of respawning on every rebuild.
    if (_stream != _PictureStream.off) return;
    _stream = _PictureStream.live;
    _frames = _window.stream().listen(
      _paint,
      onError: (Object e) {
        if (mounted) setState(() => _problem = e is AppError ? e.message : '$e');
      },
      onDone: () {
        if (!mounted || _stream != _PictureStream.live) return;
        setState(() {
          _frames = null;
          _stream = _PictureStream.ended;
        });
      },
    );
  }

  Future<void> _paint(Uint8List jpeg) async {
    if (_decoding) return;
    _decoding = true;
    try {
      final frame = (image: await decodeFirstFrame(jpeg));
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

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final image = _image;
    final ghost = _ghost;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LiveDriverBar(
          noun: 'window',
          control: _window.control,
          actions: (may) => [
            AdaptiveButton(
              label: 'Bring to front',
              emphasis: ButtonEmphasis.secondary,
              onPressed: !may ? null : () => _window.raise().catchError((Object _) {}),
            ),
          ],
        ),
        if (_stream == _PictureStream.ended || (image != null && _problem != null))
          _StreamNotice(
            message: _stream == _PictureStream.ended ? 'The live view stopped.' : _problem!,
            onRetry: _stream == _PictureStream.ended ? _retry : null,
          ),
        Expanded(
          child: image == null
              ? Center(
                  child: Text(
                    _problem ?? 'Starting the window view…',
                    textAlign: TextAlign.center,
                    style: theme.type.callout.tint(theme.textMuted),
                  ),
                )
              : LayoutBuilder(
                  builder: (context, box) {
                    // The window's size in points (as the agent sees it), else the picture's.
                    final w = _window.width > 0 ? _window.width : image.width.toDouble();
                    final h = _window.width > 0 ? _window.height : image.height.toDouble();
                    _scale = ((box.maxWidth - 16) / w).clamp(0.05, 2.0);
                    if (h * _scale > box.maxHeight - 16) _scale = ((box.maxHeight - 16) / h).clamp(0.05, 2.0);
                    return Center(
                      child: Listener(
                        onPointerUp: (e) {
                          if (!_window.control.mayAct()) return;
                          final p = e.localPosition / _scale;
                          unawaited(_window.userClick(p.dx, p.dy).catchError((Object _) => false));
                        },
                        child: SizedBox(
                          width: w * _scale,
                          height: h * _scale,
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: RawImage(image: image, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
                              ),
                              if (ghost != null && ghost.x != null && ghost.y != null)
                                Positioned(
                                  left: ghost.x! * _scale - 12,
                                  top: ghost.y! * _scale - 12,
                                  child: IgnorePointer(
                                    child: Container(
                                      width: 24,
                                      height: 24,
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
            'Clicks press in place where they can, else bring the window forward. Bring it forward to type.',
            style: theme.type.caption.tint(theme.textMuted),
          ),
        ),
      ],
    );
  }
}

/// A picture stream (iOS Simulator, desktop window):
///
/// ```text
///  off ──shown──► live ──stream ended──► ended ──Retry──► live
///   ▲───────── hidden, or disposed (from any state) ────────┘
/// ```
enum _PictureStream { off, live, ended }

/// A line above a picture that still shows: the stream ended (with Retry), or the last error.
class _StreamNotice extends StatelessWidget {
  const _StreamNotice({required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
      child: Row(
        children: [
          Expanded(child: Text(message, style: theme.type.caption.tint(theme.textMuted), maxLines: 2)),
          if (onRetry case final retry?)
            AdaptiveButton(label: 'Retry', emphasis: ButtonEmphasis.secondary, onPressed: retry),
        ],
      ),
    );
  }
}
