import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'custom_command.dart';

const _dirName = '.everyai/commands';

Future<String?> globalDir() async {
  try {
    return '${(await getApplicationSupportDirectory()).path}/commands';
  } on Object {
    return null;
  }
}

Future<List<CustomCommand>> loadCommands(List<({String name, String path})> projects) async {
  final out = <CustomCommand>[];
  final global = await globalDir();
  if (global != null) out.addAll(await _readDir(global, null));
  for (final p in projects) {
    out.addAll(await _readDir('${p.path}/$_dirName', p.name, p.path));
  }
  return out;
}

Future<List<CustomCommand>> _readDir(String dir, String? project, [String? projectDir]) async {
  final d = Directory(dir);
  if (!d.existsSync()) return const [];
  final out = <CustomCommand>[];
  try {
    await for (final f in d.list(followLinks: false)) {
      if (f is! File || !f.path.endsWith('.md')) continue;
      final name = f.uri.pathSegments.last.replaceFirst(RegExp(r'\.md$'), '');
      if (!CustomCommand.validName.hasMatch(name)) continue;
      try {
        if (await f.length() > 256 * 1024) continue;
        out.add(
          CustomCommand.parse(name, await f.readAsString(), path: f.path, project: project, projectDir: projectDir),
        );
      } on FileSystemException {
        continue;
      }
    }
  } on FileSystemException {
    return out;
  }
  out.sort((a, b) => a.name.compareTo(b.name));
  return out;
}

Future<CustomCommand> create(String name, String? projectPath, String? projectName) async {
  if (!CustomCommand.validName.hasMatch(name)) {
    throw StateError('Use lowercase letters, digits, - and _ (up to 48 characters).');
  }
  final dir = projectPath != null ? '$projectPath/$_dirName' : await globalDir();
  if (dir == null) throw StateError('Custom commands need a file system.');
  final file = File('$dir/$name.md');
  if (file.existsSync()) throw StateError('/$name already exists.');
  final command = CustomCommand(
    name: name,
    description: 'Describe what /$name does',
    args: '[arguments]',
    body: 'Write the prompt here. \$ARGUMENTS is replaced by what you type after /$name.',
    path: file.path,
    project: projectPath == null ? null : projectName,
    projectDir: projectPath,
  );
  await file.parent.create(recursive: true);
  await file.writeAsString(command.toSource());
  return command;
}

Future<void> delete(CustomCommand command) async {
  final path = command.path;
  if (path == null) return;
  final f = File(path);
  if (f.existsSync()) await f.delete();
}
