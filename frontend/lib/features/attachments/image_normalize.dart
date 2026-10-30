import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// The longest edge a chat photo keeps. Vision models downscale past about this anyway, so larger pixels only
/// cost upload size, tokens' worth of nothing, and the 32 MiB request limit (the history is resent every turn).
const maxImageEdge = 2048;

/// Photos at or under this size are sent as they are.
const keepImageBytes = 1024 * 1024;

/// [bytes] shrunk to at most [maxImageEdge] on the long side and re-encoded (JPEG, or PNG when it has
/// transparency), when that makes a big picture smaller. Returns null to keep the original: small files, GIFs
/// (animation), formats it can't decode, and results that did not get smaller.
Future<({Uint8List bytes, String extension})?> normalizeImage(Uint8List bytes, String extension) {
  final ext = extension.toLowerCase();
  if (bytes.length <= keepImageBytes || ext == 'gif') return Future.value();
  return compute(_normalize, (bytes, ext));
}

({Uint8List bytes, String extension})? _normalize((Uint8List, String) args) {
  final (bytes, _) = args;
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  var image = decoded;
  final longest = image.width > image.height ? image.width : image.height;
  if (longest > maxImageEdge) {
    image = img.copyResize(
      image,
      width: image.width >= image.height ? maxImageEdge : null,
      height: image.height > image.width ? maxImageEdge : null,
      interpolation: img.Interpolation.average,
    );
  }
  final alpha = image.hasAlpha && _usesAlpha(image);
  final out = alpha ? img.encodePng(image) : img.encodeJpg(image, quality: 85);
  if (out.length >= bytes.length) return null;
  return (bytes: Uint8List.fromList(out), extension: alpha ? 'png' : 'jpg');
}

bool _usesAlpha(img.Image image) {
  for (final p in image) {
    if (p.a < p.maxChannelValue) return true;
  }
  return false;
}
