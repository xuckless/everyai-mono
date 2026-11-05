// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../harness/harness.dart' show HarnessError;
import 'bridges.dart' show SshEnv;
import 'ssh_tunnel.dart';

Future<SshTunnel> openSshTunnel(
  SshEnv env,
  int localPort, {
  @visibleForTesting Future<Process> Function(String executable, List<String> args)? start,
  Duration timeout = const Duration(seconds: 20),
}) async {
  if (env.remote.problem case final why?) throw HarnessError(why);
  final process = await (start ?? Process.start)(env.cli, sshTunnelArgs(env.remote, localPort));
  unawaited(process.stdin.close().then((_) {}, onError: (Object _) {}));
  unawaited(process.stdout.drain<void>().then((_) {}, onError: (Object _) {}));
  final allocated = Completer<int?>();
  final said = StringBuffer();
  // Read to the end, so ssh never blocks on a full stderr pipe.
  process.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .listen(
        (line) {
          if (allocated.isCompleted) return;
          if (allocatedPort(line) case final port?) return allocated.complete(port);
          if (said.length < 1000) said.writeln(line);
        },
        onDone: () {
          if (!allocated.isCompleted) allocated.complete(null);
        },
        onError: (Object _) {},
      );
  final port = await allocated.future.timeout(timeout, onTimeout: () => null);
  if (port == null) {
    process.kill();
    final why = said.toString().trim();
    throw HarnessError("Couldn't open a tunnel to ${env.label}${why.isEmpty ? '.' : ': $why'}");
  }
  return _Tunnel(process, port);
}

final class _Tunnel implements SshTunnel {
  _Tunnel(this._process, this.remotePort);

  final Process _process;
  @override
  final int remotePort;

  @override
  Future<void> close() async {
    _process.kill();
    await _process.exitCode;
  }
}
