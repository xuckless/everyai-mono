// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/preferences.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../domain/cli_repo_configs.dart';
import '../drivers/acp/acp_agents.dart' show AcpAgent;
import '../drivers/acp/acp_driver.dart';
import '../drivers/driver.dart';
import '../drivers/driver_registry.dart';
import 'repo_config_scan.dart';

/// The CLI whose project config [driver] reads, or null when it reads none EveryAI warns about.
RepoConfigCli? repoConfigCliOf(HarnessDriver? driver) => driver is AcpDriver
    ? switch (driver.resolved.profile.agent) {
        AcpAgent.gemini => RepoConfigCli.gemini,
        AcpAgent.qwen => RepoConfigCli.qwen,
        AcpAgent.kiro => RepoConfigCli.kiro,
        AcpAgent.cursor => RepoConfigCli.cursor,
        AcpAgent.openCode || AcpAgent.grok || AcpAgent.generic => null,
      }
    : null;

/// The CLI config notes by [repoConfigNoteKey]; accepted ones are kept in preferences ([key]: key → digest).
final repoConfigNotesProvider = NotifierProvider<RepoConfigNotes, Map<String, RepoConfigNote>>(RepoConfigNotes.new);

final class RepoConfigNotes extends Notifier<Map<String, RepoConfigNote>> {
  static const key = 'code.repo_config_notes';

  Preferences get _prefs => ref.read(preferencesProvider);

  @override
  Map<String, RepoConfigNote> build() {
    final raw = _prefs[key];
    final saved = raw == null ? null : jsonDecode(raw);
    return {
      if (saved is Map<String, Object?>)
        for (final MapEntry(key: k, :value) in saved.entries)
          if (value is String) k: RepoConfigAccepted(value),
    };
  }

  RepoConfigNote of(String noteKey) => state[noteKey] ?? const RepoConfigUnseen();

  /// unseen or accepted (other files) → shown.
  void show(String noteKey, String digest) => _set(noteKey, RepoConfigShown(digest));

  /// shown → accepted: Continue.
  void accept(String noteKey) {
    if (of(noteKey) case RepoConfigShown(:final digest)) _set(noteKey, RepoConfigAccepted(digest));
  }

  /// shown → unseen: Cancel (asked again next start).
  void dismiss(String noteKey) {
    if (of(noteKey) is RepoConfigShown) _set(noteKey, const RepoConfigUnseen());
  }

  void _set(String noteKey, RepoConfigNote note) {
    state = {...state, noteKey: note};
    _prefs[key] = jsonEncode({
      for (final MapEntry(key: k, value: n) in state.entries)
        if (n is RepoConfigAccepted) k: n.digest,
    });
  }
}

/// Before a session starts on [harness] in the project [projectId] at [dir]: when the CLI would honour project
/// files that pre-allow tools or start programs, says so once (per project, harness and those files' contents).
/// True to go on (nothing to say, said before for these files, or Continue); false on Cancel.
Future<bool> confirmRepoConfigs(
  BuildContext context,
  WidgetRef ref, {
  required String projectId,
  required String dir,
  required String harness,
}) async {
  final cli = repoConfigCliOf(ref.read(driverRegistryProvider).resolve(harness));
  if (cli == null) return true;
  final found = await scanRepoConfigs(cli, dir);
  if (found == null || !context.mounted) return found == null;
  final notes = ref.read(repoConfigNotesProvider.notifier);
  final noteKey = repoConfigNoteKey(projectId, harness);
  if (!notes.of(noteKey).asksFor(found.digest)) return true;
  notes.show(noteKey, found.digest);
  final go = await showKitDialog<bool>(
    context,
    builder: (ctx) {
      final theme = EveryTheme.of(ctx);
      return KitDialog(
        title: "This project's ${cli.folder} folder changes what ${cli.label} does",
        width: 500,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${cli.label} reads these files and follows them under EveryAI too. What they allow runs without '
              'asking you.',
            ),
            const SizedBox(height: 10),
            for (final f in found.files)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: f.path, style: theme.type.callout.mono.tint(theme.text)),
                      TextSpan(text: '  ${f.what}'),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 4),
            Text(
              "Shown again only if these files change. Check them first if you didn't write them.",
              style: theme.type.caption.tint(theme.textMuted),
            ),
          ],
        ),
        actions: [
          KitButton(
            label: 'Cancel',
            style: KitButtonStyle.ghost,
            shortcut: 'esc',
            onPressed: () => Navigator.of(ctx).pop(false),
          ),
          KitButton(label: 'Continue', onPressed: () => Navigator.of(ctx).pop(true)),
        ],
      );
    },
  );
  if (go ?? false) {
    notes.accept(noteKey);
    return true;
  }
  notes.dismiss(noteKey);
  return false;
}
