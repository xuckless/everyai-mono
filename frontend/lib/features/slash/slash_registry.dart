import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'chat_commands.dart';
import 'code_commands.dart';
import 'custom/custom_command.dart';
import 'custom/custom_commands_provider.dart';
import 'slash_command.dart';

/// Every command the `/` menu offers, all groups. Built-ins are listed here;
/// custom commands, skills and connectors join through their own providers.
final slashCommandsProvider = Provider<List<SlashCommand>>(
  (ref) => [
    ...ref.watch(builtInSlashCommandsProvider),
    ...ref.watch(customSlashCommandsProvider),
    ...ref.watch(skillSlashCommandsProvider),
    ...ref.watch(connectorSlashCommandsProvider),
  ],
);

final builtInSlashCommandsProvider = Provider<List<SlashCommand>>((ref) => builtInSlashCommands);

/// `.everyai/commands/*.md` (project and global); filled by the custom-commands step.
final customSlashCommandsProvider = Provider<List<SlashCommand>>(
  (ref) => [for (final c in ref.watch(customCommandsProvider).value ?? const <CustomCommand>[]) c.toSlash()],
);

/// One `/skill-name` per enabled skill; filled by the skills step.
final skillSlashCommandsProvider = Provider<List<SlashCommand>>((ref) => const []);

/// MCP prompts as commands; empty until connectors exist.
final connectorSlashCommandsProvider = Provider<List<SlashCommand>>((ref) => const []);

/// The built-ins: the chat set (`chat_commands.dart`) and the Code set (`code_commands.dart`).
final builtInSlashCommands = <SlashCommand>[...chatBuiltIns, ...codeBuiltIns];
