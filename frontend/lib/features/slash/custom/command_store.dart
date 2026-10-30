import 'command_store_stub.dart' if (dart.library.io) 'command_store_io.dart' as impl;
import 'custom_command.dart';

/// Where commands live: `<project>/.everyai/commands` and `<app support>/commands`.
const commandsDirName = '.everyai/commands';

/// Reads every command of the global folder and of [projects] (name, path pairs).
/// A project command shadows a global one of the same name in the menu.
Future<List<CustomCommand>> loadCustomCommands(List<({String name, String path})> projects) =>
    impl.loadCommands(projects);

/// The global folder; null where there is no file system.
Future<String?> globalCommandsDir() => impl.globalDir();

/// Writes a new command file and returns it. Throws [StateError] if [name] is taken or invalid.
Future<CustomCommand> createCustomCommand({required String name, String? projectPath, String? projectName}) =>
    impl.create(name, projectPath, projectName);

Future<void> deleteCustomCommand(CustomCommand command) => impl.delete(command);
