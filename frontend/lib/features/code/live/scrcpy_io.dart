// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import '../git/git_service.dart';
import 'adb_io.dart';
import 'app_view.dart';
import 'scrcpy_pin.dart';
import 'verified_download_io.dart';
import '../../../core/process/supervisor.dart';

/// One encoded video packet from the device (Annex-B H.264); [config] holds the parameter sets.
typedef VideoPacket = ({Uint8List data, bool config, bool key});

Future<String>? _fetching;

/// The pinned scrcpy server file, downloaded once into the app's data folder and checked against its SHA-256.
Future<String> scrcpyServer() => _fetching ??= () async {
  if (Platform.environment['EVERYAI_SCRCPY_SERVER'] case final set? when File(set).existsSync()) return set;
  final dir = '${await GitService.dataDir()}/tools/scrcpy-$scrcpyVersion';
  final file = File('$dir/scrcpy-server');
  if (!file.existsSync()) await downloadVerifiedTo(Uri.parse(scrcpyServerUrl), scrcpyServerSha256, file);
  return file.path;
}().whenComplete(() => _fetching = null);

/// A scrcpy session with one Android device: the server pushed and started over adb, a forwarded port, the video
/// socket (when [video]) and the control socket. Touches, keys and text go through [touch], [key], [text] and
/// [paste]; [packets] carries the encoded screen, [sizes] the picture's size (it changes on rotation).
final class ScrcpyConnection {
  ScrcpyConnection._(this.serial, this._server, this._port, this._name, this._video, this._control);

  /// The adb forwards scrcpy sessions of this run set up (`serial|port`), until each is removed. One whose removal
  /// failed stays here, and [forwardProblems] says why (adb keeps a forward until it is removed or adb restarts).
  static final forwards = <String>{};
  static final forwardProblems = <String, String>{};

  /// Removes the forward of [port] on [serial]; a failure is kept in [forwardProblems] and logged.
  static Future<bool> _unforward(String serial, int port) async {
    final key = '$serial|$port';
    try {
      await AndroidSdk.run(['forward', '--remove', 'tcp:$port'], serial: serial, timeout: const Duration(seconds: 10));
      forwards.remove(key);
      forwardProblems.remove(key);
      await _record(serial, port, null);
      return true;
    } on Object catch (e) {
      forwardProblems[key] = '$e';
      debugPrint('NOT CLOSED: the adb forward tcp:$port on $serial could not be removed: $e');
      return false;
    }
  }

  /// App data `scrcpy-forwards.json`: every forward EveryAI set up (`serial|port|socket name`) until it is removed,
  /// so a later run can tell the ones a crashed run left from the user's own scrcpy (whose forwards look the same).
  static Future<File> _recordFile() async => File('${await GitService.dataDir()}/scrcpy-forwards.json');

  static Future<void> _recordQueue = Future.value();

  /// Adds (with [name]) or removes (null) the record of [serial]'s forward of [port]; writes run one at a time.
  static Future<void> _record(String serial, int port, String? name) {
    final next = _recordQueue.then((_) async {
      final now = await _recorded();
      now.removeWhere((r) => r.startsWith('$serial|$port|'));
      if (name != null) now.add('$serial|$port|$name');
      try {
        final f = await _recordFile();
        await f.parent.create(recursive: true);
        await f.writeAsString(jsonEncode([...now]));
      } on Object catch (e) {
        debugPrint('scrcpy: the record of its adb forwards could not be written: $e');
      }
    });
    return _recordQueue = next;
  }

  static Future<Set<String>> _recorded() async {
    try {
      final f = await _recordFile();
      if (!f.existsSync()) return {};
      final j = jsonDecode(await f.readAsString());
      return {
        if (j is List)
          for (final x in j)
            if (x is String) x,
      };
    } on Object catch (e) {
      debugPrint('scrcpy: the record of its adb forwards could not be read: $e');
      return {};
    }
  }

