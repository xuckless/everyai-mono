// ignore_for_file: invalid_use_of_visible_for_testing_member, depend_on_referenced_packages
// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

// Dev only: process ownership, live (macOS). Stands up the real Code session controller on the EveryAI harness in a
// temp git project, with no model: the tools are called through the harness's own entry point
// (`EveryAISession.runToolDirectly`), and Stop, Stop all and delete are the controller's own. Every check goes to
// RIG_OUT/results.json (name, passed, evidence). The app's data folder (path_provider) is RIG_DATA, so the user's
// own data, ledger and keychain are never touched.
//   flutter build macos --debug -t tool/live_apps/process_rig.dart \
//     --dart-define=RIG_OUT=/tmp/rig --dart-define=RIG_DATA=/tmp/rig/data [--dart-define=RIG_MODE=life]
//   build/macos/Build/Products/Debug/EveryAI.app/Contents/MacOS/EveryAI
// RIG_MODE=session (default): steps 2 and 4 (stop / restart / Stop all / delete; pool, shell cap, budget), then the
// app's quit sequence, then exit.
// RIG_MODE=life: the app's quit wiring (quit, SIGTERM, the launch sweep) with a few supervised children alive; it
// writes life.json and waits to be quit or killed.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:drift/native.dart';
import 'package:every_ai/app/app_quit.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/net/api_client.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/process/budget.dart' show processBudgetKey;
import 'package:every_ai/core/process/pool.dart';
import 'package:every_ai/core/process/supervisor.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:every_ai/features/code/drivers/everyai_driver.dart';
import 'package:every_ai/features/code/harness/events.dart' show ExecutionStatus;
import 'package:every_ai/features/code/harness/everyai/everyai_harness_io.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/live/browser_jar.dart';
import 'package:every_ai/features/code/live/live_browsers.dart';
import 'package:every_ai/features/code/live/live_pool.dart';
import 'package:every_ai/features/code/mcp_providers.dart';
import 'package:every_ai/features/code/shells/shell_registry.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:every_ai/features/processes/process_providers.dart';
import 'package:every_ai/features/usage/usage_totals.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

const _outDefine = String.fromEnvironment('RIG_OUT');
const _dataDefine = String.fromEnvironment('RIG_DATA');
final _mode = Platform.environment['RIG_MODE'] ?? const String.fromEnvironment('RIG_MODE', defaultValue: 'session');

late final Directory _out;
late final String _data;
final _status = ValueNotifier<String>('starting');
final _results = <Map<String, Object?>>[];
final _log = <String>[];

void _note(String line) {
  final l = '${DateTime.now().toIso8601String().substring(11, 23)} $line';
  _log.add(l);
  // ignore: avoid_print
  print('RIG $l');
  _status.value = line;
  File('${_out.path}/log.txt').writeAsStringSync('${_log.join('\n')}\n');
}

