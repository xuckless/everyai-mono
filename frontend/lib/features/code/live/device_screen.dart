// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'app_view.dart';
import 'frames.dart';
import 'live_session.dart';

/// A phone or tablet screen the `app` tool drives with touches: an iOS Simulator (AXe) or an Android device or
/// emulator (adb). Coordinates are the device's own (points on iOS, pixels on Android).
abstract interface class DeviceScreen {
  /// Who drives it, and the agent's actions for the Preview.
  LiveControl get control;
  FrameBook get frames;
  ViewGeometry get geometry;
  double get width;
  double get height;

  /// What it is, for result headers ("iPhone 16", "Pixel 9 Pro XL").
  String get label;

  /// What `install` takes ("a built .app", "an .apk") and `launch` ("bundle id", "package").
  String get installs;
  String get launches;

  Future<List<AppNode>> tree();
  Future<String> snapshot();
  Future<String> tap(String ref);
  Future<String> tapAt(double x, double y);
  Future<String> longPress(String ref);
  Future<String> type(String ref, String text, {bool submit = false});
  Future<String> submit();
  Future<String> scroll(double dy, {String? ref});
  Future<String> drag(double x, double y, double toX, double toY);
  Future<String> back();
  Future<String> home();
  Future<String> install(String path);
  Future<String> launch(String app);

  /// The app's log since the last call (Android: logcat of the app in front), or null where there is none.
  Future<List<String>?> logs();
  Future<void> settle();
  String? changedSince(List<AppNode> before);

  /// A picture of [region] (device coordinates; null: the whole screen) sized for the model, and its frame.
  Future<(List<int>, AgentFrame)> frameShot({ViewRect? region});
}

/// Which session holds each device (one session drives a device at a time).
final class DeviceHolds {
  final _holders = <String, String>{};

  String? holder(String id) => _holders[id];

  /// Lets [session] drive [id]; the holding session's id when another one holds it.
  String? claim(String id, String session) {
    final h = _holders[id];
    if (h != null && h != session) return h;
    _holders[id] = session;
    return null;
  }

  Iterable<String> heldBy(String session) => [
    for (final e in _holders.entries)
      if (e.value == session) e.key,
  ];

  void release(String session) => _holders.removeWhere((_, s) => s == session);
}

/// The smallest placed node under (x, y).
AppNode? hitNode(List<AppNode> nodes, double x, double y) {
  AppNode? best;
  double area(AppNode n) => (n.right! - n.left!) * (n.bottom! - n.top!);
  for (final n in nodes) {
    if (!n.placed || x < n.left! || x > n.right! || y < n.top! || y > n.bottom!) continue;
    if (best == null || area(n) < area(best)) best = n;
  }
  return best;
}

/// "i4 button "Save"" for results.
String nodeText(AppNode n) => '${n.ref.isEmpty ? '' : '${n.ref} '}${n.role}${n.name.isEmpty ? '' : ' "${n.name}"'}';

/// [png] (a screenshot of a screen [screenWidth] wide in device coordinates) cropped to [r] and sized to [size], off
/// the main isolate. A top-level function: a closure would carry its driver (and its sockets) into the isolate.
Future<List<int>> cropForModel(Uint8List png, double screenWidth, ViewRect r, ({int width, int height}) size) =>
    Isolate.run(() => _crop(png, screenWidth, r, size));

List<int> _crop(Uint8List png, double screenWidth, ViewRect r, ({int width, int height}) size) {
  var image = img.decodePng(png);
  if (image == null) return png;
  final scale = image.width / screenWidth;
  image = img.copyCrop(
    image,
    x: (r.left * scale).round(),
    y: (r.top * scale).round(),
    width: (r.width * scale).round(),
    height: (r.height * scale).round(),
  );
  return img.encodePng(img.copyResize(image, width: size.width, height: size.height));
}