  /// Forwards on [serial] that EveryAI recorded setting up (same port and socket name) and no session of this run
  /// holds: left by a run that crashed. A forward EveryAI has no record of (the user's own scrcpy, another tool) is
  /// never removed, whatever its name.
  static Future<void> _removeStaleForwards(String serial) async {
    final recorded = await _recorded();
    if (!recorded.any((r) => r.startsWith('$serial|'))) return;
    final String list;
    try {
      list = await AndroidSdk.run(['forward', '--list'], timeout: const Duration(seconds: 10));
    } on Object catch (e) {
      debugPrint('scrcpy: the adb forwards could not be listed ($e); stale ones may remain.');
      return;
    }
    final present = <String>{};
    for (final line in list.split('\n')) {
      final m = RegExp(r'^(\S+)\s+tcp:(\d+)\s+localabstract:(scrcpy_\S+)$').firstMatch(line.trim());
      if (m == null || m.group(1) != serial) continue;
      final port = int.parse(m.group(2)!);
      final key = '$serial|$port|${m.group(3)}';
      present.add(key);
      if (recorded.contains(key) && !forwards.contains('$serial|$port')) await _unforward(serial, port);
    }
    // Records of forwards adb no longer has (it restarted, the device went): dropped.
    for (final r in recorded) {
      final parts = r.split('|');
      if (parts.length == 3 &&
          parts[0] == serial &&
          !present.contains(r) &&
          !forwards.contains('${parts[0]}|${parts[1]}')) {
        await _record(serial, int.parse(parts[1]), null);
      }
    }
  }

  final String serial;
  final SupervisedProcess _server;
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
    await _removeStaleForwards(serial);
    await AndroidSdk.run(['push', server, remote], serial: serial);
    final scid = Random.secure().nextInt(0x7fffffff).toRadixString(16).padLeft(8, '0');
    final name = 'scrcpy_$scid';
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    await AndroidSdk.run(['forward', 'tcp:$port', 'localabstract:$name'], serial: serial);
    forwards.add('$serial|$port');
    await _record(serial, port, name);
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
    final SupervisedProcess p;
    try {
      p = await ProcessSupervisor.instance.spawn(
        SpawnSpec(
          owner: const AppOwner(),
          kind: ProcessKind.stream,
          exe: AndroidSdk.adb!,
          args: ['-s', serial, 'shell', args.join(' ')],
          label: 'scrcpy server ($serial)',
          detail: 'serial $serial, forward tcp:$port',
        ),
      );
    } on Object catch (e) {
      await _unforward(serial, port);
      throw AppError("Couldn't start scrcpy on $serial: $e");
    }
    final log = StringBuffer();
    p.stdout.transform(utf8.decoder).listen(log.write, onError: (Object _) {});
    p.stderr.transform(utf8.decoder).listen(log.write, onError: (Object _) {});
    Future<void> undo() async {
      final outcome = await p.stop();
      if (outcome is! Ended) debugPrint('NOT CLOSED: scrcpy server ($serial) after a failed start: $outcome');
      await _unforward(serial, port);
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

  static Future<(Socket, _Reader)> _connectFirst(int port, SupervisedProcess server) async {
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

  /// Puts [s] on the device's clipboard and pastes it into the focused field (any text, emoji included); with
  /// [paste] false only sets the clipboard.
  void paste(String s, {bool paste = true}) {
    final bytes = utf8.encode(s);
    final b = ByteData(14)
      ..setUint8(0, 9)
      ..setInt64(1, 0)
      ..setUint8(9, paste ? 1 : 0)
      ..setUint32(10, bytes.length);
    _send([...b.buffer.asUint8List(), ...bytes]);
  }

  Future<KillOutcome>? _closing;

  /// Ends the session: its sockets first (the server on the device then ends by itself), then the `adb shell`
  /// process (verified), then the forward. The outcome of the process stop; a forward that stays is in
  /// [forwardProblems].
  Future<KillOutcome> close() => _closing ??= _close();

  Future<KillOutcome> _close() async {
    _closed = true;
    _video?.destroy();
    _control.destroy();
    final outcome = await _server.stop();
    if (outcome is! Ended) debugPrint('NOT CLOSED: scrcpy server ($serial): $outcome');
    await _packets.close();
    await _sizes.close();
    await _unforward(serial, _port);
    return outcome;
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
