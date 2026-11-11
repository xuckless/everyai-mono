// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The outside CLIs that read a project's own config and can be told by it to run tools without asking or to start
/// programs. The CLI keeps honouring that config under EveryAI (owner, 2026-11-11): the user is told once, not
/// blocked.
enum RepoConfigCli {
  gemini('Gemini CLI', '.gemini'),
  qwen('Qwen Code', '.qwen'),
  kiro('Kiro CLI', '.kiro'),
  cursor('Cursor CLI', '.cursor');

  const RepoConfigCli(this.label, this.folder);
  final String label;
  final String folder;
}

/// One file (or folder, ending in `/`) of a project's CLI config, relative to the project, and what it can do.
typedef RepoConfigFile = ({String path, String what});

/// A project's files as the scan reads them: text by relative path (null: missing or unreadable), and whether a
/// relative path is a folder.
abstract interface class RepoTree {
  String? read(String path);
  bool isDir(String path);
}

/// `.gemini/settings.json` (and `.qwen/`) keys that can't widen what the CLI does unasked.
const _geminiHarmless = {r'$schema', 'ui', 'general', 'model', 'privacy', 'telemetry', 'output', 'accessibility'};

/// The files in [tree] that let [cli] act without asking or start programs, the same list the start checks once
/// refused on (`geminiWorkspaceProblem`, `kiroWorkspaceProblem`, `cursorWorkspaceProblem`, removed 2026-11-11).
List<RepoConfigFile> cliRepoConfigs(RepoConfigCli cli, RepoTree tree) {
  final dir = cli.folder;
  switch (cli) {
    case RepoConfigCli.gemini || RepoConfigCli.qwen:
      final keys = <String>[];
      if (_json(tree.read('$dir/settings.json')) case final Map<String, Object?> settings) {
        for (final MapEntry(:key, :value) in settings.entries) {
          final harmless =
              _geminiHarmless.contains(key) ||
              (key == 'context' && value is Map<String, Object?> && value['includeDirectories'] == null);
          if (!harmless) keys.add('"$key"');
        }
      }
      return [
        if (keys.isNotEmpty)
          (
            path: '$dir/settings.json',
            what: 'settings (${keys.join(', ')}) that can allow tools ahead of time or start MCP server commands',
          ),
        if (tree.isDir('$dir/policies')) (path: '$dir/policies/', what: 'policies that can allow tools without asking'),
        if (tree.isDir('$dir/extensions'))
          (path: '$dir/extensions/', what: 'extensions that can add tools and start programs'),
      ];
    case RepoConfigCli.kiro:
      return [
        if (tree.isDir('$dir/agents'))
          (path: '$dir/agents/', what: 'agent configs offered as its modes, which can pre-allow tools and run hooks'),
        if (tree.read('$dir/settings/mcp.json') != null)
          (path: '$dir/settings/mcp.json', what: 'MCP servers it starts (programs)'),
      ];
    case RepoConfigCli.cursor:
      final allow = switch (_json(tree.read('$dir/cli.json'))) {
        {'permissions': {'allow': final List<Object?> a}} => a,
        _ => const <Object?>[],
      };
      return [
        if (allow.isNotEmpty)
          (path: '$dir/cli.json', what: 'permissions.allow, tools it runs without asking (${allow.length})'),
        if (tree.read('$dir/hooks.json') != null)
          (path: '$dir/hooks.json', what: 'hooks that run commands and can allow shell calls'),
      ];
  }
}

Object? _json(String? text) {
  if (text == null) return null;
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}

/// A digest of the listed files' contents ([contents]: relative path → text, folders contributing each file
/// beneath them), so a changed file asks again.
String repoConfigDigest(Map<String, String> contents) {
  final keys = contents.keys.toList()..sort();
  final buffer = StringBuffer();
  for (final k in keys) {
    buffer
      ..write(k)
      ..write('\u0000')
      ..write(contents[k])
      ..write('\u0000');
  }
  return sha256.convert(utf8.encode(buffer.toString())).toString();
}

/// What a project's CLI config note stands at, per project + harness:
///
/// unseen → shown(digest) → accepted(digest) (Continue) or unseen (Cancel); accepted(d) asks again (unseen) once
/// the files' digest is no longer d.
sealed class RepoConfigNote {
  const RepoConfigNote();

  /// Whether a start with files of [digest] shows the note.
  bool asksFor(String digest) => switch (this) {
    RepoConfigAccepted(digest: final d) => d != digest,
    RepoConfigShown() => false,
    RepoConfigUnseen() => true,
  };
}

/// Never shown for these files.
final class RepoConfigUnseen extends RepoConfigNote {
  const RepoConfigUnseen();
}

/// On screen now (a second start meanwhile doesn't show it again).
final class RepoConfigShown extends RepoConfigNote {
  const RepoConfigShown(this.digest);
  final String digest;
}

/// The user chose Continue for files with this [digest].
final class RepoConfigAccepted extends RepoConfigNote {
  const RepoConfigAccepted(this.digest);
  final String digest;
}

/// The key a note is kept under.
String repoConfigNoteKey(String projectId, String harness) => '$projectId|$harness';
