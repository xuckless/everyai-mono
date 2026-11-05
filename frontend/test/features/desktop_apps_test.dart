import 'package:every_ai/features/code/drivers/detection/cli_scan.dart';
import 'package:every_ai/features/code/drivers/detection/desktop_apps.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fake disk: directory -> entries. Every listing and read is recorded.
final class _Disk {
  _Disk(this.dirs, [this.files = const {}]);
  final Map<String, List<String>> dirs;
  final Map<String, String> files;
  final listed = <String>[];
  final read = <String>[];
  List<String> list(String d) {
    listed.add(d);
    return dirs[d] ?? const [];
  }

  String? readFile(String p) {
    read.add(p);
    return files[p];
  }

  bool isFile(String p) => files.containsKey(p);
}

Future<AppScan> _scan(
  _Disk d,
  String os, {
  Map<String, String> env = const {},
  Future<String> Function(String, List<String>)? run,
}) => scanDesktopApps(
  os: os,
  home: os == 'windows' ? r'C:\Users\a' : '/home/a',
  env: env,
  listDir: d.list,
  readFile: d.readFile,
  run: run ?? (_, _) async => '',
);

List<String> _bundled(_Disk d, String command, {String os = 'macos'}) =>
    bundledCliPaths(command, os: os, home: '/home/a', env: const {}, listDir: d.list, isFile: d.isFile);

