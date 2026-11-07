/// One release's "What's new": shown once after the app updates to [version], and from Settings → About.
final class ReleaseNote {
  const ReleaseNote({required this.version, required this.items, this.title, this.date});

  /// As in pubspec.yaml / `appVersion` ("0.1.0-alpha.5").
  final String version;

  /// A short line for the release ("A cheaper execution loop"), or null.
  final String? title;

  /// When it shipped ("Nov 7"), or null.
  final String? date;

  final List<WhatsNewItem> items;
}

/// A change: a short headline and, optionally, a sentence or two under it.
final class WhatsNewItem {
  const WhatsNewItem(this.headline, [this.body]);
  final String headline;
  final String? body;
}

/// The notes per release, newest first. Add an entry when bumping `appVersion`; a version with no entry shows
/// nothing after the update.
const releaseNotes = <ReleaseNote>[
  ReleaseNote(
    version: '0.1.0-alpha.5',
    title: 'A new look, local models, and tools to test your app',
    date: 'Nov 7',
    items: [
      WhatsNewItem(
        'A new look, everywhere',
        'One EveryAI design on every OS, with dark, light and Pure black themes. A cleaner sidebar, a five-tab '
            'session panel, Settings in its own window, and the app reopens where you left it.',
      ),
      WhatsNewItem(
        'The Board',
        'Every session in Needs you, Running and Done columns. Approve, deny and answer questions right on the card.',
      ),
      WhatsNewItem(
        'Models on your computer',
        "EveryAI finds Ollama, LM Studio, llama.cpp, Jan, vLLM, MLX and Apple's on-device model. Settings → Local "
            'models offers one-click packs sized to your machine.',
      ),
      WhatsNewItem(
        'Your keys stay on your computer',
        'Chats on local models and on your own keys now run on a server inside the app, not ours. Web search works '
            'without a key.',
      ),
      WhatsNewItem(
        'Every process opens in a terminal',
        'Click a shell, dev server or Docker container in Processes to see its whole log and type into it.',
      ),
      WhatsNewItem(
        'A live Preview',
        'The agent and the Preview share one browser. Watch it work with a ghost cursor, take control, and give it '
            'back.',
      ),
      WhatsNewItem(
        'Agents can test the app they build',
        'The new app tool sees and operates web and Electron pages, Flutter and React Native apps, the iOS Simulator, '
            'the Android emulator and macOS windows: screenshots, elements, clicks, typing and logs. Windows and Linux '
            'windows are in early shape.',
      ),
      WhatsNewItem(
        'Safe hands',
        "Real clicks and keys only reach the app's own window, never password fields, and pause while you use the "
            'mouse or keyboard. Real input on macOS asks once (Settings → Code → Driving apps).',
      ),
    ],
  ),
];

/// The notes for [version], or null.
ReleaseNote? noteFor(String version, [List<ReleaseNote> notes = releaseNotes]) {
  for (final n in notes) {
    if (n.version == version) return n;
  }
  return null;
}
