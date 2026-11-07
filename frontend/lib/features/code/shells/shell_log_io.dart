// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A shell's raw output (colours and all) appended to [path]. Past [cap]
/// bytes the file moves to `<path>.1` (replacing the older one) and a new one
/// starts, so a log holds between [cap] and twice that.
final class ShellLog {
  ShellLog(this.path, {this.cap = 10 * 1024 * 1024}) {
    try {
      File(path).parent.createSync(recursive: true);
      _file = File(path).openSync(mode: FileMode.append);
      _size = _file!.lengthSync();
    } on Object {
      _file = null;
    }
  }

  final String path;
  final int cap;
  RandomAccessFile? _file;
  int _size = 0;

  void add(List<int> bytes) {
    final f = _file;
    if (f == null || bytes.isEmpty) return;
    try {
      f.writeFromSync(bytes);
      _size += bytes.length;
      if (_size > cap) _roll();
    } on Object {
      // A full disk or a removed session folder: the log stops, the shell doesn't.
      close();
    }
  }

  void addText(String s) => add(utf8.encode(s));

  void _roll() {
    _file?.closeSync();
    final old = File('$path.1');
    if (old.existsSync()) old.deleteSync();
    File(path).renameSync(old.path);
    _file = File(path).openSync(mode: FileMode.append);
    _size = 0;
  }

  void close() {
    try {
      _file?.closeSync();
    } on Object {
      // Closed already.
    }
    _file = null;
  }
}

Future<Uint8List> readShellLog(String path) async {
  final b = BytesBuilder(copy: false);
  for (final p in ['$path.1', path]) {
    final f = File(p);
    if (await f.exists()) b.add(await f.readAsBytes());
  }
  return b.takeBytes();
}

Uint8List readShellLogSync(String path) {
  final b = BytesBuilder(copy: false);
  for (final p in ['$path.1', path]) {
    final f = File(p);
    if (f.existsSync()) b.add(f.readAsBytesSync());
  }
  return b.takeBytes();
}
