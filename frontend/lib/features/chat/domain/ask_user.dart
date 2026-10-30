import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../questions/domain/questions.dart';
import 'message.dart';

/// Chat's question tool. The app runs it itself (it is declared in
/// `client_tools`), so the model's turn waits until the user answers the card
/// or replies in the composer, and the answer comes back as the tool result.
const askUserTool = 'ask_user';

/// What became of an `ask_user` call, kept as its [ToolCallPart.resultJson].
@immutable
final class AskUserOutcome {
  const AskUserOutcome.answered(this.answers) : reply = null;
  const AskUserOutcome.replied(String this.reply) : answers = const [];

  /// One per question, in order; empty when the user [reply]ed instead.
  final List<QuestionAnswer> answers;

  /// What the user wrote in the composer instead of picking options.
  final String? reply;

  String toJson() => jsonEncode(
    reply != null
        ? {'reply': reply}
        : {
            'answers': [
              for (final a in answers)
                {'selected': a.selected.toList()..sort(), if (a.other.trim().isNotEmpty) 'other': a.other.trim()},
            ],
          },
  );

  /// Null when [json] is absent or not an outcome.
  static AskUserOutcome? fromJson(String? json) {
    if (json == null || json.isEmpty) return null;
    try {
      return switch (jsonDecode(json)) {
        {'reply': final String reply} => AskUserOutcome.replied(reply),
        {'answers': final List<Object?> list} => AskUserOutcome.answered([
          for (final a in list)
            if (a is Map<String, Object?>)
              QuestionAnswer(
                selected: {
                  for (final i in (a['selected'] as List<Object?>? ?? const []))
                    if (i is int) i,
                },
                other: a['other'] as String? ?? '',
              )
            else
              const QuestionAnswer(),
        ]),
        _ => null,
      };
    } on FormatException {
      return null;
    }
  }

  /// The tool result the model reads.
  String resultFor(List<Question> questions) => reply != null
      ? 'The user replied in their own words instead of picking options:\n\n${reply!.trim()}'
      : answersMessage(questions, answers);
}

/// The questions of an `ask_user` call (at most 4).
List<Question> askUserQuestions(ToolCallPart part) {
  try {
    return switch (jsonDecode(part.argumentsJson)) {
      final Map<String, Object?> args => Question.listFrom(args),
      _ => const [],
    };
  } on FormatException {
    return const [];
  }
}

/// An earlier `ask_user` call as the model sees it in later turns.
String askUserNote(ToolCallPart part) {
  final questions = askUserQuestions(part);
  final outcome = AskUserOutcome.fromJson(part.resultJson);
  if (outcome == null) {
    return '[Asked the user: ${questions.map((q) => q.question).join(' / ')} (no answer)]';
  }
  return '[Asked the user with ask_user]\n${outcome.resultFor(questions)}';
}
