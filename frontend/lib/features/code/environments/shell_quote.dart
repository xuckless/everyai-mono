// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

/// [s] as one word for a POSIX shell: plain words as they are, anything else
/// in single quotes (a `'` inside becomes `'\''`). Same rule as the checks'
/// command lines (`host/host_checks.dart`).
String posixQuote(String s) => RegExp(r'^[\w./@+-]+$').hasMatch(s) ? s : "'${s.replaceAll("'", r"'\''")}'";

/// [argv] as one POSIX command line that a shell splits back into [argv].
String posixCommand(List<String> argv) => argv.map(posixQuote).join(' ');

/// Whether [name] (a distro, container, machine, profile, ssh alias or host)
/// is safe to put on a command line as an argument: not empty, no leading
/// `-` (it would read as an option, like `-oProxyCommand=…`), no whitespace
/// or control characters.
bool safeName(String name) => name.isNotEmpty && !name.startsWith('-') && !RegExp(r'[\s\x00-\x1f\x7f]').hasMatch(name);

/// Whether [name] can be an environment variable name (`K` in `K=V`, `-e K`).
bool safeEnvName(String name) => RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name);

/// Throws when a variable name in [env] isn't [safeEnvName]: `-e A=B` or
/// `env A=B=C` would set something else.
void checkEnvNames(Map<String, String> env) {
  for (final k in env.keys) {
    if (!safeEnvName(k)) throw ArgumentError.value(k, 'env', 'not a variable name');
  }
}
