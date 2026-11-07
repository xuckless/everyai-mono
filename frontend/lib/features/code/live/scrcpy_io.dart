// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../git/git_service.dart';
import 'adb_io.dart';
import 'app_view.dart';
import 'scrcpy_pin.dart';
import 'verified_download_io.dart';

/// One encoded video packet from the device (Annex-B H.264); [config] holds the parameter sets.
typedef VideoPacket = ({Uint8List data, bool config, bool key});

Future<String>? _fetching;

/// The pinned scrcpy server file, downloaded once into the app's data folder and checked against its SHA-256.
Future<String> scrcpyServer() => _fetching ??= () async {
  if (Platform.environment['EVERYAI_SCRCPY_SERVER'] case final set? when File(set).existsSync()) return set;
  final dir = '${await GitService.dataDir()}/tools/scrcpy-$scrcpyVersion';
  final file = File('$dir/scrcpy-server');
  if (!file.existsSync()) {
    final part = File('${file.path}.part');
    await downloadVerified(Uri.parse(scrcpyServerUrl), scrcpyServerSha256, part);
    part.renameSync(file.path);
  }
  return file.path;
}().whenComplete(() => _fetching = null);

/// A scrcpy session with one Android device: the server pushed and started over adb, a forwarded port, the video
/// socket (when [video]) and the control socket. Touches, keys and text go through [touch], [key], [text] and
/// [paste]; [packets] carries the encoded screen, [sizes] the picture's size (it changes on rotation).
final class ScrcpyConnection {
  ScrcpyConnection._(this.serial, this._server, this._port, this._name, this._video, this._control);

  final String serial;
  final Process _server;
  final int _port;
  final String _name;
  final Socket? _video;
  final Socket _control;
  final _packets = StreamController<VideoPacket>.broadcast();
  final _sizes = StreamController<(int, int)>.broadcast();
  var _closed = false;

  /// The video's size (the device's screen scaled to the session's max size), as of the last session packet.
  var width = 0, height = 0;

  Stream<VideoPacket> get packets => _packets.stream;
  Stream<(int, int)> get sizes => _sizes.stream;
  bool get closed => _closed;

  /// The last config packet, so a decoder that joins late can start.
  VideoPacket? config;

  /// The last key frame (with [config], a picture to start from).
  VideoPacket? keyFrame;

  /// Starts the server on [serial] and connects. [maxSize] caps the video's longer side.
  static Future<ScrcpyConnection> open(String serial, {bool video = true, int maxSize = 1280}) async {
    final server = await scrcpyServer();
    const remote = '/data/local/tmp/everyai-scrcpy.jar';
    // The server deletes its file when it ends, so it goes up every time.
    await AndroidSdk.run(['push', server, remote], serial: serial);
    final scid = Random.secure().nextInt(0x7fffffff).toRadixString(16).padLeft(8, '0');
    final name = 'scrcpy_$scid';
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    await AndroidSdk.run(['forward', 'tcp:$port', 'localabstract:$name'], serial: serial);
    final args = [
      'CLASSPATH=$remote',
      'app_process',
      '/',
      'com.genymobile.scrcpy.Server',
      scrcpyVersion,
      'scid=$scid',
      'tunnel_forward=true',
      'audio=false',
      'video=$video',
      'control=true',
      'max_size=$maxSize',
      'video_codec=h264',
      'clipboard_autosync=false',
      'log_level=warn',
    ];
    final p = await Process.start(AndroidSdk.adb!, ['-s', serial, 'shell', args.join(' ')]);
    final log = StringBuffer();
    p.stdout.transform(utf8.decoder).listen(log.write);
    p.stderr.transform(utf8.decoder).listen(log.write);
    Future<void> undo() async {
      p.kill();
      await AndroidSdk.run(['forward', '--remove', 'tcp:$port'], serial: serial).catchError((Object _) => '');
    }

    try {
      // The forward accepts at once; the first socket's dummy byte says the server is there.
      final (first, reader) = await _connectFirst(port, p);
      // Closed by close().
      // ignore: close_sinks
      final second = video ? await Socket.connect(InternetAddress.loopbackIPv4, port) : null;
      final c = ScrcpyConnection._(serial, p, port, name, video ? first : null, second ?? first);
      // Device meta (64 bytes of name) on the first socket.
      await reader.take(64);
      if (video) {
        final codec = await reader.take(4);
        if (codec[0] == 0 && codec[1] == 0 && codec[2] == 0) {
          throw const AppError("The device couldn't start a video encoder.");
        }
        unawaited(c._readVideo(reader));
      } else {
        unawaited(reader.done.whenComplete(c.close));
      }
      unawaited(p.exitCode.then((_) => c.close()));
      return c;
    } on Object catch (e) {
      await undo();
      final said = '$log'.trim();
      throw AppError(
        "Couldn't start scrcpy on $serial: ${e is AppError ? e.message : e}${said.isEmpty ? '' : ' ($said)'}",
      );
    }
  }

