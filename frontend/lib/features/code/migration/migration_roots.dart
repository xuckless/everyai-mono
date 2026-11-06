// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

/// Where the other tools keep their user-level files. One table, so a moved folder is a one-line fix.
typedef MigrationRoots = ({
  String? claudeDir,
  String? claudeJson,
  String? cursorDir,
  String? codexDir,
  String? openCodeDir,
});

/// The folders from the login shell's environment [env] (so `CLAUDE_CONFIG_DIR`, `CODEX_HOME` and
/// `XDG_CONFIG_HOME` count); the home folder is `HOME`, or `USERPROFILE` on Windows. Paths are joined with `/`,
/// which Windows accepts too.
MigrationRoots migrationRoots(Map<String, String> env) {
  String? nonEmpty(String? s) => s == null || s.isEmpty ? null : s.replaceFirst(RegExp(r'[/\\]+$'), '');
  final home = nonEmpty(env['HOME']) ?? nonEmpty(env['USERPROFILE']);
  String? under(String? base, String rest) => base == null ? null : '$base/$rest';
  final claude = nonEmpty(env['CLAUDE_CONFIG_DIR']);
  final xdg = nonEmpty(env['XDG_CONFIG_HOME']) ?? under(home, '.config');
  return (
    claudeDir: claude ?? under(home, '.claude'),
    // Claude keeps its state file in the home folder, or inside the config folder when that is set.
    claudeJson: claude != null ? '$claude/.claude.json' : under(home, '.claude.json'),
    cursorDir: under(home, '.cursor'),
    codexDir: nonEmpty(env['CODEX_HOME']) ?? under(home, '.codex'),
    openCodeDir: under(xdg, 'opencode'),
  );
}
