import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'sidecar.dart';

const _url = String.fromEnvironment('AGENT_SERVER_URL');
const _key = String.fromEnvironment('AGENT_SERVER_KEY');
const _bin = String.fromEnvironment('AGENT_SERVER_BIN');

Sidecar createSidecar() => _url.isNotEmpty ? _External() : ProcessSidecar();

/// A server someone else started (`AGENT_SERVER_URL`).
final class _External implements Sidecar {
  @override
  bool get started => true;

  @override
  Future<AgentServerEndpoint> endpoint() async =>
      AgentServerEndpoint(Uri.parse(_url.endsWith('/') ? _url : '$_url/'), _key);

  @override
  Stream<void> get restarts => const Stream.empty();

  @override
  Future<void> stop() async {}
}

/// The binary, run as a child process on a free loopback port with a fresh
/// session key. Its state (conversations, logs) lives in app support
/// `agent-server/`, so sessions survive restarts.
///
/// A server that exits on its own (a crash, a kill) is started again at
/// once, within [CrashPolicy]; [restarts] then tells the sessions, which
/// reattach to their persisted conversations.
final class ProcessSidecar implements Sidecar {
  /// [binary] and [home] stand in for the found binary and app support
  /// `agent-server/` (tests).
  ProcessSidecar({this._binary, this._home, CrashPolicy? policy}) : _policy = policy ?? CrashPolicy();

  final String? _binary;
  final Directory? _home;
  final CrashPolicy _policy;
  Process? _process;
  Future<AgentServerEndpoint>? _ready;
  final _restarts = StreamController<void>.broadcast();

  /// A server crashed since the last one was ready: the next ready one is a restart.
  bool _crashed = false;

  @override
  Stream<void> get restarts => _restarts.stream;

  /// The running server's process id, if any (tests).
  @visibleForTesting
  int? get pid => _process?.pid;

  @override
  bool get started => _ready != null;

  @override
  Future<AgentServerEndpoint> endpoint() {
    if (_ready case final ready?) return ready;
    if (_policy.blockedUntil(DateTime.now()) case final until?) {
      final wait = until.difference(DateTime.now()).inSeconds + 1;
      return Future.error(
        SidecarError('The agent server keeps crashing; trying again in ${wait}s. See agent-server/server.log.'),
      );
    }
    late final Future<AgentServerEndpoint> ready;
    ready = _ready = _start().then(
      (e) {
        if (_crashed) {
          _crashed = false;
          _restarts.add(null);
        }
        return e;
      },
      onError: (Object e) {
        if (_ready == ready) _ready = null;
        throw e;
      },
    );
    return ready;
  }

  /// [wasUp]: it had answered `/ready`. One that dies while starting fails
  /// that start instead; it still counts toward the crash limit.
  void _onCrash({required bool wasUp}) {
    _policy.crashed(DateTime.now());
    if (!wasUp) return;
    _crashed = true;
    if (_policy.blockedUntil(DateTime.now()) == null) endpoint().ignore();
  }

