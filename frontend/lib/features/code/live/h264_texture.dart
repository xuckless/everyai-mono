// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// An H.264 stream decoded by the platform into a Flutter texture (`Texture(textureId: id)`): VideoToolbox on macOS
/// (`macos/Runner/MainFlutterWindow.swift`, channel `everyai/h264`). Elsewhere [create] returns null and callers
/// fall back to still pictures.
final class H264Texture {
  H264Texture._(this.id);

  static const _channel = MethodChannel('everyai/h264');
  static final _byId = <int, H264Texture>{};
  static var _listening = false;

  final int id;

  /// The decoded picture's size, once known.
  final size = ValueNotifier<Size?>(null);
  var _closed = false;

  /// A decoder, or null where the platform has none.
  static Future<H264Texture?> create() async {
    if (kIsWeb || !Platform.isMacOS) return null;
    if (!_listening) {
      _listening = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method != 'size') return;
        final args = (call.arguments as Map).cast<String, Object?>();
        _byId[(args['id']! as num).toInt()]?.size.value = Size(
          (args['width']! as num).toDouble(),
          (args['height']! as num).toDouble(),
        );
      });
    }
    try {
      final id = await _channel.invokeMethod<int>('create');
      if (id == null) return null;
      return _byId[id] = H264Texture._(id);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Decodes one Annex-B packet ([config]: the parameter sets).
  Future<void> feed(Uint8List data, {bool config = false}) async {
    if (_closed) return;
    await _channel.invokeMethod<void>('decode', {'id': id, 'data': data, 'config': config});
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _byId.remove(id);
    size.dispose();
    await _channel.invokeMethod<void>('dispose', {'id': id});
  }
}
