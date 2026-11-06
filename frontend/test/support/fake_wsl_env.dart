import 'package:every_ai/features/code/environments/exec_env.dart';

/// A WSL distro as the environment seam sees it; only the label and kind matter to list tests.
final class FakeWslEnv extends ExecEnv {
  const FakeWslEnv();
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
