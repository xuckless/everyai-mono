import 'package:flutter/foundation.dart';

/// Tokens and spend for a conversation or Code session, plus how full the
/// model's context window is (the latest call's size).
@immutable
final class UsageTotals {
  const UsageTotals({
    this.calls = 0,
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.cachedTokens = 0,
    this.cacheWriteTokens = 0,
    this.chargedMicros = 0,
    this.lastPromptTokens = 0,
    this.lastCompletionTokens = 0,
  });

  static const zero = UsageTotals();

  /// `GET /v1/usage/session/:id`, and the JSON stored in a chat `UsagePart`.
  factory UsageTotals.fromJson(Map<String, Object?> j) {
    int n(String k) => (j[k] as num?)?.toInt() ?? 0;
    return UsageTotals(
      calls: n('calls'),
      promptTokens: n('prompt_tokens'),
      completionTokens: n('completion_tokens'),
      cachedTokens: n('cached_tokens'),
      cacheWriteTokens: n('cache_write_tokens'),
      chargedMicros: n('charged_micros'),
      lastPromptTokens: n('last_prompt_tokens'),
      lastCompletionTokens: n('last_completion_tokens'),
    );
  }

  Map<String, Object?> toJson() => {
    'calls': calls,
    'prompt_tokens': promptTokens,
    'completion_tokens': completionTokens,
    'cached_tokens': cachedTokens,
    'cache_write_tokens': cacheWriteTokens,
    'charged_micros': chargedMicros,
    'last_prompt_tokens': lastPromptTokens,
    'last_completion_tokens': lastCompletionTokens,
  };

  final int calls;

  /// Input tokens over all calls, cached ones included.
  final int promptTokens;
  final int completionTokens;
  final int cachedTokens;
  final int cacheWriteTokens;

  /// What the user was charged, in millionths of a dollar.
  final int chargedMicros;

  /// The latest model call: what the next one starts from.
  final int lastPromptTokens;
  final int lastCompletionTokens;

  bool get isEmpty => calls == 0;
  int get totalTokens => promptTokens + completionTokens;
  int get contextTokens => lastPromptTokens + lastCompletionTokens;

  /// Share of input tokens served from the prompt cache.
  double get cacheShare => promptTokens == 0 ? 0 : cachedTokens / promptTokens;

  /// One more upstream call. [context] is false for side calls (follow-up
  /// suggestions) that don't fill this conversation's window.
  UsageTotals addCall({
    required int prompt,
    required int completion,
    int cached = 0,
    int cacheWrite = 0,
    int charged = 0,
    bool context = true,
  }) => UsageTotals(
    calls: calls + 1,
    promptTokens: promptTokens + prompt,
    completionTokens: completionTokens + completion,
    cachedTokens: cachedTokens + cached,
    cacheWriteTokens: cacheWriteTokens + cacheWrite,
    chargedMicros: chargedMicros + charged,
    lastPromptTokens: context ? prompt : lastPromptTokens,
    lastCompletionTokens: context ? completion : lastCompletionTokens,
  );

  /// Sums; the context reading comes from [other] when it has one.
  UsageTotals operator +(UsageTotals other) => UsageTotals(
    calls: calls + other.calls,
    promptTokens: promptTokens + other.promptTokens,
    completionTokens: completionTokens + other.completionTokens,
    cachedTokens: cachedTokens + other.cachedTokens,
    cacheWriteTokens: cacheWriteTokens + other.cacheWriteTokens,
    chargedMicros: chargedMicros + other.chargedMicros,
    lastPromptTokens: other.lastPromptTokens > 0 ? other.lastPromptTokens : lastPromptTokens,
    lastCompletionTokens: other.lastPromptTokens > 0 ? other.lastCompletionTokens : lastCompletionTokens,
  );

  @override
  bool operator ==(Object other) =>
      other is UsageTotals &&
      other.calls == calls &&
      other.promptTokens == promptTokens &&
      other.completionTokens == completionTokens &&
      other.cachedTokens == cachedTokens &&
      other.cacheWriteTokens == cacheWriteTokens &&
      other.chargedMicros == chargedMicros &&
      other.lastPromptTokens == lastPromptTokens &&
      other.lastCompletionTokens == lastCompletionTokens;

  @override
  int get hashCode => Object.hash(
    calls,
    promptTokens,
    completionTokens,
    cachedTokens,
    cacheWriteTokens,
    chargedMicros,
    lastPromptTokens,
    lastCompletionTokens,
  );
}

/// "950", "12.4K", "1.2M".
String formatTokens(int n) {
  if (n < 1000) return '$n';
  if (n < 1000000) return '${(n / 1000).toStringAsFixed(n < 100000 ? 1 : 0)}K';
  return '${(n / 1000000).toStringAsFixed(1)}M';
}