  Future<AgentServerEndpoint> _start() async {
    final bin = _binary ?? await _findBinary();
    if (bin == null) {
      throw const SidecarError(
        'The agent server isn\'t installed. Run frontend/tool/fetch_agent_server.sh, or start the app with '
        'scripts/dev.sh.',
      );
    }
    final home = _home ?? Directory('${(await getApplicationSupportDirectory()).path}/agent-server');
    await home.create(recursive: true);
    await _killStale(home);

    final port = await _freePort();
    final key = _randomHex(24);
    final process = _process = await Process.start(
      bin,
      ['--host', '127.0.0.1', '--port', '$port'],
      workingDirectory: home.path,
      environment: {'OH_SESSION_API_KEYS_0': key, 'OH_SECRET_KEY': await _secret(home)},
    );
    await File('${home.path}/server.pid').writeAsString('${process.pid}');
    // Closed when the process exits.
    // ignore: close_sinks
    final log = File('${home.path}/server.log').openWrite(mode: FileMode.append)
      ..writeln('--- ${DateTime.now().toIso8601String()} $bin on :$port');
    var exited = false;
    var up = false;
    process.stdout.listen(log.add);
    process.stderr.listen(log.add);
    unawaited(
      process.exitCode.then((code) async {
        exited = true;
        log.writeln('--- exited with $code');
        await log.close();
        // Not stopped by us: a crash.
        if (_process == process) {
          _process = null;
          _ready = null;
          _onCrash(wasUp: up);
        }
      }),
    );

    final base = Uri.parse('http://127.0.0.1:$port/');
    final client = http.Client();
    try {
      // The PyInstaller build unpacks itself first; the first start takes ~15 s.
      final deadline = DateTime.now().add(const Duration(minutes: 2));
      while (DateTime.now().isBefore(deadline)) {
        if (exited) throw SidecarError('The agent server stopped while starting. See ${home.path}/server.log.');
        try {
          final res = await client.get(base.resolve('ready')).timeout(const Duration(seconds: 2));
          if (res.statusCode == 200 && !exited) {
            up = true;
            return AgentServerEndpoint(base, key);
          }
        } on Object {
          // Not listening yet.
        }
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      // Not a crash: this start gave up on it.
      if (_process == process) _process = null;
      process.kill();
      throw SidecarError('The agent server didn\'t start in time. See ${home.path}/server.log.');
    } finally {
      client.close();
    }
  }

  @override
  Future<void> stop() async {
    final p = _process;
    _process = null;
    _ready = null;
    // SIGTERM lets the PyInstaller bootloader stop its child too.
    p?.kill();
  }

  static Future<String?> _findBinary() async {
    final name = Platform.isWindows ? 'agent-server.exe' : 'agent-server';
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = [
      if (_bin.isNotEmpty) _bin,
      if (Platform.isMacOS) '$exeDir/../Resources/$name',
      '$exeDir/$name',
      '$exeDir/lib/$name',
      '${(await getApplicationSupportDirectory()).path}/bin/$name',
    ];
    for (final c in candidates) {
      if (await File(c).exists()) return c;
    }
    return null;
  }

  /// A server left behind by a crash keeps its port and CPU; stop it.
  static Future<void> _killStale(Directory home) async {
    final file = File('${home.path}/server.pid');
    if (!await file.exists() || Platform.isWindows) return;
    final pid = int.tryParse((await file.readAsString()).trim());
    if (pid == null) return;
    final ps = await Process.run('ps', ['-p', '$pid', '-o', 'command=']);
    if ('${ps.stdout}'.contains('agent-server')) Process.killPid(pid);
  }

  /// Encrypts secrets the server stores; must stay the same across runs.
  static Future<String> _secret(Directory home) async {
    final file = File('${home.path}/secret.key');
    if (await file.exists()) return (await file.readAsString()).trim();
    final secret = _randomHex(32);
    await file.writeAsString(secret);
    if (!Platform.isWindows) await Process.run('chmod', ['600', file.path]);
    return secret;
  }

  static Future<int> _freePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }
}

String _randomHex(int bytes) {
  final r = Random.secure();
  return [for (var i = 0; i < bytes; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
}

Future<String> createSampleProject() async {
  final root = Directory('${(await getApplicationSupportDirectory()).path}/sample-projects');
  var dir = Directory('${root.path}/counter-app');
  for (var n = 2; await dir.exists(); n++) {
    dir = Directory('${root.path}/counter-app-$n');
  }
  final files = {
    'pubspec.yaml': 'name: counter_app\nenvironment:\n  sdk: ^3.9.0\ndev_dependencies:\n  test: ^1.25.0\n',
    'lib/counter.dart': 'class Counter {\n  int value = 0;\n  void increment() => value++;\n}\n',
    'test/counter_test.dart':
        "import 'package:counter_app/counter.dart';\nimport 'package:test/test.dart';\n\nvoid main() {\n"
        "  test('increment adds one', () {\n    final c = Counter()..increment();\n    expect(c.value, 1);\n  });\n}\n",
    '.gitignore': '.dart_tool/\npubspec.lock\n',
    'README.md':
        '# counter-app\n\nA tiny Dart package to try the EveryAI coding agent on. Run the tests with `dart test`.\n',
  };
  for (final MapEntry(:key, :value) in files.entries) {
    final f = File('${dir.path}/$key');
    await f.parent.create(recursive: true);
    await f.writeAsString(value);
  }
  Future<void> git(List<String> args) async {
    final r = await Process.run('git', [
      '-c',
      'user.name=EveryAI',
      '-c',
      'user.email=sample@everyai.invalid',
      ...args,
    ], workingDirectory: dir.path);
    if (r.exitCode != 0) debugPrint('git ${args.first}: ${r.stderr}');
  }

  await git(['init', '-q']);
  await git(['add', '-A']);
  await git(['commit', '-qm', 'Sample counter app']);
  return dir.path;
}
