import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'dart:math' show Random;

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

import '../../../../core/process/child_processes.dart';
import 'lsp.dart';
import 'research_sites.dart' show secretPath;

export 'lsp.dart';

/// [path] spelled the way servers report it back: symlinks resolved (`/tmp` → `/private/tmp`), normalised, and on
/// Windows in one case.
String lspCanonical(String path) {
  var real = path;
  try {
    if (FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound) real = File(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    // As given.
  }
  return p.canonicalize(real);
}

/// One language server over stdio (JSON-RPC with Content-Length framing): it gets each file's whole text and sends
/// back what it finds (`publishDiagnostics`). Requests the server makes of us get empty answers.
final class LspClient {
  LspClient._(this._process, this.root) {
    _process.stdout.listen(_onBytes, onDone: _gone);
    _process.stderr.drain<void>();
  }

  final Process _process;
  final String root;
  final _buffer = BytesBuilder(copy: false);
  final _pending = <int, Completer<Object?>>{};
  var _nextId = 1;
  var _closed = false;

  /// Each file's findings (by path), and when they last came.
  final _diagnostics = <String, List<LspDiagnostic>>{};
  final _published = StreamController<String>.broadcast();

  /// The text each open file was last given, and its version.
  final _open = <String, ({String text, int version})>{};

  /// Checks still waiting for their findings, by path: another check of the same text joins one (sending the
  /// text again would make the first report stale, and a server may not report unchanged text twice).
  final _inflight = <String, ({String text, Future<List<LspDiagnostic>?> result})>{};

  static Future<LspClient?> start(
    LspCommand command, {
    required String root,
    Map<String, String>? environment,
    Map<String, Object?>? initializationOptions,
  }) async {
    final Process p;
    try {
      p = await Process.start(command.exe, command.args, workingDirectory: root, environment: environment);
    } on ProcessException {
      return null;
    }
    ChildProcesses.track(p.pid, label: 'Language server ${command.exe}', executable: command.exe, exited: p.exitCode);
    final c = LspClient._(p, root);
    try {
      final init = await c
          ._request('initialize', {
            'processId': pid,
            'rootUri': Uri.directory(root).toString(),
            'workspaceFolders': [
              {'uri': Uri.directory(root).toString(), 'name': root.split('/').last},
            ],
            'capabilities': {
              'textDocument': {
                'synchronization': {'didSave': true},
                'publishDiagnostics': {'relatedInformation': false, 'versionSupport': true},
              },
              'workspace': {'configuration': true, 'workspaceFolders': true},
            },
            'initializationOptions': ?initializationOptions,
          })
          .timeout(const Duration(seconds: 30));
      // An error reply (or none) is no server.
      if (init is! Map) throw StateError('initialize failed');
      c._notify('initialized', const {});
      return c;
    } on Object {
      await c.close();
      return null;
    }
  }

  bool get alive => !_closed;

  /// The findings for [path] as the server last sent them, or null when it sent none for the text it has now.
  List<LspDiagnostic>? known(String path) => _diagnostics[path];

  /// The paths the server has been given.
  Iterable<String> get openPaths => _open.keys;

  /// Gives the server [text] as [path]'s content (opening it the first time), then waits for its findings on that
  /// text: the first report after it, and any that follow within a short pause. Null when none came in [timeout].
  Future<List<LspDiagnostic>?> check(String path, String text, String languageId, {required Duration timeout}) async {
    if (_closed) return null;
    final was = _open[path];
    if (was != null && was.text == text && _diagnostics.containsKey(path)) return _diagnostics[path];
    if (_inflight[path] case (text: final t, :final result) when t == text) {
      return result.timeout(timeout, onTimeout: () => null);
    }
    final result = _check(path, text, languageId, was, timeout);
    _inflight[path] = (text: text, result: result);
    try {
      return await result;
    } finally {
      if (identical(_inflight[path]?.result, result)) _inflight.remove(path);
    }
  }

  Future<List<LspDiagnostic>?> _check(
    String path,
    String text,
    String languageId,
    ({String text, int version})? was,
    Duration timeout,
  ) async {
    final uri = Uri.file(path).toString();
    final next = _published.stream.where((p) => p == path);
    final first = next.first.timeout(timeout);
    _diagnostics.remove(path);
    if (was == null) {
      _open[path] = (text: text, version: 1);
      _notify('textDocument/didOpen', {
        'textDocument': {'uri': uri, 'languageId': languageId, 'version': 1, 'text': text},
      });
    } else {
      final version = was.version + 1;
      _open[path] = (text: text, version: version);
      _notify('textDocument/didChange', {
        'textDocument': {'uri': uri, 'version': version},
        'contentChanges': [
          {'text': text},
        ],
      });
    }
    _notify('textDocument/didSave', {
      'textDocument': {'uri': uri},
    });
    try {
      await first;
    } on Object {
      return null;
    }
    // Some servers report in stages (syntax first, types after): take what comes within a short pause.
    while (true) {
      try {
        await next.first.timeout(const Duration(milliseconds: 400));
      } on TimeoutException {
        break;
      } on StateError {
        break;
      }
    }
    return _diagnostics[path];
  }

  void _onBytes(List<int> bytes) {
    _buffer.add(bytes);
    while (true) {
      final all = _buffer.toBytes();
      final head = _headerEnd(all);
      if (head < 0) return;
      final header = ascii.decode(all.sublist(0, head), allowInvalid: true);
      final length = int.tryParse(
        RegExp(r'Content-Length:\s*(\d+)', caseSensitive: false).firstMatch(header)?[1] ?? '',
      );
      final start = head + 4;
      if (length == null) {
        _buffer
          ..clear()
          ..add(all.sublist(start));
        continue;
      }
      if (all.length < start + length) {
        _buffer
          ..clear()
          ..add(all);
        return;
      }
      final body = all.sublist(start, start + length);
      _buffer
        ..clear()
        ..add(all.sublist(start + length));
      try {
        _onMessage(jsonDecode(utf8.decode(body, allowMalformed: true)));
      } on FormatException {
        // A garbled message is skipped.
      }
    }
  }

  static int _headerEnd(List<int> b) {
    for (var i = 0; i + 3 < b.length; i++) {
      if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) return i;
    }
    return -1;
  }

  void _onMessage(Object? m) {
    if (m is! Map) return;
    final id = m['id'];
    final method = m['method'];
    if (method == null && id is int) {
      _pending.remove(id)?.complete(m['error'] == null ? m['result'] : null);
      return;
    }
    if (method == 'textDocument/publishDiagnostics') {
      final params = m['params'] as Map? ?? const {};
      final uri = params['uri'];
      if (uri is! String) return;
      final String path;
      try {
        path = lspCanonical(Uri.parse(uri).toFilePath());
      } on Object {
        return;
      }
      final version = params['version'];
      // A report for an older text than the server has now is stale.
      if (version is int && _open[path] != null && version != _open[path]!.version) return;
      _diagnostics[path] = [for (final d in params['diagnostics'] as List? ?? const []) ?lspDiagnosticOf(d)];
      _published.add(path);
      return;
    }
    // A request of ours to answer (configuration, progress tokens, registrations): an empty answer each.
    if (id != null) {
      final result = method == 'workspace/configuration'
          ? [for (final _ in ((m['params'] as Map?)?['items'] as List?) ?? const []) null]
          : null;
      _send({'jsonrpc': '2.0', 'id': id, 'result': result});
    }
  }

  Future<Object?> _request(String method, Map<String, Object?> params) {
    final id = _nextId++;
    final c = Completer<Object?>();
    _pending[id] = c;
    _send({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
    return c.future;
  }

  void _notify(String method, Map<String, Object?> params) =>
      _send({'jsonrpc': '2.0', 'method': method, 'params': params});

  void _send(Map<String, Object?> message) {
    if (_closed) return;
    final body = utf8.encode(jsonEncode(message));
    try {
      _process.stdin.add([...ascii.encode('Content-Length: ${body.length}\r\n\r\n'), ...body]);
    } on Object {
      _gone();
    }
  }

  void _gone() {
    if (_closed) return;
    _closed = true;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.complete(null);
    }
    _pending.clear();
    unawaited(_published.close());
  }

  /// Asks the server to shut down, then ends it.
  Future<void> close() async {
    if (!_closed) {
      try {
        await _request('shutdown', const {}).timeout(const Duration(seconds: 2));
        _notify('exit', const {});
      } on Object {
        // Killed below.
      }
    }
    _gone();
    _process.kill();
  }
}

/// A session's language servers, one per language, started on first use: the project's own install, else the
/// user's PATH, else a pinned download ([lspPinned]). Used by the diagnostics tool and the hint after edits.
final class LspHub {
  LspHub({required this.root, required this.toolsDir, this.environment});

  final String root;

  /// Where pinned servers are installed (app data `tools/`).
  final String toolsDir;

  /// The user's login environment (their PATH); null: this process's.
  final Future<Map<String, String>> Function()? environment;

  final _clients = <LspLanguage, Future<LspClient?>>{};

  /// The servers that have finished starting (what an edit's baseline and `all` read without waiting).
  final _ready = <LspLanguage, LspClient>{};

  /// Why a language has no server, once found out (for the tool's answer).
  final missing = <LspLanguage, String>{};

  bool handles(String path) => lspLanguageOf(path) != null;

  Future<LspClient?> _client(LspLanguage l) async {
    final c = await (_clients[l] ??= _start(l));
    if (c != null && !c.alive) {
      _ready.remove(l);
      await _clients.remove(l);
      return _client(l);
    }
    if (c != null) _ready[l] = c;
    return c;
  }

  Future<LspClient?> _start(LspLanguage l) async {
    final env = await environment?.call() ?? Platform.environment;
    final command = await _resolve(l, env);
    if (command == null) return null;
    final ts = l == LspLanguage.typescript ? _tsserver(command) : null;
    if (l == LspLanguage.typescript && ts == null) {
      // Without its own TypeScript the server would load the project's (and its tsconfig plugins).
      missing[l] = "The TypeScript language server's own TypeScript is missing, so it isn't started.";
      return null;
    }
    final c = await LspClient.start(
      command,
      root: root,
      environment: env,
      initializationOptions: ts == null
          ? lspInitOptions(l)
          : {
              'tsserver': {'path': ts},
            },
    );
    if (c == null) missing[l] = "${command.exe.split('/').last} didn't start.";
    return c;
  }

  /// The TypeScript installed beside the pinned server (never the project's: see [lspCandidates]).
  String? _tsserver(LspCommand command) {
    final dir = '${File(command.exe).parent.parent.path}/typescript/lib';
    return File('$dir/tsserver.js').existsSync() ? dir : null;
  }

  Future<LspCommand?> _resolve(LspLanguage l, Map<String, String> env) async {
    if (projectCodeRefusal(root, l) case final why?) {
      missing[l] = why;
      return null;
    }
    for (final c in lspCandidates(l)) {
      if (_onPath(c.name, env) case final exe?) return (exe: exe, args: c.args);
    }
    final pin = lspPinned[l];
    if (pin == null) {
      missing[l] = 'No ${l.label} language server is installed (${lspCandidates(l).first.name}).';
      return null;
    }
    final npm = _onPath('npm', env);
    if (npm == null || _onPath('node', env) == null) {
      missing[l] = 'No ${l.label} language server is installed, and EveryAI needs Node.js to install one.';
      return null;
    }
    try {
      final dir = await _installPinned(pin.id, npm, env);
      return (exe: '$dir/node_modules/.bin/${pin.bin}', args: pin.args);
    } on Object catch (e) {
      missing[l] = "Couldn't install the ${l.label} language server: $e";
      return null;
    }
  }

  /// Installs the pinned package set [id] with `npm ci` (which checks every package against the lockfile's
  /// integrity hash), into a folder named by the lockfile's hash; reused once there.
  Future<String> _installPinned(String id, String npm, Map<String, String> env) async {
    final manifest = await rootBundle.loadString('assets/lsp/$id/package.json');
    final lock = await rootBundle.loadString('assets/lsp/$id/package-lock.json');
    final hash = sha256.convert(utf8.encode(lock)).toString().substring(0, 12);
    final dir = '$toolsDir/lsp/$id-$hash';
    if (File('$dir/.installed').existsSync()) return dir;
    // A folder of its own: another session may be installing the same set at the same time.
    final tmp = Directory('$dir.tmp-$pid-${Random().nextInt(1 << 32)}')..createSync(recursive: true);
    try {
      File('${tmp.path}/package.json').writeAsStringSync(manifest);
      File('${tmp.path}/package-lock.json').writeAsStringSync(lock);
      final proc = await Process.start(
        npm,
        ['ci', '--ignore-scripts', '--no-audit', '--no-fund', '--loglevel=error'],
        workingDirectory: tmp.path,
        environment: env,
      );
      final err = StringBuffer();
      unawaited(proc.stdout.drain<void>());
      final errDone = proc.stderr.transform(utf8.decoder).forEach(err.write);
      final code = await proc.exitCode.timeout(
        const Duration(minutes: 5),
        onTimeout: () {
          proc.kill();
          return -1;
        },
      );
      await errDone.timeout(const Duration(seconds: 2), onTimeout: () {});
      if (code != 0) {
        throw code == -1 ? 'npm ci took over 5 minutes (offline?)' : '${'$err'.trim().split('\n').last} (npm ci)';
      }
      File('${tmp.path}/.installed').writeAsStringSync('');
      if (File('$dir/.installed').existsSync()) return dir;
      final target = Directory(dir);
      if (target.existsSync()) target.deleteSync(recursive: true);
      tmp.renameSync(dir);
      return dir;
    } finally {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    }
  }

  static String? _onPath(String name, Map<String, String> env) {
    final sep = Platform.isWindows ? ';' : ':';
    for (final d in (env['PATH'] ?? '').split(sep)) {
      if (d.isEmpty) continue;
      for (final ext in Platform.isWindows ? const ['.exe', '.cmd', ''] : const ['']) {
        final f = File('$d/$name$ext');
        if (f.existsSync()) return f.path;
      }
    }
    return null;
  }

  /// [path]'s findings for its text on disk (or [text]), starting its server if needed; null when there is no
  /// server or it said nothing in [timeout].
  Future<List<LspDiagnostic>?> check(
    String path, {
    String? text,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final l = lspLanguageOf(path);
    if (l == null) return null;
    final content = text ?? (File(path).existsSync() ? File(path).readAsStringSync() : null);
    if (content == null) return null;
    final c = await _client(l).timeout(timeout, onTimeout: () => null);
    if (c == null) return null;
    return c.check(lspCanonical(path), content, lspLanguageId(l, path), timeout: timeout);
  }

  /// Opens [path] in its server in the background (after a read), so an edit has its findings to compare with.
  void warm(String path) {
    if (handles(path)) unawaited(check(path).catchError((Object _) => null));
  }

  /// The errors [path] had in the text its server was last given, or null when none are known.
  Future<int?> knownErrors(String path) async {
    final l = lspLanguageOf(path);
    // Only a server that is up: never wait for one still installing or starting.
    final d = l == null ? null : _ready[l]?.known(lspCanonical(path));
    return d == null ? null : lspErrors(d);
  }

  /// Every file the servers were given, with what they found (checked again against the files on disk).
  Future<Map<String, List<LspDiagnostic>>> all({Duration timeout = const Duration(seconds: 20)}) async {
    final out = <String, List<LspDiagnostic>>{};
    for (final c in [..._ready.values]) {
      for (final path in [...c.openPaths]) {
        final d = await check(path, timeout: timeout);
        if (d != null) out[path] = d;
      }
    }
    return out;
  }

  /// Ends every server; the next use starts them again.
  Future<void> close() async {
    final all = [..._clients.values];
    _clients.clear();
    _ready.clear();
    for (final f in all) {
      await (await f)?.close();
    }
  }
}

/// The diagnostics tool's answer in [root] for [rawPath] (relative or absolute; empty: every file checked so far),
/// for the EveryAI harness and the host's tool alike.
Future<({String text, bool isError})> diagnosticsAnswer(LspHub hub, String root, String rawPath) async {
  final real = lspCanonical(root);
  String rel(String path) {
    for (final r in {root, real}) {
      if (p.isWithin(r, path)) return p.split(p.relative(path, from: r)).join('/');
    }
    return path;
  }

  final raw = rawPath.trim();
  if (raw.isEmpty) {
    final all = await hub.all();
    if (all.isEmpty) {
      return (text: 'No files have been checked yet. Pass a path, or read or edit a file first.', isError: false);
    }
    return (text: formatDiagnostics({for (final e in all.entries) rel(e.key): e.value}), isError: false);
  }
  final path = p.normalize(p.isAbsolute(raw) ? raw : p.join(root, raw));
  // Like a read, but only inside the project: a server's messages quote the file, and nothing wraps them here.
  if (!p.isWithin(root, path) && !p.isWithin(real, path)) {
    return (text: 'Error: diagnostics check files inside the project only.', isError: true);
  }
  if (secretPath(path)) return (text: 'Error: ${rel(path)} may hold secrets; it is not checked.', isError: true);
  if (!File(path).existsSync()) return (text: 'Error: $path does not exist.', isError: true);
  final language = lspLanguageOf(path);
  if (language == null) {
    return (
      text: "No language server is known for ${rel(path)}. Run the project's own checks instead.",
      isError: false,
    );
  }
  final found = await hub.check(path);
  if (found == null) {
    final why = hub.missing[language] ?? 'The ${language.label} language server sent nothing in time.';
    return (text: "$why Run the project's own checks instead.", isError: false);
  }
  return (text: formatDiagnostics({rel(path): found}), isError: false);
}

/// Why the [language] server isn't started for the project at [root], or null. Diagnostics run without asking, so
/// nothing the repository controls may make the server run code:
/// - Rust: a toolchain file can name a rust-analyzer inside the repo, and cargo config can name a rustc or a
///   wrapper; rust-analyzer.toml can turn build scripts and proc macros back on.
/// - Dart: analyzer plugins named in any analysis_options.yaml, directly or through what it includes.
String? projectCodeRefusal(String root, LspLanguage language) {
  if (language != LspLanguage.rust && language != LspLanguage.dart) return null;
  for (final f in _projectFiles(root)) {
    final name = p.basename(f);
    final parent = p.basename(p.dirname(f));
    if (language == LspLanguage.rust) {
      final cargoConfig = parent == '.cargo' && (name == 'config' || name == 'config.toml');
      if (name == 'rust-toolchain' || name == 'rust-toolchain.toml' || name == 'rust-analyzer.toml' || cargoConfig) {
        return '${p.relative(f, from: root)} can make the Rust toolchain run programs from the project, so EveryAI '
            "doesn't start rust-analyzer itself. Run cargo check instead.";
      }
    } else if (name == 'analysis_options.yaml' && _loadsPlugins(f, root, 0)) {
      return '${lspProjectCodeRefusal(LspLanguage.dart, analysisOptions: 'plugins:')} '
          '(${p.relative(f, from: root)})';
    }
  }
  return null;
}

/// The files under [root] a server could read for its settings: folders a build or a package manager fills are
/// skipped, and the walk is bounded.
Iterable<String> _projectFiles(String root) sync* {
  const skip = {'.git', 'node_modules', 'target', 'build', '.dart_tool', '.venv', 'venv', '__pycache__', 'Pods'};
  var queue = [(dir: root, depth: 0)];
  var seen = 0;
  while (queue.isNotEmpty && seen < 4000) {
    final next = <({String dir, int depth})>[];
    for (final d in queue) {
      seen++;
      final List<FileSystemEntity> entries;
      try {
        entries = Directory(d.dir).listSync(followLinks: false);
      } on FileSystemException {
        continue;
      }
      for (final e in entries) {
        final name = p.basename(e.path);
        if (e is Directory) {
          if (d.depth < 6 && !skip.contains(name)) next.add((dir: e.path, depth: d.depth + 1));
        } else if (e is File) {
          yield e.path;
        }
      }
    }
    queue = next;
  }
}

/// Whether the analysis options file [path] names analyzer plugins, itself or through its `include:`s (files, and
/// `package:` files found through the project's package config). An include that can't be found counts as plugins.
bool _loadsPlugins(String path, String root, int depth) {
  if (depth > 6) return true;
  final String text;
  try {
    text = File(path).readAsStringSync();
  } on FileSystemException {
    return true;
  }
  if (lspProjectCodeRefusal(LspLanguage.dart, analysisOptions: text) != null) return true;
  final includes = <String>[];
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final m = RegExp(r'^include\s*:\s*(.*)$').firstMatch(lines[i]);
    if (m == null) continue;
    final rest = m[1]!.trim();
    if (rest.isNotEmpty) {
      includes.add(rest.replaceAll(RegExp('^["\']|["\']\$'), ''));
    } else {
      // A list of includes.
      for (var j = i + 1; j < lines.length && RegExp(r'^\s+-').hasMatch(lines[j]); j++) {
        includes.add(lines[j].replaceFirst(RegExp(r'^\s+-\s*'), '').trim().replaceAll(RegExp('^["\']|["\']\$'), ''));
      }
    }
  }
  for (final inc in includes) {
    final target = inc.startsWith('package:') ? _packageFile(inc, p.dirname(path), root) : p.join(p.dirname(path), inc);
    if (target == null || _loadsPlugins(target, root, depth + 1)) return true;
  }
  return false;
}

/// The file a `package:name/path` URI names, through the nearest `.dart_tool/package_config.json` at or above [from]
/// (up to [root]); null when it can't be found.
String? _packageFile(String uri, String from, String root) {
  final rest = uri.substring('package:'.length);
  final slash = rest.indexOf('/');
  if (slash < 0) return null;
  final name = rest.substring(0, slash);
  for (var dir = from; ; dir = p.dirname(dir)) {
    final config = File(p.join(dir, '.dart_tool', 'package_config.json'));
    if (config.existsSync()) {
      try {
        final json = jsonDecode(config.readAsStringSync()) as Map<String, Object?>;
        for (final pkg in json['packages'] as List<Object?>? ?? const []) {
          if (pkg is! Map || pkg['name'] != name) continue;
          final base = Uri.directory(p.join(dir, '.dart_tool'));
          final pkgRoot = base.resolve('${pkg['rootUri']}'.endsWith('/') ? '${pkg['rootUri']}' : '${pkg['rootUri']}/');
          final lib = pkgRoot.resolve('${pkg['packageUri'] ?? 'lib/'}');
          return lib.resolve(rest.substring(slash + 1)).toFilePath();
        }
      } on Object {
        return null;
      }
      return null;
    }
    if (p.equals(dir, root) || p.dirname(dir) == dir) return null;
  }
}
