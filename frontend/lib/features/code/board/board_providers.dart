import 'dart:convert';
import 'dart:ui' show Color;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/preferences.dart';
import '../domain/code_session.dart';
import '../domain/transcript.dart';
import '../ui/transcript/transcript_items.dart' show approvalTitle;

/// The Board's columns.
enum BoardColumn {
  needsYou('Needs you'),
  running('Running'),
  done('Done');

  const BoardColumn(this.label);
  final String label;

  static BoardColumn of(SessionStatus s) => switch (s) {
    SessionStatus.needsInput => needsYou,
    SessionStatus.running || SessionStatus.starting => running,
    SessionStatus.idle || SessionStatus.done || SessionStatus.failed => done,
  };
}

/// A harness's mark on the Board: two letters on its colour (no logos).
({String letters, Color color}) harnessMark(String harness) => switch (harness) {
  everyaiHarnessName => (letters: 'EA', color: const Color(0xFF7756E4)),
  'claude-code' => (letters: 'CC', color: const Color(0xFFC9694A)),
  'codex' => (letters: 'CX', color: const Color(0xFF10A37F)),
  'opencode' => (letters: 'OC', color: const Color(0xFF4B5563)),
  'gemini' => (letters: 'GM', color: const Color(0xFF3B6FE0)),
  _ => (
    letters: harness.replaceAll(RegExp('^acp:|^terminal:'), '').padRight(2).substring(0, 2).toUpperCase(),
    color: Color(0xFF000000 | (harness.hashCode * 2654435761 & 0x7F7F7F) + 0x303030),
  ),
};

/// What a session is doing, in one line, from its live transcript: the approval or question it waits on, else its
/// latest step or words. Empty when there is nothing to say.
String boardActivity(Transcript t) {
  if (t.pending.isNotEmpty) {
    final title = approvalTitle(t.pending.first);
    return t.pending.length == 1 ? title : '$title (+${t.pending.length - 1})';
  }
  for (final item in t.items.reversed) {
    switch (item) {
      case QuestionItem(:final questions, answers: null) when questions.isNotEmpty:
        return 'Asked: ${questions.first.question}';
      case StepItem(:final step):
        return stepTitle(step.call);
      case ExploreGroup(:final steps) when steps.isNotEmpty:
        return stepTitle(steps.last.call);
      case SubagentItem(:final step):
        return 'Subagent: ${step.call.summary.isEmpty ? step.call.toolName : step.call.summary}';
      case AgentText(:final text) when text.trim().isNotEmpty:
        return text.trim().split('\n').first;
      case UserTurn():
        if (t.streaming.trim().isNotEmpty) return t.streaming.trim().split('\n').last;
        return '';
      default:
        continue;
    }
  }
  return '';
}

/// Forks and subagents the user put on the Board (a top-level session is always there). Preferences
/// `code.board.detached`, a JSON list of session ids.
final boardDetachedProvider = NotifierProvider<BoardDetached, Set<String>>(BoardDetached.new);

final class BoardDetached extends Notifier<Set<String>> {
  static const key = 'code.board.detached';

  @override
  Set<String> build() {
    final raw = ref.read(preferencesProvider)[key];
    if (raw == null) return const {};
    try {
      return {...(jsonDecode(raw) as List).whereType<String>()};
    } on Object {
      return const {};
    }
  }

  void toggle(String id) {
    state = state.contains(id) ? ({...state}..remove(id)) : {...state, id};
    ref.read(preferencesProvider)[key] = jsonEncode([...state]);
  }
}

/// The sessions the Board shows: every top-level session plus the detached forks, newest first.
List<CodeSessionInfo> boardSessions(List<CodeSessionInfo> all, Set<String> detached) => [
  for (final s in all)
    if (s.parentId == null || detached.contains(s.id)) s,
]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
