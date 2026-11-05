// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:every_ai/features/code/environments/bridges.dart';
import 'package:every_ai/features/code/environments/discovery.dart';
import 'package:every_ai/features/code/environments/path_maps.dart';
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

    test('UTF-16LE without a BOM', () {
      expect(decodeWslOutput(utf16le('Ubuntu-22.04\r\n', bom: false)), ['Ubuntu-22.04']);
    });

    test('UTF-8 when the CLI answers in it', () {
      expect(decodeWslOutput(ok('Ubuntu\nkali-linux\n').stdout), ['Ubuntu', 'kali-linux']);
    });
  });

  group('discovery', () {
    test('every distro, with the running ones marked', () async {
      final runner = FakeRunner({
        '$_wsl -l -q': (code: 0, stdout: utf16le('Ubuntu\r\ndocker-desktop\r\nDebian\r\n')),
        '$_wsl -l -q --running': (code: 0, stdout: utf16le('Ubuntu\r\n')),
      });
      final found = await discoverEnvironments(fakeIo(runner, os: HostOs.windows, clis: {'wsl.exe': _wsl}));
      final wsl = found.environments.whereType<WslEnv>().toList();
      expect(
        [for (final e in wsl) (e.id, e.label, e.running)],
        [('wsl:Ubuntu', 'Ubuntu (WSL)', true), ('wsl:Debian', 'Debian (WSL)', false)],
      );
      expect(runner.environments.first, {'WSL_UTF8': '0'});
      expect(found.problems, isEmpty);
    });

    test('no distros installed (non-zero exit) is no environment and no problem', () async {
      final runner = FakeRunner({'$_wsl -l -q': (code: 1, stdout: utf16le('No installed distributions.'))});
      final found = await discoverEnvironments(fakeIo(runner, os: HostOs.windows, clis: {'wsl.exe': _wsl}));
      expect(found.environments.whereType<WslEnv>(), isEmpty);
      expect(found.problems, isEmpty);
    });

    test('never looked for off Windows', () async {
      final runner = FakeRunner({});
      await discoverEnvironments(fakeIo(runner, os: HostOs.macos, clis: {'wsl.exe': _wsl}));
      expect(runner.calls, isEmpty);
    });
  });

  group('paths', () {
    const d = 'Ubuntu';
    test('Windows → WSL', () {
      expect(wslToEnvPath(r'C:\Users\a b\x', distro: d), '/mnt/c/Users/a b/x');
      expect(wslToEnvPath('d:/', distro: d), '/mnt/d/');
      expect(wslToEnvPath('C:', distro: d), '/mnt/c');
      expect(wslToEnvPath(r'C:\x', distro: d, root: '/win'), '/win/c/x');
      expect(wslToEnvPath(r'\\wsl$\Ubuntu\home\u', distro: d), '/home/u');
      expect(wslToEnvPath(r'\\wsl.localhost\ubuntu\home\u', distro: d), '/home/u');
      expect(wslToEnvPath('//wsl.localhost/Ubuntu', distro: d), '/');
      expect(wslToEnvPath(r'\\wsl$\Debian\home\u', distro: d), isNull);
      expect(wslToEnvPath(r'\\server\share\x', distro: d), isNull);
      expect(wslToEnvPath('relative', distro: d), isNull);
    });

    test('WSL → Windows', () {
      expect(wslToHostPath('/mnt/c/Users/a b/x', distro: d), r'C:\Users\a b\x');
      expect(wslToHostPath('/mnt/d/', distro: d), r'D:\');
      expect(wslToHostPath('/mnt/c', distro: d), r'C:\');
      expect(wslToHostPath('/win/c/x', distro: d, root: '/win/'), r'C:\x');
      expect(wslToHostPath('/home/u', distro: d), r'\\wsl.localhost\Ubuntu\home\u');
      expect(wslToHostPath('/mnt/cx/y', distro: d), r'\\wsl.localhost\Ubuntu\mnt\cx\y');
      expect(wslToHostPath('x', distro: d), isNull);
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
