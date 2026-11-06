import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:every_ai/features/code/panes/processes.dart';
import 'package:every_ai/features/code/shells/containers.dart';
import 'package:every_ai/features/code/shells/shell_log_io.dart';
import 'package:every_ai/features/code/shells/shell_registry.dart';
import 'package:every_ai/features/code/shells/shells_providers.dart';
import 'package:every_ai/features/code/ui/panes/processes_pane.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

ShellEntry _entry(String key, {int? pid, String session = 'grp', bool background = true, String? logPath}) =>
    ShellEntry(
      key: key,
      id: key.split('/').last,
      session: session,
      command: 'npm run dev',
      cwd: '/w',
      origin: ShellOrigin.agent,
      background: background,
      pid: pid,
      logPath: logPath,
    );

void main() {
  test('processes sit under the shell that started them; the rest are others', () {
    final shell = _entry('a/bg_1', pid: 100);
    final ended = _entry('a/bg_2', pid: 200)..endedAt = DateTime.now();
    final procs = [
      const SessionProcess(pid: 100, ppid: 1, command: 'zsh script', origin: ProcessOrigin.agent),
      const SessionProcess(pid: 101, ppid: 100, command: 'node vite', origin: ProcessOrigin.agent),
      const SessionProcess(pid: 102, ppid: 101, command: 'esbuild', origin: ProcessOrigin.agent),
      const SessionProcess(pid: 300, ppid: 1, command: 'zsh -l', origin: ProcessOrigin.terminal),
    ];
    final groups = groupByShell([shell, ended], procs);
    expect([for (final p in groups.first.processes) p.pid], [101, 102]);
    expect(groups.last.processes, isEmpty);
    expect([for (final p in otherProcesses(groups, procs)) p.pid], [300]);
  });

  test('tab ids carry the shell key', () {
    final id = shellTabId('s1', 'x/bg_2');
    expect(shellKeyOf(id), 'x/bg_2');
    expect(shellKeyOf('s1#2'), isNull);
  });

  test('a tab replays the log, then follows without repeating what the log had', () async {
    final tmp = await Directory.systemTemp.createTemp('shell-view');
    addTearDown(() => tmp.delete(recursive: true));
    final log = ShellLog('${tmp.path}/bg_1.log');
    final entry = _entry('v/bg_1', pid: 1, session: 'view-test', logPath: log.path);
    void out(String s) {
      final b = Uint8List.fromList(utf8.encode(s));
      log.add(b);
      entry.emit(b);
    }

    ShellRegistry.instance.add(entry);
    addTearDown(() => ShellRegistry.instance.forget('view-test'));
    out('first\r\n');
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final tab = shellTabId('view-test', entry.key);
    final view = container.read(shellViewProvider(tab).notifier)..start();
    out('second\r\n');
    final text = view.terminal.buffer.getText();
    expect(RegExp('first').allMatches(text).length, 1);
    expect(text, contains('second'));
    ShellRegistry.instance.ended(entry, 3);
    await Future<void>.delayed(Duration.zero);
    expect(view.terminal.buffer.getText(), contains('[Exited with code 3]'));
    log.close();
  });

  test('containers count by compose folder, bind mount, or an id the session saw', () {
    const json = """
[
 {"Id":"aaa111aaa111ffff","Name":"/web-1","Config":{"Image":"node:22","Labels":{"com.docker.compose.project.working_dir":"/w/app"}},
  "State":{"Status":"running"},"Mounts":[],"NetworkSettings":{"Ports":{"3000/tcp":[{"HostIp":"0.0.0.0","HostPort":"3000"},{"HostIp":"::","HostPort":"3000"}]}}},
 {"Id":"bbb222bbb222","Name":"/db","Config":{"Image":"postgres","Labels":{}},"State":{"Status":"running"},
  "Mounts":[{"Type":"bind","Source":"/w/app/data"}],"NetworkSettings":{"Ports":{}}},
 {"Id":"ccc333ccc333","Name":"/redis","Config":{"Image":"redis","Labels":{}},"State":{"Status":"running"},"Mounts":[]},
 {"Id":"ddd444ddd444","Name":"/other","Config":{"Image":"x","Labels":{"com.docker.compose.project.working_dir":"/w/application"}},
  "State":{"Status":"running"},"Mounts":[{"Type":"volume","Source":"/w/app"}]}
]""";
    final found = sessionContainersIn(json, worktree: '/w/app/', hints: {'redis'});
    expect([for (final c in found) c.name], ['web-1', 'db', 'redis']);
    expect(found.first.ports.map((p) => p.port).toSet(), {3000});
    expect(found.first.why, 'compose project in this folder');
    expect(found[1].why, 'mounts this folder');
    expect(found[2].why, 'started in this session');
    expect(sessionContainersIn('not json', worktree: '/w'), isEmpty);
  });

  test('container hints come from docker commands only', () {
    expect(containerHintsOf('docker run -d --name api nginx', '3f2a9c1b7d4e\n'), {'3f2a9c1b7d4e', 'api'});
    expect(containerHintsOf('echo 3f2a9c1b7d4e', '3f2a9c1b7d4e\n'), isEmpty);
  });
}
