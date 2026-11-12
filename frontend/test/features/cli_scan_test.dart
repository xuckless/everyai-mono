import 'package:every_ai/features/code/drivers/detection/cli_scan.dart';
import 'package:every_ai/features/code/environments/exec_env.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Wsl extends ExecEnv {
  const _Wsl();
  @override
  String get id => 'wsl:Ubuntu';
  @override
  EnvKind get kind => EnvKind.wsl;
  @override
  String get label => 'Ubuntu (WSL)';
  @override
  WrappedCommand wrap(String executable, List<String> args, {String? cwd, Map<String, String> env = const {}}) =>
      (executable: 'wsl.exe', args: ['-d', 'Ubuntu', '--', executable, ...args], environment: const {});
  @override
  String? toEnvPath(String hostPath) => null;
  @override
  String? toHostPath(String envPath) => null;
}

void main() {
  group('findCli on this computer', () {
    var probes = 0;
    Future<String?> prefix(Map<String, String> _) async {
      probes++;
      return '/npm';
    }

    Future<String?> find(
      Set<String> files, {
      Map<String, String>? env,
      Future<String?> Function(Map<String, String>)? npm,
      bool windows = false,
      List<String> Function(String)? list,
    }) => findCli(
      'tool',
      loadEnv: () async => env ?? {'PATH': '/bin:/usr/bin'},
      windows: windows,
      isFile: files.contains,
      list: list,
      npmPrefix: npm ?? prefix,
    );

    setUp(() => probes = 0);

    test('a PATH hit wins and never asks npm', () async {
      expect(await find({'/usr/bin/tool', '/npm/bin/tool'}), '/usr/bin/tool');
      expect(probes, 0);
    });

    test('Windows looks in the Programs folders, with PATHEXT', () async {
      const programs = r'C:\L\Programs';
      final found = await find(
        {'$programs\\Tool\\bin\\tool.EXE'},
        env: {'Path': r'C:\Windows', 'LOCALAPPDATA': r'C:\L'},
        windows: true,
        list: (d) => d == programs ? ['Other', 'Tool'] : [],
        npm: (_) async => null,
      );
      expect(found, r'C:\L\Programs\Tool\bin\tool.EXE');
    });
  });

  group('findCli in another environment', () {
    test('one login-shell line runs there and its path is returned', () async {
      final ran = <List<String>>[];
      final found = await findCli(
        'claude',
        env: const _Wsl(),
        run: (exe, args) async {
          ran.add([exe, ...args]);
          return '__EVERYAI_CLI__\n/home/u/.claude/local/claude\n';
        },
      );
      expect(found, '/home/u/.claude/local/claude');
      expect(ran, hasLength(1));
      expect(ran.single.take(6), ['wsl.exe', '-d', 'Ubuntu', '--', 'sh', '-lc']);
      expect(ran.single.last, 'claude');
      expect(ran.single.join(' '), allOf(contains('command -v'), contains(r'$HOME/.opencode/bin')));
    });
  });
}
