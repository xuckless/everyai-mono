import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../domain/slide_spec.dart';
import '../ui/renderers/slide_canvas.dart';

/// The smallest text, in canvas units, that reads when a slide is presented.
const _minSize = 14.0;

/// Problems on one slide a picture may not make plain, as short sentences naming the element (empty when none).
/// Text is measured with the same style the canvas draws it in.
List<String> slideFindings(DeckSlide slide, SlideArtBook art) {
  final out = <String>[];
  const canvas = Rect.fromLTWH(0, 0, slideWidth, slideHeight);
  final texts = <TextElement>[];
  for (final e in slide.elements) {
    final box = e.box;
    if (!box.overlaps(canvas)) {
      out.add('${e.label} is entirely off the slide (x ${box.left.round()}, y ${box.top.round()}).');
      continue;
    }
    final past = math.max(
      math.max(canvas.left - box.left, box.right - canvas.right),
      math.max(canvas.top - box.top, box.bottom - canvas.bottom),
    );
    if (past > 4 && !(e is PictureElement && e.fit == PictureFit.cover)) {
      out.add('${e.label} runs ${past.round()} past the slide edge (the canvas is 960×540).');
    }
    switch (e) {
      case PictureElement(:final ref):
        if (art.of(ref) case MissingArt(:final reason)) out.add('${e.label} can\'t be shown: "$ref" is $reason.');
      case TextElement():
        texts.add(e);
        if (e.plainText.trim().isEmpty) continue;
        final need = _textHeight(e);
        final room = e.box.height - 2 * e.padding;
        if (need > room + 2) {
          out.add(
            '${e.label} needs about ${need.round()} of height but its box has ${room.round()}: '
            'it spills out. Shorten it, lower its size, or make the box taller.',
          );
        }
        if (_widestWord(e) > e.box.width - 2 * e.padding + 1) {
          out.add('${e.label} has a word wider than its box; it breaks mid-word or spills sideways.');
        }
        if (e.size < _minSize) {
          out.add('${e.label} is ${e.size.round()} px; under ${_minSize.round()} it is hard to read on a screen.');
        }
        final behind = e.fill ?? _behind(slide, e);
        if (behind != null && _contrast(e.color, behind) < 3) {
          out.add('${e.label} has too little contrast against what is behind it.');
        }
      case TableElement():
        if (e.rows.isEmpty) out.add('${e.label} has no rows.');
        final need = _tableHeight(e);
        if (need > e.box.height + 4) {
          out.add('${e.label} needs about ${need.round()} of height but its box has ${e.box.height.round()}.');
        }
      case ShapeElement():
    }
  }
  for (var i = 0; i < texts.length; i++) {
    for (var j = i + 1; j < texts.length; j++) {
      final a = texts[i], b = texts[j];
      if (a.plainText.trim().isEmpty || b.plainText.trim().isEmpty) continue;
      final overlap = a.box.intersect(b.box);
      if (overlap.width <= 0 || overlap.height <= 0) continue;
      final smaller = math.min(a.box.width * a.box.height, b.box.width * b.box.height);
      if (overlap.width * overlap.height > smaller * 0.1) out.add('${a.label} and ${b.label} overlap.');
    }
  }
  return out;
}

/// How tall [e]'s text is when laid out in its box (the canvas's paragraph spacing included).
double _textHeight(TextElement e) {
  final style = slideTextStyle(e);
  var height = 0.0;
  for (final (i, p) in e.paragraphs.indexed) {
    final width = e.box.width - 2 * e.padding - (p.bullet ? bulletIndent(e) : 0);
    final painter = TextPainter(
      text: TextSpan(style: style, children: [slideSpan(e, p)]),
      textDirection: TextDirection.ltr,
      textAlign: e.align,
    )..layout(maxWidth: math.max(width, 1));
    height += painter.height + (i == 0 ? 0 : e.size * (p.bullet ? 0.35 : 0.2));
    painter.dispose();
  }
  return height;
}

double _widestWord(TextElement e) {
  final style = slideTextStyle(e);
  var widest = 0.0;
  for (final word in e.plainText.split(RegExp(r'\s+'))) {
    if (word.isEmpty) continue;
    final painter = TextPainter(
      text: TextSpan(text: word, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    widest = math.max(widest, painter.width);
    painter.dispose();
  }
  return widest;
}

double _tableHeight(TableElement e) {
  final cols = e.columns;
  if (cols == 0) return 0;
  final style = TextStyle(fontFamily: SlideFont.sans.family, fontSize: e.size, height: 1.3);
  final cellWidth = e.box.width / cols - e.size * 1.2;
  var height = 0.0;
  for (final row in e.rows) {
    var tallest = 0.0;
    for (final cell in row) {
      final painter = TextPainter(
        text: TextSpan(text: cell, style: style),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: math.max(cellWidth, 1));
      tallest = math.max(tallest, painter.height);
      painter.dispose();
    }
    height += tallest + e.size * 0.8 + 1;
  }
  return height;
}

/// The colour behind a text box without its own fill: the topmost filled shape under it, else the slide's
/// background; null over a picture (its colours aren't known).
Color? _behind(DeckSlide slide, TextElement text) {
  final index = slide.elements.indexOf(text);
  for (final e in slide.elements.take(index).toList().reversed) {
    if (!e.box.overlaps(text.box)) continue;
    switch (e) {
      case PictureElement():
        return null;
      case ShapeElement(:final fill?) when fill.a > 0.5 && e.kind != ShapeKind.line && e.kind != ShapeKind.arrow:
        return fill;
      case TextElement(:final fill?) when fill.a > 0.5:
        return fill;
      default:
    }
  }
  return slide.background;
}

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}
