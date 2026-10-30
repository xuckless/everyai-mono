import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/skills/data/skill_store_io.dart' as store;
import 'package:every_ai/features/skills/domain/builtin_skills.dart';
import 'package:every_ai/features/skills/domain/skill_catalog.dart';
import 'package:every_ai/features/skills/domain/skill_format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the bundled skills pass the strict validator', () async {
    final skills = await loadBuiltinSkills();
    expect(skills.map((s) => s.name), ['draw-diagram', 'make-deck', 'vector-art', 'write-artifact']);
    for (final s in skills) {
      final md = utf8.decode(s.files['SKILL.md']!);
      final check = checkSkill(
        dirName: s.name,
        skillMd: md,
        entries: [
          for (final e in s.files.entries) SkillEntry(e.key, size: e.value.length, head: e.value.take(4).toList()),
        ],
      );
      expect(check.report.errors, isEmpty, reason: s.name);
      expect(check.report.warnings, isEmpty, reason: s.name);
      expect(check.manifest!.name, s.name);
      expect(check.manifest!.license, 'Apache-2.0');
      expect(check.report.hasScripts, isFalse);
      expect(s.files.keys, contains('LICENSE.txt'));
      expect(utf8.decode(s.files['LICENSE.txt']!), contains('Apache License'));
      expect(md.split('\n').length, lessThan(SkillRules.longBodyLines));
    }
  });

  test('seeding installs once, respects removal and updates on a new digest', () async {
    final skills = await loadBuiltinSkills();
    final lib = await Directory.systemTemp.createTemp('builtin-skills');
    addTearDown(() => lib.delete(recursive: true));
    final dir = '${lib.path}/skills';

    await store.seedBuiltins(dir, skills);
    expect(File('$dir/make-deck/SKILL.md').existsSync(), isTrue);
    final scanned = await store.scan((library: dir, shared: null, projects: const []));
    expect(scanned.where((s) => s.usable && s.source == SkillSource.library), hasLength(4));

    // Removed by the user: stays removed.
    await store.delete('$dir/make-deck');
    await store.seedBuiltins(dir, skills);
    expect(Directory('$dir/make-deck').existsSync(), isFalse);

    // An app update ships a changed copy: it replaces the old one.
    final changed = BuiltinSkill('vector-art', {
      ...skills.firstWhere((s) => s.name == 'vector-art').files,
      'SKILL.md': utf8.encode('---\nname: vector-art\ndescription: New.\n---\nBody.\n'),
    });
    await store.seedBuiltins(dir, [changed]);
    expect(File('$dir/vector-art/SKILL.md').readAsStringSync(), contains('New.'));

    // A folder the user made with a bundled name is never overwritten.
    final other = await Directory.systemTemp.createTemp('own-skills');
    addTearDown(() => other.delete(recursive: true));
    await Directory('${other.path}/make-deck').create();
    await File('${other.path}/make-deck/SKILL.md').writeAsString('mine');
    await store.seedBuiltins(other.path, skills);
    expect(File('${other.path}/make-deck/SKILL.md').readAsStringSync(), 'mine');
  });
}
