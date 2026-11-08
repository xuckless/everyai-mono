// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io';

import 'package:every_ai/features/code/harness/everyai/lsp_io.dart';
import 'package:flutter_test/flutter_test.dart';

/// A language server stand-in: answers initialize (after DELAY seconds) and shutdown, publishes no findings, exits on
/// `exit`, and starts a child that lives until killed (as the TypeScript server's tsserver does), writing its pid.
const _server = r'''#!/usr/bin/env python3
import json, os, subprocess, sys, time
child = subprocess.Popen(['sleep', '300'])
open(os.environ['CHILD_PIDS'], 'a').write(f'{child.pid}\n')
def read():
    length = 0
    while True:
        line = sys.stdin.buffer.readline()
        if not line: sys.exit(0)
        if line in (b'\r\n', b'\n'): break
        if line.lower().startswith(b'content-length:'): length = int(line.split(b':')[1])
    return json.loads(sys.stdin.buffer.read(length))
def send(m):
    b = json.dumps(m).encode()
    sys.stdout.buffer.write(b'Content-Length: %d\r\n\r\n' % len(b) + b); sys.stdout.buffer.flush()
while True:
    m = read()
    if m.get('method') == 'initialize':
        time.sleep(float(os.environ.get('DELAY', '0')))
        send({'jsonrpc': '2.0', 'id': m['id'], 'result': {'capabilities': {}}})
    elif m.get('method') == 'shutdown':
        if os.environ.get('ORPHAN') != '1': child.kill()
        send({'jsonrpc': '2.0', 'id': m['id'], 'result': None})
    elif m.get('method') == 'exit':
        sys.exit(0)
    elif m.get('method') == 'textDocument/didOpen':
        d = m['params']['textDocument']
        send({'jsonrpc': '2.0', 'method': 'textDocument/publishDiagnostics', 'params': {'uri': d['uri'], 'version': d['version'], 'diagnostics': []}})
''';

