/// Links into the app: `everyai://prompt?text=…&mode=chat|code&project=<id>`.
///
/// A link only puts text in a box. It never sends, and it carries no model, harness, mode of work or trust.
sealed class AppLink {
  const AppLink();
}

/// A prompt to review and send by hand. [mode] is where it goes; [projectId] is a local id to look up, never a path.
final class PromptLink extends AppLink {
  const PromptLink({required this.text, this.mode = PromptTarget.chat, this.projectId});

  final String text;
  final PromptTarget mode;
  final String? projectId;
}

/// A prompt link whose text is over [maxPromptLinkBytes].
final class OversizedLink extends AppLink {
  const OversizedLink();
}

enum PromptTarget { chat, code }

const maxPromptLinkBytes = 32 * 1024;

/// Reads [uri] as a prompt link; null for anything else (other schemes and hosts, no text).
AppLink? parseAppLink(Uri uri) {
  if (uri.scheme != 'everyai' || uri.host != 'prompt') return null;
  final Map<String, String> query;
  try {
    query = uri.queryParameters;
  } on FormatException {
    return null; // bad percent-encoding or UTF-8
  }
  final text = (query['text'] ?? '').replaceAll(_invisible, '');
  if (text.trim().isEmpty) return null;
  if (_utf8Length(text) > maxPromptLinkBytes) return const OversizedLink();
  final project = query['project']?.trim();
  return PromptLink(
    text: text,
    mode: query['mode'] == 'code' ? PromptTarget.code : PromptTarget.chat,
    projectId: project == null || project.isEmpty ? null : project,
  );
}

/// What has no place in a prompt box the user is meant to review: control characters (newline and tab stay), C1
/// controls, zero-width and bidi characters, and the Unicode tag block that can hide a whole instruction.
final _invisible = RegExp(
  r'[\u0000-\u0008\u000B-\u001F\u007F-\u009F\u200B-\u200F\u202A-\u202E\u2060-\u2064\u2066-\u2069\uFEFF]'
  r'|[\u{E0000}-\u{E007F}]',
  unicode: true,
);

int _utf8Length(String s) {
  var n = 0;
  for (final r in s.runes) {
    n += r < 0x80
        ? 1
        : r < 0x800
        ? 2
        : r < 0x10000
        ? 3
        : 4;
  }
  return n;
}

/// The app route a link opens. Off desktop there is no Code composer, so a code link goes to Chat.
String routeForPrompt(PromptLink link, {required bool desktop, required String chat, required String code}) =>
    link.mode == PromptTarget.code && desktop ? code : chat;

/// The link as the page it opens will take it: off desktop a code link opens Chat, so it becomes a chat link.
PromptLink linkForHost(PromptLink link, {required bool desktop}) =>
    link.mode == PromptTarget.code && !desktop ? PromptLink(text: link.text) : link;
