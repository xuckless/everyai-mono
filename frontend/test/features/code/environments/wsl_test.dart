// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:every_ai/features/code/environments/bridges.dart';
import 'package:every_ai/features/code/environments/discovery.dart';
import 'package:flutter_test/flutter_test.dart';

import 'env_fakes.dart';

const _wsl = r'C:\Windows\System32\wsl.exe';

void main() {
  group('decodeWslOutput', () {
    test('UTF-16LE with a BOM and CRLF, Docker Desktop left out', () {
      expect(decodeWslOutput(utf16le('Ubuntu\r\ndocker-desktop\r\ndocker-desktop-data\r\nDebian\r\n\r\n')), [
        'Ubuntu',
        'Debian',
      ]);
    });
  });

  test('wrap runs --exec in --cd, with variables through WSLENV', () {
    const env = WslEnv(cli: _wsl, distro: 'Ubuntu', inheritedWslEnv: 'USERPROFILE/p');
    final w = env.wrap('claude', ['-p', 'a b'], cwd: '/home/u/my proj', env: {'EVERYAI_SESSION': 's1', 'TOKEN': 't'});
    expect(w.executable, _wsl);
    expect(w.args, ['-d', 'Ubuntu', '--cd', '/home/u/my proj', '--exec', 'claude', '-p', 'a b']);
    expect(w.environment, {'EVERYAI_SESSION': 's1', 'TOKEN': 't', 'WSLENV': 'USERPROFILE/p:EVERYAI_SESSION/u:TOKEN/u'});
    expect(env.wrap('ls', const []).environment, isEmpty);
    expect(env.toEnvPath(r'C:\p'), '/mnt/c/p');
    expect(env.hostUrl(Uri.parse('http://127.0.0.1:9/mcp')), isNull);
    expect(
      const WslEnv(cli: _wsl, distro: 'U', mirrored: true).hostUrl(Uri.parse('http://127.0.0.1:9/mcp')),
      Uri.parse('http://127.0.0.1:9/mcp'),
    );
  });
}