void main() {
  late Directory tmp;
  late File pids;
  Map<String, String> env({double delay = 0, bool orphan = false}) => {
    ...Platform.environment,
    'PATH': '${tmp.path}/bin:/usr/bin:/bin',
    'CHILD_PIDS': pids.path,
    'DELAY': '$delay',
    'ORPHAN': orphan ? '1' : '0',
  };
  LspHub hub(String name, {double delay = 0, bool orphan = false}) {
    final root = Directory('${tmp.path}/$name')..createSync();
    final h = LspHub(
      root: root.path,
      toolsDir: '${tmp.path}/tools',
      environment: () async => env(delay: delay, orphan: orphan),
    );
    addTearDown(h.close);
    return h;
  }

  File cFile(LspHub h) => File('${h.root}/main.c')..writeAsStringSync('int main(void) { return 0; }\n');
  bool alive(int pid) => Process.runSync('kill', ['-0', '$pid']).exitCode == 0;
  List<int> childPids() => [for (final l in pids.readAsLinesSync()) int.parse(l)];

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lsp_life');
    pids = File('${tmp.path}/pids')..createSync();
    Directory('${tmp.path}/bin').createSync();
    for (final name in ['clangd', 'gopls']) {
      File('${tmp.path}/bin/$name').writeAsStringSync(_server);
      Process.runSync('chmod', ['+x', '${tmp.path}/bin/$name']);
    }
  });
  tearDown(() async {
    await LspHub.closeAll();
    LspHub.maxRunningServers = 4;
    LspHub.serverIdle = const Duration(minutes: 10);
    LspHub.evictWait = const Duration(seconds: 20);
    for (final p in childPids()) {
      Process.killPid(p, ProcessSignal.sigkill);
    }
    await tmp.delete(recursive: true);
  });

  test('the phase table', () {
    expect(nextLspPhase(LspPhase.notStarted, LspEvent.use), LspPhase.starting);
    expect(nextLspPhase(LspPhase.stopped, LspEvent.use), LspPhase.starting);
    expect(nextLspPhase(LspPhase.starting, LspEvent.up), LspPhase.ready);
    expect(nextLspPhase(LspPhase.starting, LspEvent.fail), LspPhase.failed);
    for (final e in [LspEvent.idle, LspEvent.evicted, LspEvent.close]) {
      expect(nextLspPhase(LspPhase.ready, e), LspPhase.stopping);
      expect(nextLspPhase(LspPhase.starting, e), LspPhase.stopping);
    }
    expect(nextLspPhase(LspPhase.stopping, LspEvent.gone), LspPhase.stopped);
    expect(nextLspPhase(LspPhase.ready, LspEvent.died), LspPhase.stopped);
    expect(nextLspPhase(LspPhase.failed, LspEvent.use), isNull);
    expect(nextLspPhase(LspPhase.ready, LspEvent.use), isNull);
  });

  test('closing a hub ends each server and the children it started', () async {
    final h = hub('a');
    expect(await h.check(cFile(h).path), isEmpty);
    expect(h.phaseOf(LspLanguage.cpp), LspPhase.ready);
    final child = childPids().single;
    expect(alive(child), isTrue);
    await h.close();
    expect(h.phaseOf(LspLanguage.cpp), LspPhase.stopped);
    expect(LspHub.runningServers, 0);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(alive(child), isFalse);
  }, skip: Platform.isWindows);

  test(
    'at most maxRunningServers run across sessions: the least recently used stops, and starts again on use',
    () async {
      LspHub.maxRunningServers = 2;
      final hubs = [hub('a'), hub('b'), hub('c')];
      for (final h in hubs) {
        expect(await h.check(cFile(h).path), isEmpty);
      }
      expect(LspHub.runningServers, 2);
      expect(hubs.map((h) => h.phaseOf(LspLanguage.cpp)), [LspPhase.stopped, LspPhase.ready, LspPhase.ready]);
      expect(await hubs.first.check(cFile(hubs.first).path), isEmpty);
      expect(hubs.map((h) => h.phaseOf(LspLanguage.cpp)), [LspPhase.ready, LspPhase.stopped, LspPhase.ready]);
    },
    skip: Platform.isWindows,
  );

  test('an idle server stops by itself', () async {
    LspHub.serverIdle = const Duration(milliseconds: 300);
    final h = hub('a');
    await h.check(cFile(h).path);
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(h.phaseOf(LspLanguage.cpp), LspPhase.stopped);
    expect(LspHub.runningServers, 0);
  }, skip: Platform.isWindows);

  test('a hub closed while its server starts ends that server when it lands', () async {
    final h = hub('a', delay: 0.8);
    final check = h.check(cFile(h).path);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(h.phaseOf(LspLanguage.cpp), LspPhase.starting);
    await h.close();
    expect(h.phaseOf(LspLanguage.cpp), LspPhase.stopped);
    expect(await check, isNull);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(LspHub.runningServers, 0);
    expect(childPids().where(alive), isEmpty);
  }, skip: Platform.isWindows);

  test('a child the server leaves running after a clean exit is still ended (it was listed before)', () async {
    final h = hub('a', orphan: true);
    expect(await h.check(cFile(h).path), isEmpty);
    final child = childPids().single;
    await h.close();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(alive(child), isFalse);
  }, skip: Platform.isWindows);

  test('a burst of starts keeps to the cap (a start holds its place while it starts)', () async {
    LspHub.maxRunningServers = 2;
    final hubs = [
      for (final n in ['a', 'b', 'c', 'd']) hub(n, delay: 0.3),
    ];
    var peak = 0;
    var done = false;
    final watch = () async {
      while (!done) {
        final n = Process.runSync('pgrep', ['-f', '${tmp.path}/bin/clangd']).stdout.toString().trim();
        final count = n.isEmpty ? 0 : n.split('\n').length;
        if (count > peak) peak = count;
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    }();
    await Future.wait([for (final h in hubs) h.check(cFile(h).path)]);
    done = true;
    await watch;
    expect(LspHub.runningServers, lessThanOrEqualTo(2));
    expect(peak, lessThanOrEqualTo(2));
  }, skip: Platform.isWindows);

  test('closeAll (quit) also ends a server that is still starting', () async {
    final h = hub('a', delay: 0.8);
    final check = h.check(cFile(h).path);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await LspHub.closeAll();
    expect(await check, isNull);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(childPids().where(alive), isEmpty);
    expect(Process.runSync('pgrep', ['-f', '${tmp.path}/bin/clangd']).exitCode, isNot(0));
  }, skip: Platform.isWindows);
}
