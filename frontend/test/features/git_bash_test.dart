import 'dart:io';

import 'package:every_ai/features/code/harness/everyai/git_bash.dart';
import 'package:every_ai/features/code/harness/everyai/shell_io.dart';
import 'package:every_ai/features/code/panes/pty_io.dart' show terminalShell;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('findGitBash', () {
    String? find(Map<String, String> env, Set<String> files) => findGitBash(env, files.contains);

    test('finds the all-users install, 64-bit before x86', () {
      expect(
        find({'ProgramFiles': r'C:\Program Files'}, {r'C:\Program Files\Git\bin\bash.exe'}),
        r'C:\Program Files\Git\bin\bash.exe',
      );
      expect(
        find(
          {'ProgramW6432': r'C:\Program Files', 'ProgramFiles(x86)': r'C:\Program Files (x86)'},
          {r'C:\Program Files\Git\bin\bash.exe', r'C:\Program Files (x86)\Git\bin\bash.exe'},
        ),
        r'C:\Program Files\Git\bin\bash.exe',
      );
    });

    test('finds the per-user install and Scoop', () {
      expect(
        find({'LOCALAPPDATA': r'C:\Users\x\AppData\Local'}, {r'C:\Users\x\AppData\Local\Programs\Git\bin\bash.exe'}),
        r'C:\Users\x\AppData\Local\Programs\Git\bin\bash.exe',
      );
      expect(
        find({'USERPROFILE': r'C:\Users\x'}, {r'C:\Users\x\scoop\apps\git\current\bin\bash.exe'}),
        r'C:\Users\x\scoop\apps\git\current\bin\bash.exe',
      );
    });

    test('follows git.exe on PATH from cmd, mingw64\\bin and bin', () {
      expect(
        find({'PATH': r'C:\Windows;D:\Tools\Git\cmd'}, {r'D:\Tools\Git\cmd\git.exe', r'D:\Tools\Git\bin\bash.exe'}),
        r'D:\Tools\Git\bin\bash.exe',
      );
      expect(
        find({'PATH': r'D:\Git\mingw64\bin\'}, {r'D:\Git\mingw64\bin\git.exe', r'D:\Git\bin\bash.exe'}),
        r'D:\Git\bin\bash.exe',
      );
      expect(find({'PATH': r'D:\Git\bin'}, {r'D:\Git\bin\git.exe', r'D:\Git\bin\bash.exe'}), r'D:\Git\bin\bash.exe');
    });

    test('matches env keys in any case', () {
      expect(find({'Path': r'E:\Git\cmd'}, {r'E:\Git\cmd\git.exe', r'E:\Git\bin\bash.exe'}), r'E:\Git\bin\bash.exe');
      expect(find({'PROGRAMFILES': r'C:\PF'}, {r'C:\PF\Git\bin\bash.exe'}), r'C:\PF\Git\bin\bash.exe');
    });

    test('never returns the WSL launchers', () {
      expect(
        find(
          {'SystemRoot': r'C:\Windows', 'PATH': r'C:\Windows\System32;C:\Users\x\AppData\Local\Microsoft\WindowsApps'},
          {
            r'C:\Windows\System32\git.exe',
            r'C:\Windows\System32\bash.exe',
            r'C:\Users\x\AppData\Local\Microsoft\WindowsApps\git.exe',
            r'C:\Users\x\AppData\Local\Microsoft\WindowsApps\bash.exe',
          },
        ),
        isNull,
      );
    });

    test('null when Git for Windows is not installed', () {
      expect(find({'ProgramFiles': r'C:\Program Files', 'PATH': r'C:\Windows'}, {}), isNull);
    });
  });

  group('wrapper script', () {
    test('Windows: forward-slash cd, quotes kept, pwd -W', () {
      final s = wrapScript('ls', cwd: r"C:\Users\o'n\p", cwdFile: r'C:\tmp\sh/.cwd-1', windows: true);
      expect(s, startsWith("cd 'C:/Users/o'\\''n/p' 2>/dev/null || cd ~\n"));
      expect(s, contains("{ pwd -W 2>/dev/null || pwd -P; } > 'C:/tmp/sh/.cwd-1' 2>/dev/null\n"));
    });

    test('elsewhere: the same text as before', () {
      expect(
        wrapScript('ls', cwd: "/p/o'n", cwdFile: '/s/.cwd-1', windows: false),
        "cd '/p/o'\\''n' 2>/dev/null || cd ~\n"
        '{\nls\n} < /dev/null 2>&1\n'
        '__everyai_status=\$?\n'
        "pwd -P > '/s/.cwd-1' 2>/dev/null\n"
        'exit \$__everyai_status\n',
      );
    });

    test('the recorded directory comes back in Windows form', () {
      expect(cwdFromFile('C:/Users/x/p\n', windows: true), r'C:\Users\x\p');
      expect(cwdFromFile('/Users/x/p\n', windows: false), '/Users/x/p');
    });
  });

  group('no shell', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('gitbash');
      ShellEnv.debugUse(ShellEnv.test('', const {'PATH': ''}));
    });
    tearDown(() {
      ShellEnv.debugUse(null);
      tmp.deleteSync(recursive: true);
    });

    test('commands answer with the install hint', () async {
      final shell = SessionShell(root: tmp.path, sessionTag: 't', scratchDir: '${tmp.path}/sh');
      final res = await shell.run('ls', timeout: const Duration(seconds: 5));
      expect(res.exitCode, 127);
      expect(res.output, gitBashMissingMessage);
      await expectLater(
        shell.start('ls'),
        throwsA(isA<ShellMissing>().having((e) => e.toString(), 'message', gitBashMissingMessage)),
      );
    });
  });

  group('script file', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('shellfile'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('cd carries over, the script is removed, long commands run', () async {
      Directory('${tmp.path}/sub').createSync();
      final shell = SessionShell(root: tmp.path, sessionTag: 't', scratchDir: '${tmp.path}/.sh');
      expect((await shell.run('cd sub', timeout: const Duration(seconds: 20))).exitCode, 0);
      expect(shell.cwd, endsWith('/sub'));
      expect(Directory('${tmp.path}/.sh').listSync().where((e) => e.path.contains('.cmd-')), isEmpty);
      final long = 'x' * 40000;
      final res = await shell.run("printf '%s' '$long' | wc -c", timeout: const Duration(seconds: 20));
      expect(res.output.trim(), '40000');
    });
  });

  group('terminalShell', () {
    test('Windows with Git Bash: a login shell that stays in the folder', () {
      final t = terminalShell(windows: true, gitBash: r'C:\Git\bin\bash.exe');
      expect(t.exe, r'C:\Git\bin\bash.exe');
      expect(t.args, ['--login', '-i']);
      expect(t.env['CHERE_INVOKING'], '1');
    });

    test('Windows without Git Bash: PowerShell', () {
      final t = terminalShell(windows: true);
      expect((t.exe, t.args.join(' ')), ('powershell.exe', '-NoLogo'));
    });

    test('macOS: \$SHELL when it exists, else zsh', () {
      final set = terminalShell(windows: false, shellVar: '/opt/fish', exists: (_) => true, macOS: true);
      expect((set.exe, set.args.join(' '), set.env['TERM']), ('/opt/fish', '-l', 'xterm-256color'));
      final unset = terminalShell(windows: false, exists: (_) => false, macOS: true);
      expect((unset.exe, unset.args.join(' ')), ('/bin/zsh', '-l'));
    });
  });
}
