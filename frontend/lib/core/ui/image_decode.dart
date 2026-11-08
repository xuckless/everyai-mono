// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:typed_data';
import 'dart:ui' as ui;

/// The first frame of an encoded picture (JPEG, PNG). Its codec is disposed at once: a live view decodes up to 30
/// pictures a second, and codecs left to the garbage collector held their native memory (60 MB per 1,500 frames in
/// a probe). The caller owns the image and disposes it.
Future<ui.Image> decodeFirstFrame(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}
