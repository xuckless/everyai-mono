import 'dart:convert';
import 'dart:typed_data';

import '../../skills/data/skill_import.dart';
import '../../skills/domain/skill_format.dart' show SkillEntryKind;
import 'skill_md.dart';

/// Where `/learn` takes a skill from.
sealed class LearnSource {
  const LearnSource(this.hint);

  /// What the user says the skill is for (the words after the source).
  final String hint;
}

/// The current conversation.
final class LearnFromConversation extends LearnSource {
  const LearnFromConversation(super.hint);
}

/// A web page, fetched by the backend.
final class LearnFromUrl extends LearnSource {
  const LearnFromUrl(this.url, super.hint);
  final String url;
}

/// A folder on this machine.
final class LearnFromFolder extends LearnSource {
  const LearnFromFolder(this.path, super.hint);
  final String path;
}

/// What `/learn [source] [what it is for]` names: a URL, a folder path
/// (absolute, `~`, `./` or `../`, quoted when it has spaces) that
/// [isFolder] confirms, else the conversation with all of [args] as the hint.
LearnSource parseLearnArgs(String args, {required bool Function(String path) isFolder}) {
  final text = args.trim();
  final m = RegExp(r'''^(?:"([^"]+)"|'([^']+)'|(\S+))\s*([\s\S]*)$''').firstMatch(text);
  if (m == null) return LearnFromConversation(text);
  final first = (m[1] ?? m[2] ?? m[3])!;
  final rest = m[4]!.trim();
  if (RegExp(r'^https?://\S+$', caseSensitive: false).hasMatch(first)) return LearnFromUrl(first, rest);
  final pathLike = first.startsWith('/') || first.startsWith('~') || first.startsWith('./') || first.startsWith('../');
  if (pathLike && isFolder(first)) return LearnFromFolder(first, rest);
  return LearnFromConversation(text);
}

/// [skill] as an import candidate, run through the same strict check as an
/// import from disk.
Future<ImportCandidate> skillCandidate(SkillMd skill) async {
  final bytes = Uint8List.fromList(utf8.encode(skill.toSource()));
  final found = await findImportCandidates([
    SkillFile('SKILL.md', size: bytes.length, kind: SkillEntryKind.file, read: () async => bytes),
  ], fallbackName: skill.name);
  return found.single;
}
