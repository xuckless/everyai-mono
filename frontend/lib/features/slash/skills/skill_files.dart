import 'skill_files_stub.dart' if (dart.library.io) 'skill_files_io.dart' as impl;
import 'skill_md.dart';

/// The result of saving a skill.
typedef SkillSaved = ({String name, String path});

/// Writes [skill] as `<skills folder>/<name>/SKILL.md` in the user's skills
/// folder (`~/.agents/skills`, which Agent Skills tools and OpenHands read).
/// Throws [StateError] when the name is taken or there is no file system.
Future<SkillSaved> saveUserSkill(SkillMd skill) => impl.save(skill);