  static Future<(Socket, _Reader)> _connectFirst(int port, Process server) async {
    final until = DateTime.now().add(const Duration(seconds: 10));
    var exited = false;
    unawaited(server.exitCode.then((_) => exited = true));
    while (true) {
      final s = await Socket.connect(InternetAddress.loopbackIPv4, port);
      final r = _Reader(s);
      try {
        await r.take(1).timeout(const Duration(seconds: 3));
        return (s, r);
      } on Object {
        // The device side closed at once: the server isn't listening yet.
        s.destroy();
      }
      if (exited || DateTime.now().isAfter(until)) throw const AppError('the server did not answer');
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  }

  Future<void> _readVideo(_Reader r) async {
    try {
      while (!_closed) {
        final head = await r.take(12);
        final b = ByteData.sublistView(head);
        if (head[0] & 0x80 != 0) {
          width = b.getInt32(4);
          height = b.getInt32(8);
          _sizes.add((width, height));
          continue;
        }
        final flags = b.getUint32(0);
        final size = b.getUint32(8);
        final data = await r.take(size);
        final p = (data: data, config: flags & 0x40000000 != 0, key: flags & 0x20000000 != 0);
        if (p.config) {
          config = p;
        } else if (p.key) {
          keyFrame = p;
        }
        _packets.add(p);
      }
    } on Object {
      // The stream ended.
    }
    await close();
  }

  void _send(List<int> bytes) {
    if (_closed) throw const AppError('The scrcpy session has ended.');
    _control.add(bytes);
  }

  /// A touch: [action] 0 down, 1 up, 2 move; x and y in the video's coordinates.
  void touch(int action, double x, double y, {int pointer = -1}) {
    final b = ByteData(32)
      ..setUint8(0, 2)
      ..setUint8(1, action)
      ..setInt64(2, pointer)
      ..setInt32(10, x.round())
      ..setInt32(14, y.round())
      ..setUint16(18, width)
      ..setUint16(20, height)
      ..setUint16(22, action == 1 ? 0 : 0xffff)
      ..setInt32(24, 1) // the primary button
      ..setInt32(28, action == 1 ? 0 : 1);
    _send(b.buffer.asUint8List());
  }

  /// A wheel at (x, y): [dy] in notches (positive scrolls the content up, as a wheel turned away from you does).
  void scroll(double x, double y, double dy) {
    int fixed(double v) => (v.clamp(-16, 16) / 16 * 0x7fff).round();
    final b = ByteData(21)
      ..setUint8(0, 3)
      ..setInt32(1, x.round())
      ..setInt32(5, y.round())
      ..setUint16(9, width)
      ..setUint16(11, height)
      ..setInt16(13, 0)
      ..setInt16(15, fixed(dy))
      ..setInt32(17, 0);
    _send(b.buffer.asUint8List());
  }

  /// A key press ([keycode] from Android's KeyEvent), down then up; [meta] Android's meta state.
  void key(int keycode, {int meta = 0}) {
    for (final action in [0, 1]) {
      final b = ByteData(14)
        ..setUint8(0, 0)
        ..setUint8(1, action)
        ..setInt32(2, keycode)
        ..setInt32(6, 0)
        ..setInt32(10, meta);
      _send(b.buffer.asUint8List());
    }
  }

  /// Types [s] (ASCII is typed as keys; up to 300 bytes at a time).
  void text(String s) {
    final bytes = utf8.encode(s);
    final b = ByteData(5)
      ..setUint8(0, 1)
      ..setUint32(1, bytes.length);
    _send([...b.buffer.asUint8List(), ...bytes]);
  }

  /// Puts [s] on the device's clipboard and pastes it into the focused field (any text, emoji included).
  void paste(String s) {
    final bytes = utf8.encode(s);
    final b = ByteData(14)
      ..setUint8(0, 9)
      ..setInt64(1, 0)
      ..setUint8(9, 1)
      ..setUint32(10, bytes.length);
    _send([...b.buffer.asUint8List(), ...bytes]);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _video?.destroy();
    _control.destroy();
    _server.kill();
    await _packets.close();
    await _sizes.close();
    await AndroidSdk.run(['forward', '--remove', 'tcp:$_port'], serial: serial).catchError((Object _) => '');
  }

  @override
  String toString() => 'scrcpy $_name on $serial';
}

/// Reads exact byte counts from a socket (its one subscription).
final class _Reader {
  _Reader(Stream<Uint8List> source) {
    _sub = source.listen(
      (chunk) {
        _chunks.add(chunk);
        _have += chunk.length;
        _wake();
      },
      onDone: () {
        _ended = true;
        _wake();
        if (!_done.isCompleted) _done.complete();
      },
      onError: (Object _) {
        _ended = true;
        _wake();
        if (!_done.isCompleted) _done.complete();
      },
      cancelOnError: true,
    );
  }

  late final StreamSubscription<Uint8List> _sub;
  final _chunks = <Uint8List>[];
  var _have = 0;
  var _ended = false;
  Completer<void>? _waiting;
  final _done = Completer<void>();

  Future<void> get done => _done.future;

  void _wake() {
    final w = _waiting;
    _waiting = null;
    w?.complete();
  }

  /// The next [n] bytes; throws when the socket ends first.
  Future<Uint8List> take(int n) async {
    while (_have < n) {
      if (_ended) throw const SocketException('closed');
      // Large packets: let the socket run ahead.
      _waiting = Completer<void>();
      await _waiting!.future;
    }
    final out = Uint8List(n);
    var at = 0;
    while (at < n) {
      final c = _chunks.first;
      final need = n - at;
      if (c.length <= need) {
        out.setRange(at, at + c.length, c);
        at += c.length;
        _chunks.removeAt(0);
      } else {
        out.setRange(at, n, c);
        _chunks[0] = Uint8List.sublistView(c, need);
        at = n;
      }
    }
    _have -= n;
    return out;
  }

  Future<void> cancel() => _sub.cancel();
}
