import 'custom_command.dart';

Future<List<CustomCommand>> loadCommands(List<({String name, String path})> projects) async => const [];

Future<String?> globalDir() async => null;

Future<CustomCommand> create(String name, String? projectPath, String? projectName) =>
    throw StateError('Custom commands need a file system.');

Future<void> delete(CustomCommand command) async {}
