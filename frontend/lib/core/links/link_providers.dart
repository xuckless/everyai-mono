import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_link.dart';

/// A prompt from a link, waiting for a composer to take it (the shell opens the page; the page fills its box).
final pendingPromptProvider = NotifierProvider<PendingPrompt, PromptLink?>(PendingPrompt.new);

final class PendingPrompt extends Notifier<PromptLink?> {
  @override
  PromptLink? build() => null;

  /// A newer link replaces an older one that nobody took.
  void offer(PromptLink link) => state = link;

  PromptLink? take() {
    final link = state;
    state = null;
    return link;
  }
}
