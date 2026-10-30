import 'dart:io';

import 'skill_md.dart';

String? _home() => Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];

Future<({String name, String path})> save(SkillMd skill) async {
  final home = _home();
  if (home == null) throw StateError('The home folder could not be found.');
  final dir = Directory('$home/.agents/skills/${skill.name}');
  if (dir.existsSync()) {
    throw StateError('A skill named "${skill.name}" already exists in ~/.agents/skills.');
  }
  await dir.create(recursive: true);
  final file = File('${dir.path}/SKILL.md');
  await file.writeAsString(skill.toSource());
  return (name: skill.name, path: file.path);
}
