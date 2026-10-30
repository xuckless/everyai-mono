import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../code/code_providers.dart';
import 'command_store.dart';
import 'custom_command.dart';

/// Every custom command on disk: the global folder, then each Code project's
/// `.everyai/commands`. A project command shadows a global one by name (the
/// menu keeps the first of a name, so project entries come first).
final customCommandsProvider = AsyncNotifierProvider<CustomCommands, List<CustomCommand>>(CustomCommands.new);

final class CustomCommands extends AsyncNotifier<List<CustomCommand>> {
  @override
  Future<List<CustomCommand>> build() async {
    final projects = ref.watch(codeProjectsProvider);
    final all = await loadCustomCommands([for (final p in projects) (name: p.name, path: p.path)]);
    return [...all.where((c) => !c.isGlobal), ...all.where((c) => c.isGlobal)];
  }

  /// Re-reads the folders (after an edit in an outside editor).
  Future<void> reload() async {
    state = await AsyncValue.guard(build);
  }

  Future<CustomCommand> create(String name, {CodeProjectRef? project}) async {
    final c = await createCustomCommand(name: name, projectPath: project?.path, projectName: project?.name);
    await reload();
    return c;
  }

  Future<void> remove(CustomCommand command) async {
    await deleteCustomCommand(command);
    await reload();
  }
}

/// A project to put a command in.
typedef CodeProjectRef = ({String name, String path});
