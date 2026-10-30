import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/net/api_client.dart';
import '../../../core/providers.dart';
import '../../chat/domain/message.dart';
import '../../skills/skills_providers.dart';
import 'learn.dart';
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
    return draftFrom(messages: turns, hint: hint, session: session);
  }

  /// A skill from one source: chat [messages] (`{role, content}`), a web page
  /// at [url] (the backend fetches it through its safe fetcher, never the
  /// app), or a folder's [documents] (`{path, text}`).
  Future<SkillMd> draftFrom({
    List<Map<String, String>> messages = const [],
    String url = '',
    List<({String path, String text})> documents = const [],
    String hint = '',
    String? session,
  }) async {
    final json = await _api.postJson(
      'v1/aux/skill',
      {
        if (url.isNotEmpty)
          'url': url
        else if (documents.isNotEmpty)
          'documents': [
            for (final d in documents) {'path': d.path, 'text': d.text},
          ]
        else
          'messages': messages,
        if (hint.isNotEmpty) 'hint': hint,
        'session': ?session,
      },
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

/// Where a finished skill goes: through the strict import check into the
/// skills library, which is rescanned, so Chat and new Code sessions see it
/// at once (the same path as Code's `/learn`).
final skillSaverProvider = Provider<Future<SkillSaved> Function(SkillMd skill)>(
  (ref) => (skill) async {
    final candidate = await skillCandidate(skill);
    if (!candidate.ok) throw StateError(candidate.check.report.errors.join(' '));
    final added = await ref.read(installedSkillsProvider.notifier).import(candidate);
    return (name: added?.name ?? candidate.dirName, path: added?.dir ?? '');
  },
);
