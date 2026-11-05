// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/agents_providers.dart';
import '../../skills/data/skill_import.dart';
import '../../skills/data/skill_store.dart' show folderFiles;
import '../../skills/skills_providers.dart' show installedSkillsProvider;
import '../../slash/custom/command_store.dart';
import '../../slash/custom/custom_commands_provider.dart';
import '../code_providers.dart';
import '../mcp_providers.dart';
import '../resume/resume_files.dart';
import 'migration_files.dart';
import 'migration_scan.dart';

// "Bring over from other tools": the scan runs when the sheet opens (nothing at app start), and nothing is written
// until the user ticks rows and presses Import. The other tools' folders are never written.

/// The other tools' user-level folders, from the login shell's environment. Tests override it.
final migrationRootsProvider = FutureProvider<MigrationRoots>((ref) async => migrationRoots(await resumeEnv()));

/// What the other tools hold, minus what EveryAI already has. Read again each time the sheet opens.
final migrationScanProvider = FutureProvider.autoDispose<List<ImportItem>>((ref) async {
  final projects = [
    for (final p in ref.read(codeProjectsProvider))
      if (!p.path.startsWith('demo://')) p,
  ];
  final roots = await ref.read(migrationRootsProvider.future);
  final items = await scanOtherTools(roots, [for (final p in projects) p.path]);
  final mcp = ref.read(codeMcpServersProvider);
  String? idOf(String? scope) => scope == null ? null : projects.where((p) => p.path == scope).firstOrNull?.id;
  final commands = await loadCustomCommands([for (final p in projects) (name: p.name, path: p.path)]);
  final agents = ref.read(agentLibraryProvider).value ?? const [];
  final skills = ref.read(installedSkillsProvider).value ?? const [];
  return [
    for (final i in items)
      if (i.kind == ImportKind.agent &&
          i.agentName != null &&
          agents.any((a) => a.name == i.agentName && a.projectId == idOf(i.scope)))
        i.copyWith(unavailable: 'Already in EveryAI.')
      else if (i.kind == ImportKind.skill && skills.any((s) => s.dirName == i.title && s.projectId == idOf(i.scope)))
        i.copyWith(unavailable: 'Already in EveryAI.')
      else if (i.mcp != null && mcp.listFor(idOf(i.scope)).any((s) => s.name == i.mcp!.name))
        i.copyWith(unavailable: 'Already in EveryAI.')
      else if (i.command != null && commands.any((c) => c.name == i.command!.name && c.projectDir == i.scope))
        i.copyWith(unavailable: 'Already in EveryAI.')
      else
        i,
  ];
});

/// Installs skill [candidates] (the sheet asks about hidden text first) and returns a line for each; null when the
/// user left.
typedef SkillImporter = Future<List<String>?> Function(List<ImportCandidate> candidates);

/// Brings over the chosen rows and returns a line for each. A name that is already there is never replaced.
final importApplierProvider = Provider<Future<List<String>> Function(List<ImportItem> chosen, {SkillImporter? skills})>(
  (ref) => (chosen, {skills}) async {
    final lines = <String>[];
    var wroteCommand = false;
    final projects = ref.read(codeProjectsProvider);
    for (final item in chosen) {
      if (!item.selectable) continue;
      final project = item.scope == null ? null : projects.where((p) => p.path == item.scope).firstOrNull;
      if (item.scope != null && project == null) {
        lines.add('${item.title}: its project is no longer in EveryAI.');
        continue;
      }
      try {
        switch (item.kind) {
          case ImportKind.mcp:
            final server = item.mcp!;
            final notifier = ref.read(codeMcpServersProvider.notifier);
            if (ref.read(codeMcpServersProvider).listFor(project?.id).any((s) => s.name == server.name)) {
              lines.add('${item.title}: already in EveryAI, left as it is.');
            } else {
              notifier.put(server, projectId: project?.id);
              lines.add(
                '${item.title}: imported.'
                '${server.transport.remote ? '' : ' You approve the command in MCP servers before it runs.'}'
                '${server.enabled
                    ? ''
                    : item.notes.any((n) => n.contains('variables'))
                    ? ' It is switched off until you fix its variables.'
                    : ' It was switched off in ${item.source}, so it stays off.'}',
              );
            }
          case ImportKind.command:
            await writeCustomCommand(item.command!, projectPath: project?.path);
            wroteCommand = true;
            lines.add('${item.title}: imported.');
          case ImportKind.agent:
            await ref
                .read(agentLibraryProvider.notifier)
                .create(item.agentName!, projectPath: project?.path, text: item.agentText, trust: false);
            lines.add('${item.title}: imported.');
          case ImportKind.skill:
            final found = await findImportCandidates(await folderFiles(item.path!), fallbackName: item.title);
            final done = skills == null ? null : await skills(found);
            lines.addAll(done ?? ['${item.title}: not imported.']);
          case ImportKind.rule:
            break;
        }
      } on StateError catch (e) {
        lines.add('${item.title}: ${RegExp('exists|already').hasMatch(e.message) ? 'already there.' : e.message}');
      } on Object catch (e) {
        lines.add('${item.title}: $e');
      }
    }
    if (wroteCommand) await ref.read(customCommandsProvider.notifier).reload();
    return lines;
  },
);
