// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// The shape of what a live source shows: its size in the source's own units (CSS pixels for a page, points for a
/// simulator or window), its pixel density and rotation. A change here moves every point, so a frame taken before
/// is no good for coordinates any more.
@immutable
final class ViewGeometry {
  const ViewGeometry(this.width, this.height, {this.scale = 1, this.rotation = 0});
  final int width;
  final int height;
  final double scale;

  /// Quarter turns (simulators, emulators).
  final int rotation;

  @override
  bool operator ==(Object other) =>
      other is ViewGeometry &&
      other.width == width &&
      other.height == height &&
      other.scale == scale &&
      other.rotation == rotation;

  @override
  int get hashCode => Object.hash(width, height, scale, rotation);

  @override
  String toString() => '$width×$height';
}

/// A rectangle in the source's units.
typedef ViewRect = ({double left, double top, double width, double height});

/// A picture the model was given: its id, the size of the image it saw, and the part of the view it shows (the
/// whole view, or a zoomed region). The model's x/y are in the image's pixels.
@immutable
final class AgentFrame {
  const AgentFrame({
    required this.id,
    required this.imageWidth,
    required this.imageHeight,
    required this.region,
    required this.geometry,
    required this.moves,
  });

  final String id;
  final int imageWidth;
  final int imageHeight;
  final ViewRect region;
  final ViewGeometry geometry;

  /// The source's scroll/navigation count when it was taken (see [FrameBook.moved]).
  final int moves;

  bool get zoomed => region.width < geometry.width || region.height < geometry.height;
}

/// How big a picture for the model may be on its long side: larger frames are shrunk (models downscale or refuse
/// big images, and the tokens grow with the area).
const maxAgentImageSide = 1568;

/// The image size a view region of [w]×[h] source units at [scale] device pixels each is sent at: its device
/// pixels, shrunk to [maxSide] on the long side.
({int width, int height}) agentImageSize(double w, double h, {double scale = 1, int maxSide = maxAgentImageSide}) {
  final dw = w * scale, dh = h * scale;
  final shrink = math.min(1.0, maxSide / math.max(dw, dh));
  return (width: math.max(1, (dw * shrink).round()), height: math.max(1, (dh * shrink).round()));
}

/// The frames a session's model has seen of one source, so its coordinates can be checked and mapped back.
final class FrameBook {
  FrameBook({this.prefix = 'f', this.kept = 24});

  final String prefix;
  final int kept;
  final _frames = <String, AgentFrame>{};
  var _next = 1;

  /// Scrolls and navigations so far (bumped by the source's owner).
  int moves = 0;

  /// The latest frame, or null.
  AgentFrame? get latest => _frames.isEmpty ? null : _frames.values.last;

  void moved() => moves++;

  /// Records a picture of [region] (null: the whole view) sent at [imageWidth]×[imageHeight].
  AgentFrame record({
    required int imageWidth,
    required int imageHeight,
    required ViewGeometry geometry,
    ViewRect? region,
  }) {
    final f = AgentFrame(
      id: '${prefix}_${_next++}',
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      region: region ?? (left: 0, top: 0, width: geometry.width.toDouble(), height: geometry.height.toDouble()),
      geometry: geometry,
      moves: moves,
    );
    _frames[f.id] = f;
    while (_frames.length > kept) {
      _frames.remove(_frames.keys.first);
    }
    return f;
  }

  AgentFrame? operator [](String id) => _frames[id];

  /// The point in the source for [x],[y] in frame [frameId] (null: the latest), checked against the view's
  /// geometry [now]: a refusal when it changed (the point would land elsewhere) or the frame is unknown, a warning
  /// when the view scrolled or navigated since.
  FramePoint map(String? frameId, double x, double y, ViewGeometry now) {
    final f = frameId == null || frameId.isEmpty ? latest : _frames[frameId];
    if (f == null) {
      return FramePoint.refused(
        frameId == null || frameId.isEmpty
            ? 'No screenshot taken yet: take one, then click at a point in it.'
            : 'There is no frame $frameId (only the last $kept are kept): take a new screenshot.',
      );
    }
    if (f.geometry != now) {
      return FramePoint.refused(
        'The view is now ${now.width}×${now.height}${now.rotation != f.geometry.rotation ? ' and rotated' : ''} '
        '(frame ${f.id} was ${f.geometry.width}×${f.geometry.height}): take a new screenshot.',
      );
    }
    if (x < 0 || y < 0 || x > f.imageWidth || y > f.imageHeight) {
      return FramePoint.refused('($x, $y) is outside frame ${f.id}, which is ${f.imageWidth}×${f.imageHeight}.');
    }
    final sx = f.region.width / f.imageWidth, sy = f.region.height / f.imageHeight;
    return FramePoint(
      f.region.left + x * sx,
      f.region.top + y * sy,
      warning: f.moves != moves
          ? 'The view scrolled or changed page since frame ${f.id}, so this point may not be what you saw there.'
          : null,
      frame: f,
    );
  }
}

/// Where a model's point lands in the source, or why it can't be used.
@immutable
final class FramePoint {
  const FramePoint(this.x, this.y, {this.warning, this.frame}) : refusal = null;
  const FramePoint.refused(String this.refusal) : x = 0, y = 0, warning = null, frame = null;

  final double x;
  final double y;
  final String? refusal;
  final String? warning;
  final AgentFrame? frame;
}