void _check(String name, bool passed, Object evidence) {
  _results.add({'name': name, 'passed': passed, 'evidence': evidence});
  _note('${passed ? 'PASS' : 'FAIL'} $name');
  File('${_out.path}/results.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(_results));
}

// ignore: unused_element
void _notRun(String name, String why) {
  _results.add({'name': name, 'passed': null, 'evidence': 'not run: $why'});
  _note('NOT RUN $name: $why');
  File('${_out.path}/results.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(_results));
}

/// The app's data folder, redirected (the supervisor's ledger, sessions, browser jars, tools).
final class _RigPaths extends PathProviderPlatform {
  _RigPaths(this.root);
  final String root;
  String _d(String sub) => (Directory('$root/$sub')..createSync(recursive: true)).path;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => _d('tmp');
  @override
  Future<String?> getApplicationDocumentsPath() async => _d('docs');
  @override
  Future<String?> getApplicationCachePath() async => _d('cache');
  @override
  Future<String?> getLibraryPath() async => _d('library');
  @override
  Future<String?> getDownloadsPath() async => _d('downloads');
}

/// The EveryAI harness, but a session's first message is only added (never run): no model is called.
final class _NoModelHarness implements Harness {
  _NoModelHarness(this.inner);
  final EveryAIHarness inner;

  @override
  Future<HarnessSession> start(SessionSpec s) => inner.start(
    SessionSpec(
      workingDir: s.workingDir,
      model: s.model,
      mode: s.mode,
      llmBaseUrl: s.llmBaseUrl,
      llmApiKey: s.llmApiKey,
      sessionTag: s.sessionTag,
      processTag: s.processTag,
      initialMessage: s.initialMessage,
      runInitial: false,
      maxInputTokens: s.maxInputTokens,
      maxOutputTokens: s.maxOutputTokens,
      vision: s.vision,
      initialImages: s.initialImages,
      persona: s.persona,
      promptSuffix: s.promptSuffix,
      effort: s.effort,
      holdClientTools: s.holdClientTools,
      subagent: s.subagent,
      mcpConfig: s.mcpConfig,
      skills: s.skills,
      tools: s.tools,
      rolePrompt: s.rolePrompt,
      clientTools: s.clientTools,
      autoCompactAt: s.autoCompactAt,
      pathMap: s.pathMap,
      researchSites: s.researchSites,
      bugCheck: s.bugCheck,
      script: s.script,
      reviewModel: s.reviewModel,
      briefing: s.briefing,
      liveId: s.liveId,
      browserProfile: s.browserProfile,
      skillsOff: s.skillsOff,
      runtimeProfiles: s.runtimeProfiles,
    ),
  );

  @override
  Future<HarnessSession> attach(String conversationId) => inner.attach(conversationId);

  @override
  Future<Map<String, ExecutionStatus>> statuses(List<String> ids) => inner.statuses(ids);
}

class _Catalog extends CatalogController {
  @override
  ModelCatalog build() => builtInCatalog;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  _out = Directory(
    Platform.environment['RIG_OUT'] ??
        (_outDefine.isNotEmpty ? _outDefine : '${Directory.systemTemp.path}/process-rig'),
  )..createSync(recursive: true);
  _data = Platform.environment['RIG_DATA'] ?? (_dataDefine.isNotEmpty ? _dataDefine : '${_out.path}/data');
  Directory(_data).createSync(recursive: true);
  PathProviderPlatform.instance = _RigPaths(_data);
  // Browser jars sealed with a fixed key in the rig's folder: never the user's keychain.
  SealedStore.override = SealedStore('$_data/browser', () async => SecretKey(List.filled(32, 7)));
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: ValueListenableBuilder<String>(
            valueListenable: _status,
            builder: (_, s, _) => Text('process rig ($_mode): $s', textAlign: TextAlign.center),
          ),
        ),
      ),
    ),
  );
  final run = _mode == 'life' ? _life() : _session();
  unawaited(
    run.catchError((Object e, StackTrace s) => _check('rig crashed', false, '$e\n$s')).whenComplete(() {
      if (_mode != 'life') exit(0);
    }),
  );
}

// ------------------------------------------------------------------ container

final _noNetwork = MockClient((req) async => http.Response('no network in the rig', 599));

late final ProviderContainer _c;
late final Preferences _prefs;
late final _NoModelHarness _harness;

void _makeContainer({Map<String, String> prefs = const {}}) {
  _prefs = Preferences.inMemory(prefs);
  _harness = _NoModelHarness(EveryAIHarness(dataDir: () async => _data, gatewayKey: () async => ''));
  _c = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(AppDatabase(NativeDatabase.memory())),
      preferencesProvider.overrideWithValue(_prefs),
      modelCatalogProvider.overrideWith(_Catalog.new),
      codeUsageProvider.overrideWithBuild((ref, n) async => UsageTotals.zero),
      everyaiHarnessProvider.overrideWithValue(_harness),
      driverRegistryProvider.overrideWithValue(DriverRegistry({everyaiHarnessName: EveryAIDriver(_harness)})),
      driverDataDirProvider.overrideWithValue(() async => _data),
      apiClientProvider.overrideWithValue(ApiClient(baseUrl: Uri.parse('http://rig.invalid/'), client: _noNetwork)),
    ],
  );
}

// ------------------------------------------------------------------ the OS's view

typedef _Row = ({int pid, int ppid, int pgid, String tty, String command});

