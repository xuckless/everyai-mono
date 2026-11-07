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
const releaseNotes = <ReleaseNote>[];

/// The notes for [version], or null.
ReleaseNote? noteFor(String version, [List<ReleaseNote> notes = releaseNotes]) {
  for (final n in notes) {
    if (n.version == version) return n;
  }
  return null;
}
