// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import 'package:every_ai/features/code/environments/bridges.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('wrap: one remote line, BatchMode and a connect timeout', () {
    const env = SshEnv(
      cli: '/usr/bin/ssh',
      remote: SshRemote.host(user: 'me', host: 'example.com', port: 2222),
    );
    expect(env.id, 'ssh:me@example.com:2222');
    expect(env.label, 'example.com (SSH)');
    final w = env.wrap('claude', ['-p', r"it's $HOME"], cwd: '/srv/my app', env: {'K': 'v w'});
    expect(w.args, [
      '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', '-p', '2222', '--', 'me@example.com', //
      sshRemoteLine(r"cd '/srv/my app' && exec env 'K=v w' claude -p 'it'\''s $HOME'"),
    ]);
    final line = w.args.last;
    expect(line, startsWith("exec /bin/sh -c 'eval "));
    // Nothing a login shell would read differently inside the quotes.
    expect(line.contains('\\') || line.contains('\n') || line.substring(17, line.length - 1).contains("'"), isFalse);
    final b64 = RegExp(r'printf %s (\S+) \|').firstMatch(line)!.group(1)!;
    expect(utf8.decode(base64.decode(b64)), r"cd '/srv/my app' && exec env 'K=v w' claude -p 'it'\''s $HOME'");
    expect(env.toEnvPath('/x'), isNull);
    expect(env.toHostPath('/x'), isNull);
    expect(env.hostUrl(Uri.parse('http://127.0.0.1:1')), isNull);
    expect(
      () => const SshEnv(cli: '/usr/bin/ssh', remote: SshRemote.alias('-oProxyCommand=x')).wrap('ls', const []),
      throwsArgumentError,
    );
  });

  // What sshd does with the line: the remote user's login shell runs it with
  // -c. csh allows no newline inside quotes and fish reads \\ and \' there,
  // so the line must mean the same to each.
}
