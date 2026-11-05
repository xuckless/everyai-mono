import 'package:every_ai/features/code/drivers/detection/cli_scan.dart';
import 'package:every_ai/features/code/drivers/detection/cli_state.dart';
import 'package:every_ai/features/code/drivers/driver.dart';
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
  ({String executable, List<String> args}) wrap(
    String executable,
    List<String> args, {
    String? cwd,
    Map<String, String> env = const {},
  }) => (executable: 'wsl.exe', args: ['-d', 'Ubuntu', '--', executable, ...args]);
  @override
  String? toEnvPath(String hostPath) => null;
  @override
  String? toHostPath(String envPath) => null;
}

void main() {
  group('cliStateOf', () {
    test('absent, or Set up when the desktop app is there', () {
      expect(cliStateOf(const DriverStatus()), CliState.absent);
      expect(cliStateOf(const DriverStatus(), appFound: true), CliState.setUp);
      // A check that timed out is not installed; never offered on a guess.
      expect(cliStateOf(const DriverStatus(problem: 'timed out')), CliState.absent);
    });

    test('sign in only when the CLI says it is signed out', () {
      expect(cliStateOf(const DriverStatus(installed: true, signedIn: false)), CliState.signIn);
      expect(cliStateOf(const DriverStatus(installed: true, signedIn: true)), CliState.ready);
      expect(cliStateOf(const DriverStatus(installed: true)), CliState.ready);
      expect(cliStateOf(const DriverStatus(installed: true, problem: 'too old')), CliState.ready);
      expect(cliStateOf(const DriverStatus(installed: true), appFound: true), CliState.ready);
    });
  });

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

    test('the real npm prefix is the last place', () async {
      expect(await find({'/npm/bin/tool'}), '/npm/bin/tool');
      expect(await find({}), isNull);
    });

    test('npm is asked once per captured environment', () async {
      final env = {'PATH': '/bin'};
      await find({}, env: env);
      await find({}, env: env);
      expect(probes, 1);
      await find({}, env: {'PATH': '/bin'});
      expect(probes, 2);
    });

    test('a failed npm probe is a plain miss', () async {
      expect(await find({}, npm: (_) async => null), isNull);
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
          return '/home/u/.claude/local/claude\n';
        },
      );
      expect(found, '/home/u/.claude/local/claude');
      expect(ran, hasLength(1));
      expect(ran.single.take(6), ['wsl.exe', '-d', 'Ubuntu', '--', 'sh', '-lc']);
      expect(ran.single.last, 'claude');
      expect(ran.single.join(' '), allOf(contains('command -v'), contains(r'$HOME/.opencode/bin')));
    });

    test('a miss or a failure is null', () async {
      expect(await findCli('x', env: const _Wsl(), run: (_, _) async => ''), isNull);
      expect(await findCli('x', env: const _Wsl(), run: (_, _) async => throw StateError('no wsl')), isNull);
    });
  });
}
