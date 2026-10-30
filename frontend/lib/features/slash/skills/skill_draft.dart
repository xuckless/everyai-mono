import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/net/api_client.dart';
import '../../../core/providers.dart';
import '../../chat/domain/message.dart';
import 'skill_files.dart';
import 'skill_md.dart';

/// Asks the backend's cheap model to turn a conversation into a `SKILL.md`.
final class SkillDrafter {
  const SkillDrafter(this._api, {this.authenticated = false});

  final ApiClient _api;
  final bool authenticated;

  /// The model's file, checked and repaired. Throws [FormatException] when
  /// what came back is not a usable skill, [ApiException]s from the call.
  Future<SkillMd> draft(List<Message> messages, {String hint = '', String? session}) async {
    final turns = [
      for (final m in messages)
        if (m.status == MessageStatus.complete && m.plainText.trim().isNotEmpty)
          {'role': m.role.name, 'content': m.plainText},
    ];
    if (turns.isEmpty) throw const FormatException('There is nothing in this chat to learn from yet.');
    final json = await _api.postJson(
      'v1/aux/skill',
      {'messages': turns, if (hint.isNotEmpty) 'hint': hint, 'session': ?session},
      authenticated: authenticated,
      timeout: const Duration(seconds: 90),
    );
    final content = json['content'];
    if (content is! String) throw const FormatException('The skill model returned nothing.');
    return SkillMd.repairAndParse(content);
  }
}

final skillDrafterProvider = Provider<SkillDrafter>(
  (ref) => SkillDrafter(ref.watch(apiClientProvider), authenticated: !ref.watch(appConfigProvider).devSkipAuth),
);

/// Where a finished skill goes. The skills settings step swaps this for the
/// skill store; until then it writes the user's skills folder.
final skillSaverProvider = Provider<Future<SkillSaved> Function(SkillMd skill)>((ref) => saveUserSkill);
