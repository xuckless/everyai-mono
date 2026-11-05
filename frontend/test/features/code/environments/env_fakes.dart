// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import 'package:every_ai/features/code/environments/discovery.dart';
import 'package:every_ai/features/code/environments/exec_env.dart';

/// A recorded command runner: answers by `exe args…`, and records every
/// call (with its environment). Unknown commands answer null, as a CLI that
/// didn't answer would.
final class FakeRunner {
  FakeRunner(this.answers);

  final Map<String, CommandResult?> answers;
  final calls = <String>[];
  final environments = <Map<String, String>>[];

  Future<CommandResult?> call(
    String exe,
    List<String> args, {
    Duration timeout = Duration.zero,
    Map<String, String> environment = const {},
  }) async {
    final key = [exe, ...args].join(' ');
    calls.add(key);
    environments.add(environment);
    return answers[key];
  }
}

CommandResult ok(String text, {int code = 0}) => (code: code, stdout: utf8.encode(text));

/// [text] as wsl.exe writes it: UTF-16LE, with a BOM when [bom].
List<int> utf16le(String text, {bool bom = true}) => [
  if (bom) ...[0xFF, 0xFE],
  for (final c in text.codeUnits) ...[c & 0xFF, c >> 8],
];

EnvironmentIo fakeIo(
  FakeRunner runner, {
  Map<String, String> clis = const {},
  HostOs os = HostOs.macos,
  String home = '/Users/a',
  Set<String> files = const {},
}) => EnvironmentIo(run: runner.call, which: (c) async => clis[c], os: os, home: home, exists: files.contains);

/// An environment for tests: paths under [hostRoot] on the host are under
/// [envRoot] inside, [wrap] is recorded and gives [bridge] with the
/// command after it (or [wrapWith]), [hostUrl] comes from [urls].
final class FakeEnv extends ExecEnv {
  FakeEnv({
    this.id = 'wsl:Ubuntu',
    this.kind = EnvKind.wsl,
    this.label = 'Ubuntu (WSL)',
    this.hostRoot = '/host',
    this.envRoot = '/env',
    this.bridge = '/usr/bin/bridge',
    this.wrapWith,
    this.urls,
  });

  @override
  final String id;
  @override
  final EnvKind kind;
  @override
  final String label;
  final String hostRoot;
  final String envRoot;
  final String bridge;
  final WrappedCommand Function(String executable, List<String> args, String? cwd, Map<String, String> env)? wrapWith;
  final Uri? Function(Uri loopback)? urls;
  final wraps = <({String executable, List<String> args, String? cwd, Map<String, String> env})>[];

  @override
  WrappedCommand wrap(String executable, List<String> args, {String? cwd, Map<String, String> env = const {}}) {
    wraps.add((executable: executable, args: args, cwd: cwd, env: env));
    return wrapWith?.call(executable, args, cwd, env) ??
        (
          executable: bridge,
          args: [
            if (cwd != null) ...['--cd', cwd],
            executable,
            ...args,
          ],
          environment: env,
        );
  }

  static String? _move(String p, String from, String to) =>
      p == from ? to : (p.startsWith('$from/') ? '$to${p.substring(from.length)}' : null);

  @override
  String? toEnvPath(String hostPath) => _move(hostPath, hostRoot, envRoot);

  @override
  String? toHostPath(String envPath) => _move(envPath, envRoot, hostRoot);

  @override
  Uri? hostUrl(Uri loopback) => urls == null ? loopback : urls!(loopback);
}
