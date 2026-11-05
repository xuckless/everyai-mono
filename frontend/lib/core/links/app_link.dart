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
  // Control characters (except newline and tab) have no place in a prompt box.
  final text = (uri.queryParameters['text'] ?? '').replaceAll(RegExp(r'[\u0000-\u0008\u000B-\u001F\u007F]'), '');
  if (text.trim().isEmpty) return null;
  if (_utf8Length(text) > maxPromptLinkBytes) return const OversizedLink();
  final project = uri.queryParameters['project']?.trim();
  return PromptLink(
    text: text,
    mode: uri.queryParameters['mode'] == 'code' ? PromptTarget.code : PromptTarget.chat,
    projectId: project == null || project.isEmpty ? null : project,
  );
}

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
