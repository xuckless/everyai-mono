import '../domain/skill_catalog.dart';
import 'skill_import.dart';
import 'skill_store.dart' show SkillRoots;

Future<SkillRoots> roots(List<({String id, String path})> projects) async =>
    (library: null, shared: null, projects: const <({String id, String path})>[]);

Future<List<InstalledSkill>> scan(SkillRoots roots) async => const [];

Future<List<SkillFile>> folderFiles(String path) async => const [];

Future<String> install(ImportCandidate candidate, String destDir) => throw StateError('Skills need a file system.');

Future<void> delete(String dir) async {}