Future<Map<int, _Row>> _ps() async {
  final r = await Process.run('ps', ['-axww', '-o', 'pid=,ppid=,pgid=,tty=,command=']);
  final rows = <int, _Row>{};
  for (final line in const LineSplitter().convert('${r.stdout}')) {
    final m = RegExp(r'^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(.*)$').firstMatch(line);
    if (m == null) continue;
    final pid = int.parse(m[1]!);
    rows[pid] = (pid: pid, ppid: int.parse(m[2]!), pgid: int.parse(m[3]!), tty: m[4]!, command: m[5]!);
  }
  return rows;
}

Set<int> _treeOf(Map<int, _Row> t, Iterable<int> roots) {
  final out = <int>{};
  final q = [...roots.where(t.containsKey)];
  while (q.isNotEmpty) {
    final p = q.removeLast();
    if (!out.add(p)) continue;
    q.addAll(t.values.where((r) => r.ppid == p).map((r) => r.pid));
  }
  return out;
}

/// Session ids (getsid) of [pids], read by python (macOS ps has no sid column).
Future<Map<int, int?>> _sids(Iterable<int> pids) async {
  final list = pids.toList();
  if (list.isEmpty) return {};
  final r = await Process.run('/usr/bin/python3', [
    '-c',
    'import os,sys\nfor p in sys.argv[1:]:\n  try: print(p, os.getsid(int(p)))\n  except Exception: print(p, -1)',
    ...list.map((p) => '$p'),
  ]);
  return {
    for (final l in const LineSplitter().convert('${r.stdout}'))
      int.parse(l.split(' ')[0]): int.tryParse(l.split(' ')[1]).let((s) => s == -1 ? null : s),
  };
}

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}

/// `ps`-style lines (pid ppid pgid sid tty command) for [pids] that run.
Future<List<String>> _psLines(Iterable<int> pids) async {
  final t = await _ps();
  final alive = pids.where(t.containsKey).toList()..sort();
  final sids = await _sids(alive);
  return [
    for (final p in alive)
      '${t[p]!.pid} ppid=${t[p]!.ppid} pgid=${t[p]!.pgid} sid=${sids[p]} tty=${t[p]!.tty} ${_short(t[p]!.command)}',
  ];
}

String _short(String s) => s.length > 160 ? '${s.substring(0, 160)}…' : s;

/// Pids whose environment carries `EVERYAI_SESSION=<tag>` (the supervisor's own env scan).
Future<Set<int>> _tagged(String tag) async {
  final scan = await ProcessSupervisor.instance.scan(env: true);
  if (scan is! Listed) return {};
  return {
    for (final r in scan.table.rows.values)
      if (r.tag(sessionTagEnvVar) == tag && !r.zombie) r.pid,
  };
}

Future<bool> _portOpen(int port) async {
  try {
    final s = await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: const Duration(seconds: 1));
    s.destroy();
    return true;
  } on Object {
    return false;
  }
}

Future<int> _freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  await s.close();
  return p;
}

Future<void> _git(String dir, List<String> args) async {
  final r = await Process.run('git', [
    '-c',
    'user.name=rig',
    '-c',
    'user.email=rig@example.invalid',
    ...args,
  ], workingDirectory: dir);
  if (r.exitCode != 0) throw StateError('git ${args.join(' ')}: ${r.stderr}');
}

// ------------------------------------------------------------------ the project

const _mcpServer = r'''
import json, os, sys
def send(m):
    sys.stdout.write(json.dumps(m) + "\n"); sys.stdout.flush()
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    m = json.loads(line)
    mid = m.get("id"); method = m.get("method")
    if mid is None:
        continue
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": m["params"].get("protocolVersion", "2025-06-18"),
              "capabilities": {"tools": {}}, "serverInfo": {"name": "rigmcp", "version": "1"}}})
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": mid, "result": {"tools": [{"name": "rig_echo", "description": "Echoes text with the server's pid.",
              "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}}]}})
    elif method == "tools/call":
        t = m["params"].get("arguments", {}).get("text", "")
        send({"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": "echo:%s pid:%d" % (t, os.getpid())}]}})
    else:
        send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "no " + str(method)}})
''';

