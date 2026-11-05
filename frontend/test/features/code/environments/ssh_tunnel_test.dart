// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/code/environments/bridges.dart';
import 'package:every_ai/features/code/environments/ssh_tunnel.dart';
import 'package:every_ai/features/code/environments/ssh_tunnel_io.dart' as io;
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// ssh as the test plays it: what it writes to stderr, and whether it was killed.
final class _FakeSsh implements Process {
  final _err = StreamController<List<int>>();
  final _exit = Completer<int>();
  var killed = false;

  void say(String line) => _err.add(utf8.encode('$line\n'));
  Future<void> quit() async {
    await _err.close();
    if (!_exit.isCompleted) _exit.complete(255);
  }

  @override
  Stream<List<int>> get stderr => _err.stream;
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  IOSink get stdin => IOSink(StreamController<List<int>>().sink);
  @override
  Future<int> get exitCode => _exit.future;
  @override
  int get pid => 42;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    if (!_exit.isCompleted) _exit.complete(-15);
    return true;
  }
}

void main() {
  const env = SshEnv(
    cli: '/usr/bin/ssh',
    remote: SshRemote.host(user: 'me', host: 'box', port: 2222),
  );

  test('the remote picks the port; the forward goes to loopback here only', () {
    expect(sshTunnelArgs(env.remote, 5123), [
      '-N',
      '-T',
      '-o',
      'BatchMode=yes',
      '-o',
      'ExitOnForwardFailure=yes',
      '-o',
      'ConnectTimeout=5',
      '-p',
      '2222',
      '-R',
      '0:127.0.0.1:5123',
      '--',
      'me@box',
    ]);
    expect(allocatedPort('Allocated port 40123 for remote forward to 127.0.0.1:5123'), 40123);
    expect(allocatedPort('Warning: Permanently added box'), isNull);
  });

  test('opens with the port ssh printed and closes by ending ssh', () async {
    final ssh = _FakeSsh();
    final started = <String>[];
    final opening = io.openSshTunnel(
      env,
      5123,
      start: (exe, args) async {
        started.add('$exe ${args.last}');
        return ssh;
      },
    );
    ssh
      ..say('Warning: Permanently added box')
      ..say('Allocated port 40123 for remote forward to 127.0.0.1:5123');
    final tunnel = await opening;
    expect(started, ['/usr/bin/ssh me@box']);
    expect(tunnel.remotePort, 40123);
    expect(ssh.killed, isFalse);
    await tunnel.close();
    expect(ssh.killed, isTrue);
  });

  test('an ssh that ends without a forward says what it said', () async {
    final ssh = _FakeSsh();
    final opening = io.openSshTunnel(env, 5123, start: (_, _) async => ssh);
    ssh.say('Permission denied (publickey).');
    unawaited(ssh.quit());
    await expectLater(
      opening,
      throwsA(isA<HarnessError>().having((e) => e.message, 'message', contains('Permission denied'))),
    );
  });
}
