import 'dart:async';

import 'package:every_ai/features/local_models/data/local_http.dart';
import 'package:every_ai/features/local_models/data/local_system.dart';
import 'package:every_ai/features/local_models/domain/fm.dart';
import 'package:every_ai/features/local_models/domain/hardware.dart';

/// Answers by `METHOD path` (port included in the key as `:port/path` when [byPort]), else nothing answers.
final class FakeLocalHttp implements LocalHttp {
  FakeLocalHttp([Map<String, LocalReply>? replies]) : replies = replies ?? {};

  /// Keys: `GET 127.0.0.1:11434/api/tags`.
  final Map<String, LocalReply> replies;
  final calls = <String>[];
  final sent = <String, Object?>{};

  /// Lines per pull: tag → the stream of its latest pull, or canned lines.
  final pulls = <String, StreamController<String>>{};
  final pullLines = <String, List<String>>{};

  String _key(String method, Uri url) => '$method ${url.host}:${url.port}${url.path}';

  @override
  Future<LocalReply?> get(Uri url, {Map<String, String> headers = const {}, Duration? timeout}) =>
      send('GET', url, headers: headers, timeout: timeout);

  @override
  Future<LocalReply?> send(
    String method,
    Uri url, {
    Object? json,
    Map<String, String> headers = const {},
    Duration? timeout,
  }) async {
    final k = _key(method, url);
    calls.add(k);
    sent[k] = json;
    if (json is Map && json['model'] is String && replies.containsKey('$k#${json['model']}')) {
      return replies['$k#${json['model']}'];
    }
    return replies[k];
  }

  @override
  Stream<String> postLines(Uri url, Object json) {
    final tag = (json as Map)['model'] as String;
    calls.add('PULL $tag');
    if (pullLines[tag] case final lines?) return Stream.fromIterable(lines);
    // A fresh stream per pull (a pulled-again tag gets a new one).
    // ignore: close_sinks, the test closes the ones it uses.
    final c = pulls[tag] = StreamController<String>();
    return c.stream;
  }
}

final class FakeLocalSystem implements LocalSystem {
  FakeLocalSystem({
    this.os = HostOs.macos,
    this.spec = const HardwareSpec(
      os: HostOs.macos,
      chip: 'Apple M2 Pro',
      memoryBytes: 16 << 30,
      unifiedMemory: true,
      freeDiskBytes: 212 << 30,
    ),
    this.fm = FmStatus.missing,
    this.ollama,
    this.fmPort,
  });

  @override
  final HostOs os;
  HardwareSpec spec;
  FmStatus fm;
  String? ollama;
  int? fmPort;
  var ollamaStarts = 0;
  var stops = 0;
  String? lms;

  /// Launched servers by id, with the completer that ends each (a test "exits" it).
  final launched = <String, Completer<int>>{};
  final launches = <String>[];
  final ran = <String>[];
  final stoppedPorts = <int>[];

  /// What [stopListener] answers (null: it stopped).
  String? listenerStopProblem;

  /// Called on each launch (a test makes the server answer).
  void Function(String id, List<String> args)? onLaunch;

  @override
  Future<HardwareSpec> hardware() async => spec;
  @override
  Future<String?> ollamaPath() async => ollama;
  @override
  Future<String?> lmsPath() async => lms;
  @override
  Future<FmStatus> fmStatus() async => fm;
  @override
  Future<({int code, String out})?> run(String exe, List<String> args) async {
    ran.add([exe, ...args].join(' '));
    return (code: 0, out: '');
  }

  @override
  Future<LaunchedServer?> launch(
    String id,
    String exe,
    List<String> args, {
    Map<String, String> env = const {},
    bool shell = false,
    String? logPath,
  }) async {
    if (id == 'ollama') ollamaStarts++;
    launches.add(id);
    final c = launched[id] = Completer<int>();
    onLaunch?.call(id, args);
    return LaunchedServer(pid: 1000 + launches.length, exited: c.future);
  }

  @override
  String? get launchProblem => null;
  @override
  bool owns(String id) => launched[id] != null && !launched[id]!.isCompleted;
  @override
  Future<String?> stopOwned(String id, {Duration grace = const Duration(seconds: 5)}) async {
    final c = launched.remove(id);
    if (c != null && !c.isCompleted) c.complete(0);
    return null;
  }

  @override
  Future<String?> stopListener(int port, {Duration grace = const Duration(seconds: 5)}) async {
    stoppedPorts.add(port);
    return listenerStopProblem;
  }

  @override
  Future<int?> freePort() async => fmPort;
  @override
  Future<void> stopAllOwned() async {
    stops++;
    for (final id in launched.keys.toList()) {
      await stopOwned(id);
    }
  }

  @override
  Future<String?> logDir() async => null;
}

LocalReply json(String body, [int status = 200]) => LocalReply(status, body);
