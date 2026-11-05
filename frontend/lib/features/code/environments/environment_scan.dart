// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import '../drivers/driver.dart' show DriverStatus;
import 'discovery.dart';
import 'environment_io_stub.dart' if (dart.library.io) 'environment_io_io.dart' as io;
import 'exec_env.dart';
import 'shell_quote.dart';

/// What one look inside an environment found: its login shell's PATH and
/// HOME, `uname -sm`, for WSL the automount root and the Windows host's
/// address, and per command whether it's installed (path, first
/// `--version` line). [problem] says why the look failed.
final class EnvScan {
  const EnvScan({this.path, this.home, this.os, this.wslRoot, this.hostAddress, this.found = const {}, this.problem});

  final String? path;
  final String? home;
  final String? os;

  /// `/mnt/` unless `/etc/wsl.conf` moved it.
  final String? wslRoot;

  /// The default gateway inside WSL (the Windows host in NAT mode).
  final String? hostAddress;
  final Map<String, DriverStatus> found;
  final String? problem;
}

/// The coding CLIs looked for by default; the drivers' list replaces it at
/// integration (`environmentScanCommandsProvider`).
const defaultScanCommands = ['claude', 'codex', 'opencode', 'gemini'];

const _marker = '__EVERYAI_SCAN__';

/// Run by `/bin/sh -c` with the probe as `$1` and the commands after it:
/// picks the user's login shell when it's a POSIX one (fish and csh can't run
/// the probe), lets it load its rc files as an interactive login shell, then
/// hands the probe to /bin/sh with that environment. A constant: the
/// commands are only ever positional arguments.
const scanBootstrap =
    r'case "${SHELL##*/}" in bash|zsh|sh|dash|ksh|mksh|ash) s=$SHELL ;; *) s=/bin/sh ;; esac; '
    r'[ -x "$s" ] || s=/bin/sh; '
    r'''exec "$s" -ilc 'p=$1; shift; exec /bin/sh -c "$p" sh "$@"' sh "$@" </dev/null''';

/// Prints the marker, then tab-separated facts, then `CLI name path version`
/// per command: `command -v`, else the usual install folders under $HOME
/// (and the newest nvm Node), with `--version` capped at 4 s.
const scanProbe = r'''printf '\n__EVERYAI_SCAN__\n'
printf 'PATH\t%s\n' "$PATH"
printf 'HOME\t%s\n' "$HOME"
printf 'OS\t%s\n' "$(uname -sm 2>/dev/null)"
if command -v wslpath >/dev/null 2>&1; then
  printf 'WSLROOT\t%s\n' "$(wslpath -u 'C:\' 2>/dev/null)"
  printf 'GATEWAY\t%s\n' "$(ip route show default 2>/dev/null | awk '{print $3; exit}')"
fi
t=
command -v timeout >/dev/null 2>&1 && t='timeout 4'
n=$(ls -dt "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | head -n 1)
for c in "$@"; do
  p=$(command -v "$c" 2>/dev/null)
  case "$p" in /*) ;; *) p= ;; esac
  if [ -z "$p" ]; then
    for d in "$HOME/.local/bin" "$HOME/.npm-global/bin" "$HOME/.claude/local" "$HOME/.opencode/bin" "$HOME/.bun/bin" "$HOME/.cargo/bin" "$n"; do
      if [ -n "$d" ] && [ -x "$d/$c" ]; then p=$d/$c; break; fi
    done
  fi
  v=
  if [ -n "$p" ]; then v=$($t "$p" --version </dev/null 2>/dev/null | head -n 1); fi
  printf 'CLI\t%s\t%s\t%s\n' "$c" "$p" "$v"
done
''';

/// Looks inside [env] for [commands] in one round trip, through its bridge
/// and its login shell (so the PATH its rc files set applies). A stopped
/// environment isn't started; one that doesn't answer within [timeout] is
/// given up on (the bridge process is killed).
Future<EnvScan> scanEnvironment(
  ExecEnv env, {
  List<String> commands = defaultScanCommands,
  RunCommand? run,
  Duration timeout = const Duration(seconds: 15),
}) async {
  if (!env.running) return EnvScan(problem: '${env.label} is stopped. Start it, then check again.');
  final names = [
    for (final c in commands)
      if (safeName(c) && !c.contains('/')) c,
  ];
  final w = env.wrap('/bin/sh', ['-c', scanBootstrap, 'sh', scanProbe, ...names]);
  final result = await (run ?? io.platformEnvironmentIo().run)(
    w.executable,
    w.args,
    timeout: timeout,
    environment: w.environment,
  );
  if (result == null) return EnvScan(problem: "${env.label} didn't answer within ${timeout.inSeconds} s.");
  final scan = parseScanOutput(utf8.decode(result.stdout, allowMalformed: true), names);
  if (scan != null) return scan;
  if (env.kind == EnvKind.ssh && result.code == 255) {
    return EnvScan(
      problem:
          "Couldn't connect to ${env.label}. Connect once from a terminal, so its host key is known and your key "
          'or ssh agent signs you in.',
    );
  }
  return EnvScan(problem: "Couldn't run a shell in ${env.label} (exit code ${result.code}).");
}

/// The facts after the marker in the probe's output (rc file banners before
/// it are skipped), or null when there's no marker.
EnvScan? parseScanOutput(String out, List<String> commands) {
  final at = out.indexOf('$_marker\n');
  if (at < 0) return null;
  final facts = <String, String>{};
  final found = <String, DriverStatus>{};
  for (final raw in const LineSplitter().convert(out.substring(at + _marker.length + 1))) {
    final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
    final parts = line.split('\t');
    if (parts.first == 'CLI' && parts.length >= 3) {
      final path = parts[2].trim();
      final version = parts.length > 3 ? parts.sublist(3).join('\t').trim() : '';
      found[parts[1]] = path.isEmpty
          ? const DriverStatus()
          : DriverStatus(installed: true, path: path, version: version.isEmpty ? null : version);
    } else if (parts.length >= 2) {
      facts[parts.first] = parts.sublist(1).join('\t').trim();
    }
  }
  String? fact(String k) => (facts[k]?.isEmpty ?? true) ? null : facts[k];
  return EnvScan(
    path: fact('PATH'),
    home: fact('HOME'),
    os: fact('OS'),
    wslRoot: _wslRoot(fact('WSLROOT')),
    hostAddress: fact('GATEWAY'),
    found: {for (final c in commands) c: found[c] ?? const DriverStatus()},
  );
}

// `wslpath -u 'C:\'` is `<root>c/`; the root is what's before the drive.
String? _wslRoot(String? c) {
  if (c == null) return null;
  final m = RegExp(r'^(.*/)[A-Za-z]/?$').firstMatch(c);
  return m?.group(1);
}