Future<String> _makeProject(String name) async {
  final dir = Directory('${_out.path}/$name')..createSync(recursive: true);
  File('${dir.path}/index.html').writeAsStringSync('<!doctype html><title>RigPage</title><h1 id="h">Hello rig</h1>');
  File('${dir.path}/bin/main.dart')
    ..createSync(recursive: true)
    ..writeAsStringSync("void main() {\n  int x = 'not an int';\n  print(x);\n}\n");
  File('${dir.path}/pubspec.yaml').writeAsStringSync('name: rig_project\nenvironment:\n  sdk: ^3.0.0\n');
  File('${dir.path}/.gitignore').writeAsStringSync('.everyai/\n.dart_tool/\n');
  await _git(dir.path, ['init', '-q']);
  await _git(dir.path, ['add', '.']);
  await _git(dir.path, ['commit', '-qm', 'rig']);
  return dir.path;
}

// ------------------------------------------------------------------ steps 2 and 4

Future<void> _session() async {
  _note('session mode; data folder $_data; app pid $pid');
  final projectDir = await _makeProject('project');
  final mcpScript = '${_out.path}/rig_mcp.py';
  File(mcpScript).writeAsStringSync(_mcpServer);
  final mcp = McpServer(name: 'rigmcp', command: '/usr/bin/python3', args: [mcpScript]).approve();
  _makeContainer(
    prefs: {
      'code.projects': jsonEncode([CodeProject(id: 'p1', name: 'Rig', path: projectDir).toJson()]),
      CodeMcpServers.key: jsonEncode(StoredMcpServers(global: [mcp]).toJson()),
    },
  );
  // What the shell does at app start: the pool, the budget watch, the jars; and the quit wiring (sweep).
  _c.read(driverShutdownProvider);
  _c.read(appQuitProvider);
  final sweep = await _waitFor(() => ProcessSupervisor.instance.lastSweep.value, const Duration(seconds: 20));
  _note('launch sweep: $sweep');
  final ledgerDir = await ProcessSupervisor.instance.ledgerDirectory;
  _note('ledger folder: $ledgerDir');

  // Step 1's launcher proof: a script without `#!` runs in /bin/sh, and the command line says who exec'd it:
  // everyai-exec runs "/bin/sh <script>", perl's execvp "sh <script>".
  await _launcherProof();

  final sessions = _c.read(codeSessionsProvider.notifier);
  final project = _c.read(codeProjectsProvider).single;
  final info = await sessions.start(project: project, prompt: 'rig', model: 'local/rig', mode: AgentMode.auto);
  final id = info.id;
  final tag = info.processTag;
  _note('session $id (proc tag $tag, conversation ${info.conversationId})');
  final ctl = await _open(id);
  final s = (await _harness.inner.attach(info.conversationId)) as EveryAISession;

  final port = await _freePort();
  final run = _Runner(s);
  final first = await run.all(port, projectDir, 'first');
  if (first == null) return;
  await _stopAndProve(ctl, id, tag, first, port, 'Stop');

  // The same tools again: they come back.
  final port2 = await _freePort();
  final second = await run.all(port2, projectDir, 'after Stop');
  if (second != null) {
    final reused = second.pids.intersection(first.pids);
    _check('2 restart: new pids after Stop', reused.isEmpty && second.pids.isNotEmpty, {
      'first': first.pids.toList()..sort(),
      'second': second.pids.toList()..sort(),
      'reused': reused.toList(),
    });
    // Stop all, then delete.
    final o = await ctl.stopAll();
    final gone = await _goneAfter(second, port2, tag);
    _check('2 Stop all ends everything', o is Ended && gone.ok, {'outcome': '$o', ...gone.evidence});
  }
  final teardown = await sessions.remove(id);
  final left = await _tagged(tag);
  final owned = ProcessSupervisor.instance.children.where((c) => c.spec.owner.key == SessionOwner(tag).key).toList();
  _check('2 delete ends gone, nothing left', teardown is TeardownGone && left.isEmpty && owned.isEmpty, {
    'teardown': teardown.runtimeType.toString(),
    'tagged still running': left.toList(),
    'still listed': [for (final c in owned) '${c.spec.label} ${c.state}'],
    'session listed': sessions.byId(id) != null,
  });

  await _poolAndBudget(projectDir);

  // The app's quit sequence (what Cmd-Q runs), then out.
  final q = await _c.read(appQuitProvider).quit();
  final quitFile = File('$ledgerDir/quit.json');
  _check('quit after the rig: clean', q.clean, {
    'steps': [for (final (n, o) in q.steps) '$n: $o'],
    'quit.json': quitFile.existsSync() ? jsonDecode(quitFile.readAsStringSync()) : 'missing',
    'children left': ProcessSupervisor.instance.children.length,
  });
}

