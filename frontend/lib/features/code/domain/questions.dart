import 'dart:convert';

import 'package:flutter/foundation.dart';

/// One question in an `ask_user_question` card.
@immutable
final class Question {
  const Question({required this.question, required this.options, this.header = '', this.multiSelect = false});

  final String question;
  final String header;
  final bool multiSelect;
  final List<QuestionOption> options;

  static List<Question> listFrom(Map<String, Object?> args) => [
    for (final q in (args['questions'] as List<Object?>? ?? const []))
      if (q is Map<String, Object?>)
        Question(
          question: q['question'] as String? ?? '',
          header: q['header'] as String? ?? '',
          multiSelect: q['multi_select'] == true || q['multiSelect'] == true,
          options: [
            for (final o in (q['options'] as List<Object?>? ?? const []))
              if (o is Map<String, Object?>)
                QuestionOption(o['label'] as String? ?? '', o['description'] as String? ?? '')
              else if (o is String)
                QuestionOption(o, ''),
          ],
        ),
  ].take(4).toList();
}

@immutable
final class QuestionOption {
  const QuestionOption(this.label, this.description);
  final String label;
  final String description;
}

/// The user's answer to one [Question]: picked option indices plus an
/// optional "Other" text.
@immutable
final class QuestionAnswer {
  const QuestionAnswer({this.selected = const {}, this.other = ''});

  final Set<int> selected;
  final String other;

  bool get isEmpty => selected.isEmpty && other.trim().isEmpty;

  List<String> labels(Question q) => [
    for (final i in selected.toList()..sort())
      if (i < q.options.length) q.options[i].label,
    if (other.trim().isNotEmpty) other.trim(),
  ];

  QuestionAnswer copyWith({Set<int>? selected, String? other}) =>
      QuestionAnswer(selected: selected ?? this.selected, other: other ?? this.other);

  @override
  bool operator ==(Object other) =>
      other is QuestionAnswer && setEquals(other.selected, selected) && other.other == this.other;

  @override
  int get hashCode => Object.hash(Object.hashAllUnordered(selected), other);
}

/// The answers go back to the agent as a normal user message: a readable
/// summary followed by the same answers as JSON.
const answersHeading = 'Answers to your questions:';

String answersMessage(List<Question> questions, List<QuestionAnswer> answers) {
  final lines = <String>[answersHeading];
  final json = <Map<String, Object?>>[];
  for (final (i, q) in questions.indexed) {
    final a = i < answers.length ? answers[i] : const QuestionAnswer();
    final labels = a.labels(q);
    lines.add('${i + 1}. ${q.question} → ${labels.isEmpty ? '(no answer)' : labels.join(', ')}');
    json.add({
      'question': q.question,
      'selected': [
        for (final s in a.selected.toList()..sort())
          if (s < q.options.length) q.options[s].label,
      ],
      if (a.other.trim().isNotEmpty) 'other': a.other.trim(),
    });
  }
  return '${lines.join('\n')}\n\n```json\n${jsonEncode({'answers': json})}\n```';
}

/// Reads [answersMessage] back (for transcript history). Null when [text]
/// isn't an answers message.
List<QuestionAnswer>? parseAnswers(String text, List<Question> questions) {
  if (!text.startsWith(answersHeading)) return null;
  final match = RegExp(r'```json\n([\s\S]*?)\n```').firstMatch(text);
  if (match == null) return null;
  try {
    final decoded = jsonDecode(match.group(1)!) as Map<String, Object?>;
    final list = decoded['answers'] as List<Object?>? ?? const [];
    return [
      for (final (i, q) in questions.indexed)
        if (list.elementAtOrNull(i) case final Map<String, Object?> a)
          QuestionAnswer(
            selected: {
              for (final label in (a['selected'] as List<Object?>? ?? const []))
                if (q.options.indexWhere((o) => o.label == label) case final idx when idx >= 0) idx,
            },
            other: a['other'] as String? ?? '',
          )
        else
          const QuestionAnswer(),
    ];
  } on Object {
    return null;
  }
}
