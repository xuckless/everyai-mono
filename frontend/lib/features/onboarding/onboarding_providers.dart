import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/version.dart';
import '../../core/preferences.dart';
import '../updates/whats_new_providers.dart';

/// Whether the user went through the entry screen. Once is enough: an update keeps it (and shows What's new
/// instead). The stored value is the version it was accepted in.
final onboardingAcceptedProvider = NotifierProvider<OnboardingAccepted, bool>(OnboardingAccepted.new);

final class OnboardingAccepted extends Notifier<bool> {
  static const key = 'onboarding.accepted';

  @override
  bool build() => ref.watch(preferencesProvider)[key]?.isNotEmpty ?? false;

  void accept() {
    final prefs = ref.read(preferencesProvider);
    prefs[key] = appVersion;
    // A new user starts on this build: its notes aren't news to them.
    prefs[WhatsNew.key] = appVersion;
    state = true;
  }
}
