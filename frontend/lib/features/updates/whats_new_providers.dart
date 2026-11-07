import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/version.dart';
import '../../core/preferences.dart';
import 'domain/whats_new.dart';

/// The release notes the app knows (a provider so tests can supply their own).
final releaseNotesProvider = Provider<List<ReleaseNote>>((_) => releaseNotes);

/// This build's notes, or null when it has none.
final currentReleaseNoteProvider = Provider<ReleaseNote?>(
  (ref) => noteFor(appVersion, ref.watch(releaseNotesProvider)),
);

/// The notes to show once at launch: this build's, when the user came from an older build and hasn't seen them.
/// A fresh install marks them seen when the onboarding is accepted, so new users aren't shown them.
final whatsNewProvider = NotifierProvider<WhatsNew, ReleaseNote?>(WhatsNew.new);

final class WhatsNew extends Notifier<ReleaseNote?> {
  static const key = 'whats_new.seen';

  @override
  ReleaseNote? build() {
    final note = ref.watch(currentReleaseNoteProvider);
    return note == null || ref.watch(preferencesProvider)[key] == appVersion ? null : note;
  }

  void markSeen() {
    ref.read(preferencesProvider)[key] = appVersion;
    state = null;
  }
}