Future<T> _waitFor<T>(T? Function() read, Duration within) async {
  final until = DateTime.now().add(within);
  while (true) {
    final v = read();
    if (v != null) return v;
    if (DateTime.now().isAfter(until)) throw TimeoutException('waited $within');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

Future<CodeSessionController> _open(String id) async {
  _c.listen(codeSessionProvider(id), (_, _) {});
  await _waitFor(() => _c.read(codeSessionProvider(id)).connected ? true : null, const Duration(seconds: 30));
  return _c.read(codeSessionProvider(id).notifier);
}

Future<void> _launcherProof() async {
  final script = File('${_out.path}/argv_probe')
    ..writeAsStringSync('ps -o command= -p \$\$ > "\$1"\n'); // no #!: ENOEXEC
  await Process.run('chmod', ['+x', script.path]);
  Future<String> via(ProcessSupervisor sup, String name) async {
    final out = '${_out.path}/argv_$name.txt';
    final r = await sup.runBounded(script.path, [out], timeout: const Duration(seconds: 10), label: 'argv probe');
    return '${File(out).existsSync() ? File(out).readAsStringSync().trim() : 'no output'} ($r)';
  }

  final app = await via(ProcessSupervisor.instance, 'app');
  final perl = await via(ProcessSupervisor.create(hooks: const SupervisorHooks(launch: LaunchVia.perl)), 'perl');
  final bundle = '${File(Platform.resolvedExecutable).parent.path}/../Resources/everyai-exec';
  _check('1 the app supervisor launches through the bundle\'s everyai-exec', app.startsWith('/bin/sh ${script.path}'), {
    'app supervisor': app,
    'forced perl, for contrast': perl,
    'bundle helper': '$bundle exists=${File(bundle).existsSync()}',
    'EVERYAI_EXEC_HELPER': Platform.environment['EVERYAI_EXEC_HELPER'] ?? '(unset)',
    'cwd .tools helper':
        '${Directory.current.path}/.tools/everyai-exec exists='
        '${File('${Directory.current.path}/.tools/everyai-exec').existsSync()}',
    'resolvedExecutable': Platform.resolvedExecutable,
  });
}

/// One round of the session's tools.
typedef _Round = ({
  Set<int> pids,
  int? ampPid,
  List<SupervisedChild> children,
  String bgShell,
  Map<String, Object?> evidence,
});

final class _Runner {
  _Runner(this.s);
  final EveryAISession s;

  Future<_Round?> all(int port, String projectDir, String label) async {
    final ev = <String, Object?>{};
    // (a) a background server, and a foreground command that leaves a child behind with &.
    final bg = await s.runToolDirectly('bash', {
      'command': 'exec python3 -m http.server $port --bind 127.0.0.1',
      'run_in_background': true,
      'description': 'rig http server',
    });
    ev['bash bg'] = bg.text;
    final shellId = RegExp(r'bg_\d+').firstMatch(bg.text)?.group(0) ?? '';
    final amp = await s.runToolDirectly('bash', {
      'command': 'nohup sleep 900 >/dev/null 2>&1 & echo amp=\$!',
      'timeout': 15000,
    });
    ev['bash &'] = amp.text;
    final ampPid = int.tryParse(RegExp(r'amp=(\d+)').firstMatch(amp.text)?.group(1) ?? '');
    var up = false;
    for (var i = 0; i < 50 && !up; i++) {
      up = await _portOpen(port);
      if (!up) await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    ev['http up'] = up;
    // (b) the MCP server's tool.
    final echo = await s.runToolDirectly('rig_echo', {'text': label});
    ev['mcp call'] = echo.text;
    final mcpPid = int.tryParse(RegExp(r'pid:(\d+)').firstMatch(echo.text)?.group(1) ?? '');
    // (c) diagnostics on a Dart file.
    final diag = await s.runToolDirectly('diagnostics', {'path': 'bin/main.dart'});
    ev['diagnostics'] = _short(diag.text.replaceAll('\n', ' | '));
    // (d) the browser on (a)'s page.
    final open = await s.runToolDirectly('browser', {'action': 'open', 'url': 'http://127.0.0.1:$port/index.html'});
    ev['browser open'] = _short(open.text.replaceAll('\n', ' | '));
    final title = await s.runToolDirectly('browser', {'action': 'eval', 'script': 'document.title'});
    ev['browser title'] = _short(title.text.replaceAll('\n', ' | '));
    final tag = s.id; // only for logs
    ev['conversation'] = tag;

    final sup = ProcessSupervisor.instance;
    final info = _c.read(codeSessionsProvider).firstWhere((i) => i.conversationId == s.id);
    final key = SessionOwner(info.processTag).key;
    final children = [
      for (final c in sup.children)
        if (c.spec.owner.key == key) c,
    ];
    final t = await _ps();
    final tagged = await _tagged(info.processTag);
    final roots = {...children.map((c) => c.pid).nonNulls, ...tagged, ?ampPid, ?mcpPid};
    final all = _treeOf(t, roots);
    ev['supervised children'] = [for (final c in children) '${c.id} ${c.spec.kind.name} "${c.spec.label}" ${c.state}'];
    ev['ps'] = await _psLines(all);
    ev['shells'] = [for (final e in ShellRegistry.instance.of(info.processTag)) '${e.id} ${e.state}'];
    ev['browser lease'] = '${LivePool.sessionLease(info.id, ResourceKind.browser)?.state}';
    ev['browser page'] = LiveBrowsers.of(info.id) == null ? 'none' : 'open';
    final kinds = children.map((c) => c.spec.kind).toSet();
    final ok =
        up &&
        ampPid != null &&
        t.containsKey(ampPid) &&
        echo.text.contains('echo:$label pid:') &&
        !diag.isError &&
        title.text.contains('RigPage') &&
        kinds.contains(ProcessKind.mcp) &&
        kinds.contains(ProcessKind.lsp);
    _check('2 tools run ($label)', ok, ev);
    return (pids: all, ampPid: ampPid, children: children, bgShell: shellId, evidence: ev);
  }
}

Future<({bool ok, Map<String, Object?> evidence})> _goneAfter(_Round r, int port, String tag) async {
  // A moment for the OS to reap what was just killed.
  await Future<void>.delayed(const Duration(milliseconds: 500));
  final alive = await _psLines(r.pids);
  final tagged = await _tagged(tag);
  final states = {for (final c in r.children) '${c.spec.kind.name} "${c.spec.label}"': '${c.state}'};
  final liveStates = r.children.where((c) => c.state.live).toList();
  final port1 = await _portOpen(port);
  return (
    ok: alive.isEmpty && tagged.isEmpty && liveStates.isEmpty && !port1,
    evidence: <String, Object?>{
      'still running (ps)': alive,
      'still tagged': tagged.toList(),
      'child states': states,
      'http port still open': port1,
    },
  );
}

Future<void> _stopAndProve(CodeSessionController ctl, String id, String tag, _Round r, int port, String what) async {
  final page = LiveBrowsers.of(id);
  final sw = Stopwatch()..start();
  final o = await ctl.stop();
  sw.stop();
  final gone = await _goneAfter(r, port, tag);
  final lease = LivePool.sessionLease(id, ResourceKind.browser);
  final shells = [for (final e in ShellRegistry.instance.of(tag)) '${e.id} ${e.state}'];
  final shellsLive = ShellRegistry.instance.of(tag).where((e) => e.state is ShellRunning || e.state is ShellStopping);
  final notice = _c.read(codeSessionProvider(id)).notice;
  _check(
    '2 $what ends shells, & child, server, MCP, LSP, browser; lease released',
    o is Ended &&
        gone.ok &&
        lease == null &&
        LiveBrowsers.of(id) == null &&
        (page == null || !page.running) &&
        shellsLive.isEmpty &&
        notice == null,
    {
      'outcome': '$o',
      'took ms': sw.elapsedMilliseconds,
      ...gone.evidence,
      'shells': shells,
      'browser lease after': '$lease',
      'browser page after': LiveBrowsers.of(id) == null ? 'none' : 'open',
      'old page running': page?.running,
      'session notice': notice?.message,
      'bash_output of the old bg shell': r.bgShell.isEmpty
          ? 'no id'
          : _short(
              (await ((await _harness.inner.attach(
                _c.read(codeSessionsProvider.notifier).byId(id)!.conversationId,
              )) as EveryAISession).runToolDirectly('bash_output', {'shell_id': r.bgShell})).text.replaceAll(
                '\n',
                ' | ',
              ),
            ),
    },
  );
}

// ------------------------------------------------------------------ step 4

Future<void> _poolAndBudget(String projectDir) async {
  final sessions = _c.read(codeSessionsProvider.notifier);
  final project = _c.read(codeProjectsProvider).single;
  // Pool: one browser.
  _prefs['code.pool.browser'] = '1';
  await LivePool.configure((k) => _prefs[k]);
  LivePool.agentWait = const Duration(seconds: 3);
  final port = await _freePort();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  server.listen((req) {
    req.response.headers.contentType = ContentType.html;
    req.response.write('<!doctype html><title>Pool${req.uri.path}</title>');
    req.response.close();
  });
  final a = await sessions.start(project: project, prompt: 'pool A', model: 'local/rig', mode: AgentMode.auto);
  final b = await sessions.start(project: project, prompt: 'pool B', model: 'local/rig', mode: AgentMode.auto);
  final ca = await _open(a.id);
  await _open(b.id);
  final sa = (await _harness.inner.attach(a.conversationId)) as EveryAISession;
  final sb = (await _harness.inner.attach(b.conversationId)) as EveryAISession;
  final oa = await sa.runToolDirectly('browser', {'action': 'open', 'url': 'http://127.0.0.1:$port/a'});
  final sw = Stopwatch()..start();
  final ob = await sb.runToolDirectly('browser', {'action': 'open', 'url': 'http://127.0.0.1:$port/b'});
  final waited = sw.elapsedMilliseconds;
  final queued = ob.text;
  final leaseB = LivePool.sessionLease(b.id, ResourceKind.browser);
  _check(
    '4 pool: the second session is queued with its place and the holder',
    queued.contains('1') && queued.toLowerCase().contains('queue') && queued.contains('pool A'),
    {
      'capacity': LivePool.pool.capacity(ResourceKind.browser),
      'A open': _short(oa.text.replaceAll('\n', ' | ')),
      'B open': queued,
      'B waited ms': waited,
      'B lease': '${leaseB?.state}',
    },
  );
  await ca.stop();
  final ob2 = await sb.runToolDirectly('browser', {'action': 'eval', 'script': 'document.title'});
  final ob3 = ob2.text.contains('Pool')
      ? ob2
      : await sb.runToolDirectly('browser', {'action': 'open', 'url': 'http://127.0.0.1:$port/b'});
  _check('4 pool: after A releases, B is granted', !ob3.text.toLowerCase().contains('queue') && !ob3.isError, {
    'A lease after stop': '${LivePool.sessionLease(a.id, ResourceKind.browser)?.state}',
    'B lease': '${LivePool.sessionLease(b.id, ResourceKind.browser)?.state}',
    'B call': _short(ob3.text.replaceAll('\n', ' | ')),
    if (!identical(ob2, ob3)) 'B first call after release': _short(ob2.text.replaceAll('\n', ' | ')),
  });
  await server.close(force: true);
  for (final id in [a.id, b.id]) {
    await sessions.remove(id);
  }

  // Background shell cap.
  final c = await sessions.start(project: project, prompt: 'cap', model: 'local/rig', mode: AgentMode.auto);
  final cc = await _open(c.id);
  final sc = (await _harness.inner.attach(c.conversationId)) as EveryAISession;
  final outs = <String>[];
  for (var i = 1; i <= 17; i++) {
    final o = await sc.runToolDirectly('bash', {
      'command': 'exec sleep 600',
      'run_in_background': true,
      'description': 'cap $i',
    });
    outs.add(_short(o.text.replaceAll('\n', ' | ')));
  }
  final live = cc.backgroundTasks.where((t) => t.running).length;
  _check(
    '4 the 17th background shell is refused with the limit text',
    outs.last.contains('the most it may have (16)') && live == 16,
    {'16th': outs[15], '17th': outs[16], 'live background shells': live},
  );
  final capStop = await cc.stop();
  _note('cap session stop: $capStop');

  // Process budget.
  _prefs[processBudgetKey] = '12';
  final o = await sc.runToolDirectly('bash', {
    'command': 'for i in \$(seq 1 30); do sleep 600 & done; wait',
    'run_in_background': true,
    'description': 'fork 30',
  });
  _note('fork 30: ${o.text.split('\n').first}');
  final sw2 = Stopwatch()..start();
  SessionNotice? notice;
  while (sw2.elapsed < const Duration(seconds: 30)) {
    notice = _c.read(codeSessionProvider(c.id)).notice;
    if (notice is ProcessBudgetExceeded) break;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  sw2.stop();
  await Future<void>.delayed(const Duration(seconds: 1));
  final t = await _ps();
  final sleeps = [
    for (final r in t.values)
      if (r.command == 'sleep 600') r.pid,
  ];
  final tagged = await _tagged(c.processTag);
  final next = await sc.runToolDirectly('bash', {'command': 'echo after', 'timeout': 10000});
  _check('4 process budget stops the session and says why', notice is ProcessBudgetExceeded && tagged.isEmpty, {
    'budget': _prefs[processBudgetKey],
    'notice': '${notice?.runtimeType}: ${notice?.message}',
    'seen after ms': sw2.elapsedMilliseconds,
    'tagged left': tagged.toList(),
    'sleep 600 processes on the machine (any owner)': sleeps.length,
    'next tool result': _short(next.text.replaceAll('\n', ' | ')),
  });
  _prefs[processBudgetKey] = null;
  await sessions.remove(c.id);
}

// ------------------------------------------------------------------ step 3

Future<void> _life() async {
  _note('life mode; data folder $_data; app pid $pid');
  _makeContainer();
  final sup = ProcessSupervisor.instance;
  _c.read(appQuitProvider);
  final sweep = await _waitFor(() => sup.lastSweep.value, const Duration(seconds: 30));
  final ledgerDir = await sup.ledgerDirectory;
  final lastQuit = await _c.read(lastQuitProvider.future);
  File('${_out.path}/sweep-$pid.json').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'sweep': '$sweep',
      'previous run entries': [for (final e in sup.previousRunEntries) '$e'],
      'notice lines': [for (final l in launchNoticeLines(sweep, lastQuit)) '${l.bad ? '!' : ''}${l.text}'],
    }),
  );
  final shell = await sup.spawn(
    SpawnSpec(
      owner: const SessionOwner('life'),
      kind: ProcessKind.shell,
      exe: '/bin/sh',
      args: ['-c', 'sleep 900'],
      label: 'life shell',
    ),
  );
  final stubborn = await sup.spawn(
    SpawnSpec(
      owner: const SessionOwner('life'),
      kind: ProcessKind.helper,
      exe: '/bin/sh',
      args: ['-c', "trap '' TERM; sleep 901 & echo \$! > '${_out.path}/grandchild-$pid'; wait"],
      label: 'ignores TERM',
    ),
  );
  for (final c in [shell, stubborn]) {
    await c.landed;
  }
  var gc = 0;
  for (var i = 0; i < 50 && gc == 0; i++) {
    gc = int.tryParse(File('${_out.path}/grandchild-$pid').readAsStringSync().trim()) ?? 0;
    if (gc == 0) await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  String? watchdog;
  for (var i = 0; i < 50 && watchdog == null; i++) {
    final f = Directory(ledgerDir).listSync().whereType<File>().where((f) => f.path.contains('watchdog-$pid-'));
    if (f.isNotEmpty) watchdog = f.first.readAsStringSync().trim();
    if (watchdog == null) await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  final info = {
    'app': pid,
    'children': {'shell': shell.pid, 'ignores TERM': stubborn.pid, 'grandchild': gc},
    'watchdog': int.tryParse(watchdog ?? ''),
    'ledger dir': ledgerDir,
    'ps': await _psLines([shell.pid!, stubborn.pid!, gc, ?int.tryParse(watchdog ?? '')]),
  };
  File('${_out.path}/life.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(info));
  _note('alive: ${jsonEncode(info['children'])}, watchdog $watchdog');
}
