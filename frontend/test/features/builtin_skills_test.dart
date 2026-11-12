import 'dart:convert';

import 'package:every_ai/features/skills/domain/builtin_skills.dart';
import 'package:every_ai/features/skills/domain/skill_format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the bundled skills pass the strict validator', () async {
    final skills = await loadBuiltinSkills();
    expect(skills.map((s) => s.name), ['draw-diagram', 'everyai-max', 'make-deck', 'vector-art', 'write-artifact']);
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
}