void main() {
  group('scanDesktopApps', () {
    test('macOS: finds apps by bundle name and skips the URL handler', () async {
      final d = _Disk({
        '/Applications': ['Claude.app', 'Cursor.app', 'Visual Studio Code.app', 'Safari.app'],
        '/home/a/Applications': ['Claude Code URL Handler.app'],
      });
      final scan = await _scan(d, 'macos');
      expect(scan.apps.keys, {DesktopApp.claude, DesktopApp.cursor, DesktopApp.vscode});
      expect(scan.apps[DesktopApp.claude], '/Applications/Claude.app');
    });

    test('Windows: folders under Programs and Program Files', () async {
      final d = _Disk({
        r'C:\L\Programs': ['Cursor', 'Other'],
        r'C:\PF': ['Microsoft VS Code', 'Antigravity'],
      });
      final scan = await _scan(d, 'windows', env: {'LOCALAPPDATA': r'C:\L', 'ProgramFiles': r'C:\PF'});
      expect(scan.apps.keys, {DesktopApp.cursor, DesktopApp.vscode, DesktopApp.antigravity});
    });

    test('Windows: reg query only when the folders found nothing', () async {
      final calls = <List<String>>[];
      Future<String> run(String exe, List<String> args) async {
        calls.add(args);
        return '    DisplayName    REG_SZ    Cursor (User)\n    DisplayName    REG_SZ    Microsoft Visual Studio Code\n';
      }

      final none = await _scan(_Disk({}), 'windows', env: {'LOCALAPPDATA': r'C:\L'}, run: run);
      expect(none.apps.keys, {DesktopApp.cursor, DesktopApp.vscode});
      expect(calls, isNotEmpty);
      calls.clear();
      await _scan(
        _Disk({
          r'C:\L\Programs': ['Claude'],
        }),
        'windows',
        env: {'LOCALAPPDATA': r'C:\L'},
        run: run,
      );
      expect(calls, isEmpty);
    });

    test('Linux: reads Name= of plausible desktop files only', () async {
      const dir = '/usr/share/applications';
      final d = _Disk(
        {
          dir: ['cursor.desktop', 'firefox.desktop', 'code.desktop', 'codex-notes.desktop'],
        },
        {
          '$dir/cursor.desktop': '[Desktop Entry]\nName=Cursor\nExec=cursor %F\n',
          '$dir/code.desktop': '[Desktop Entry]\nName=Visual Studio Code\n',
          '$dir/codex-notes.desktop': '[Desktop Entry]\nName=Notes\n',
          '$dir/firefox.desktop': 'Name=Firefox',
        },
      );
      final scan = await _scan(d, 'linux');
      expect(scan.apps.keys, {DesktopApp.cursor, DesktopApp.vscode});
      expect(d.read, isNot(contains('$dir/firefox.desktop')));
    });

    test('extension ids lose their version and platform; other extensions are not reported', () async {
      final d = _Disk({
        '/home/a/.vscode/extensions': [
          'anthropic.claude-code-2.1.3-darwin-arm64',
          'saoudrizwan.claude-dev-3.29.2',
          'ms-python.python-2024.1.0',
        ],
      });
      final scan = await _scan(d, 'linux');
      expect(scan.extensions, {'anthropic.claude-code', 'saoudrizwan.claude-dev'});
    });

    test('touches only listings, never config or token files', () async {
      final d = _Disk({
        '/Applications': ['Claude.app'],
      });
      await _scan(d, 'macos');
      expect(d.read, isEmpty);
      expect(
        d.listed.every((p) => p == '/Applications' || p.endsWith('Applications') || p.endsWith('extensions')),
        isTrue,
      );
    });

    test('an app only offers Set up, by its harness', () {
      const scan = AppScan(apps: {DesktopApp.claude: 'x'}, extensions: {'openai.chatgpt'});
      expect(scan.offersSetUp('claude-code'), isTrue);
      expect(scan.offersSetUp('codex'), isTrue);
      expect(scan.offersSetUp('opencode'), isFalse);
      expect(const AppScan(apps: {DesktopApp.vscode: 'x'}).offersSetUp('claude-code'), isFalse);
    });
  });

  group('bundledCliPaths', () {
    const base = '/home/a/Library/Application Support/Claude/claude-code';
    String bin(String v, String h) => '$base/$v/$h/claude.app/Contents/MacOS/claude';

    test('the highest version first, numerically; folders without a binary are ignored', () {
      final d = _Disk(
        {
          base: ['2.1.9', '2.1.10', '2.0.1'],
          '$base/2.1.9': ['h1'],
          '$base/2.1.10': ['h2'],
          '$base/2.0.1': ['h3'],
        },
        {bin('2.1.9', 'h1'): '', bin('2.1.10', 'h2'): ''},
      );
      expect(_bundled(d, 'claude'), [bin('2.1.10', 'h2'), bin('2.1.9', 'h1')]);
    });

    test('VS Code extension binaries are candidates too', () {
      const ext = '/home/a/.vscode/extensions';
      final d = _Disk(
        {
          ext: ['anthropic.claude-code-2.1.3-darwin-arm64', 'openai.chatgpt-0.4.0'],
          '$ext/openai.chatgpt-0.4.0/bin': ['macos-aarch64'],
        },
        {
          '$ext/anthropic.claude-code-2.1.3-darwin-arm64/resources/native-binary/claude': '',
          '$ext/openai.chatgpt-0.4.0/bin/macos-aarch64/codex': '',
        },
      );
      expect(_bundled(d, 'claude'), ['$ext/anthropic.claude-code-2.1.3-darwin-arm64/resources/native-binary/claude']);
      expect(_bundled(d, 'codex'), ['$ext/openai.chatgpt-0.4.0/bin/macos-aarch64/codex']);
      expect(_bundled(d, 'opencode'), isEmpty);
    });
  });

  group('findCli with bundled CLIs', () {
    Future<String?> find({required List<String> bundled, required bool Function(String) starts, String? onPath}) =>
        findCli(
          'claude',
          loadEnv: () async => {'PATH': '/bin'},
          windows: false,
          isFile: (p) => onPath != null && p == onPath,
          npmPrefix: (_) async => null,
          bundled: (_) => bundled,
          starts: (p) async => starts(p),
        );

    test('PATH wins over a bundled CLI', () async {
      expect(await find(onPath: '/bin/claude', bundled: ['/b/claude'], starts: (_) => true), '/bin/claude');
    });

    test('a bundled CLI counts only when --version starts', () async {
      expect(await find(bundled: ['/old/claude', '/new/claude'], starts: (p) => p == '/new/claude'), '/new/claude');
      expect(await find(bundled: ['/old/claude'], starts: (_) => false), isNull);
    });
  });
}
