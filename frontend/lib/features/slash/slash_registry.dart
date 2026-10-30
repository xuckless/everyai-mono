import 'package:flutter_riverpod/flutter_riverpod.dart';

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

/// Switches the chat mode, then sends any text after the command in it.
SlashCommand _chatMode(String name, String description) => SlashCommand(
  name: name,
  description: description,
  argsHint: '[message]',
  scope: SlashScope.chat,
  run: (ctx, args) {
    ctx.chat?.setMode(name);
    if (args.isNotEmpty) ctx.send(args);
  },
);

/// The first built-ins: mode switches. The full Chat and Code sets come with
/// their own steps.
final builtInSlashCommands = <SlashCommand>[
  _chatMode('chat', 'Answer from the model alone'),
  _chatMode('search', 'Search the web and cite sources'),
  _chatMode('research', 'Multi-step research with a report'),
  SlashCommand(
    name: 'plan',
    description: 'Switch to Plan mode: read and propose before editing',
    argsHint: '[what to plan]',
    scope: SlashScope.code,
    run: (ctx, args) {
      ctx.code?.setMode('plan');
      if (args.isNotEmpty) ctx.send(args);
    },
  ),
  SlashCommand(
    name: 'stop',
    description: 'Stop the agent',
    scope: SlashScope.code,
    run: (ctx, _) => ctx.code?.stop?.call(),
  ),
];
