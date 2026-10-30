import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../harness/events.dart' show ExecutionStatus;
import 'transcript.dart';

/// How many times `/goal` sends the agent back to work before it gives up.
const defaultGoalTurns = 20;

/// The most turns one `/goal` may ask for.
const maxGoalTurns = 100;

enum GoalStatus {
  /// Waiting for the agent to finish a turn.
  active,

  /// The judge is reading the session.
  checking,

  /// The judge found the objective met.
  met,

  /// Every turn of the budget was used and the objective isn't met.
  outOfTurns,

  /// The agent stopped on the user: a question, a plan or an approval.
  waiting,

  /// The loop stopped: the agent failed, or the judge couldn't answer.
  paused;

  bool get settled => this == met || this == outOfTurns || this == paused;
}

/// A standing objective for a Code session (`/goal`): after each turn a cheap
/// judge reads the session, and while the objective isn't met and turns
/// remain, the agent is sent back to it.
@immutable
final class Goal {
  const Goal({
    required this.objective,
    this.budget = defaultGoalTurns,
    this.used = 0,
    this.status = GoalStatus.active,
    this.note = '',
  });

  final String objective;

  /// Continue messages it may send.
  final int budget;

  /// Continue messages sent so far.
  final int used;
  final GoalStatus status;

  /// The judge's latest reason, or why the loop stopped.
  final String note;

  int get left => budget - used;

  Goal copyWith({int? used, GoalStatus? status, String? note}) => Goal(
    objective: objective,
    budget: budget,
    used: used ?? this.used,
    status: status ?? this.status,
    note: note ?? this.note,
  );

  String get statusLabel => switch (status) {
    GoalStatus.active => 'Working on it · turn ${used + 1} of ${budget + 1}',
    GoalStatus.checking => 'Checking the goal…',
    GoalStatus.met => 'Goal met',
    GoalStatus.outOfTurns => 'Out of turns ($budget used)',
    GoalStatus.waiting => 'Waiting on you',
    GoalStatus.paused => 'Paused',
  };
}

/// What `/goal <args>` asks for: the objective and a turn budget given as
/// `--turns N` (or `turns=N`) anywhere in the text. Null when no objective is left.
({String objective, int budget})? parseGoalArgs(String args) {
  var budget = defaultGoalTurns;
  final flag = RegExp(r'(?:^|\s)(?:--turns[\s=]+|turns\s*[=:]\s*)(\d+)(?=\s|$)', caseSensitive: false);
  final text = args.replaceAllMapped(flag, (m) {
    budget = int.parse(m[1]!).clamp(1, maxGoalTurns);
    return ' ';
  }).trim();
  if (text.isEmpty) return null;
  return (objective: text, budget: budget);
}

/// What the session is doing when a turn ends, for the goal loop.
enum GoalMoment {
  /// The agent finished its turn: judge it.
  judge,

  /// The agent is still at work or something is queued: check again later.
  later,

  /// The agent waits for the user (a question, a plan, an approval).
  user,

  /// The agent stopped with an error.
  failed,
}

/// Whether a goal should be judged now, from the session's [t] and whether
/// messages are [queued].
GoalMoment goalMoment(Transcript t, {bool queued = false}) {
  if (t.pending.isNotEmpty || t.openQuestion != null || t.openPlan != null) return GoalMoment.user;
  if (t.status == ExecutionStatus.error || t.status == ExecutionStatus.stuck) return GoalMoment.failed;
  if (t.running || queued || t.openSubagents.isNotEmpty) return GoalMoment.later;
  if (t.status == ExecutionStatus.finished || t.status == ExecutionStatus.idle) return GoalMoment.judge;
  return GoalMoment.later;
}

/// The judge's answer.
@immutable
final class GoalVerdict {
  const GoalVerdict({required this.met, this.reason = '', this.next = ''});
  final bool met;
  final String reason;

  /// What the agent should do next, when it isn't met.
  final String next;
}

/// The judge's messages: what it is for, the session [record] so far and the [objective].
List<Map<String, Object?>> goalJudgeRequest({required String record, required String objective}) => [
  {'role': 'system', 'content': _judgeSystem},
  {
    'role': 'user',
    'content':
        '<session-record>\n${record.trim().isEmpty ? '(nothing has happened yet)' : record.trim()}\n</session-record>\n\n'
        '<goal>\n${objective.trim()}\n</goal>',
  },
];

/// Written for this app: a strict, evidence-based check that answers in JSON.
const _judgeSystem = '''
You check whether a coding agent has reached a goal a developer set for it. You get the record of the agent's session (the developer's messages, the agent's replies, its tool calls and shortened results) and the goal.

- The goal is met only when the record shows it: the change is made and, where the goal implies it, checked (tests or a build ran and passed, the output was looked at). The agent saying it is done is not enough on its own.
- If part of the goal is missing, unverified or failing, it is not met.
- When it isn't met, say in one or two sentences what the agent should do next, concretely (which test fails, which part is missing).

Reply with only a JSON object, no prose around it:
{"met": true or false, "reason": "one sentence on why", "next": "what to do next, or an empty string when met"}''';

/// The judge's reply as a verdict; a reply that can't be read is null (the
/// loop pauses rather than guessing).
GoalVerdict? parseGoalVerdict(String reply) {
  final start = reply.indexOf('{');
  final end = reply.lastIndexOf('}');
  if (start >= 0 && end > start) {
    try {
      final json = jsonDecode(reply.substring(start, end + 1));
      if (json case {'met': final bool met}) {
        String str(String k) => json[k] is String ? (json[k] as String).trim() : '';
        return GoalVerdict(met: met, reason: str('reason'), next: str('next'));
      }
    } on FormatException {
      // Fall through to the plain-text reading.
    }
  }
  final t = reply.trim().toLowerCase();
  if (RegExp(r'^(met|yes|done)\b').hasMatch(t)) return const GoalVerdict(met: true);
  if (RegExp(r'^(not met|no)\b').hasMatch(t)) return const GoalVerdict(met: false);
  return null;
}

/// The first message of a goal, sent when the agent is idle.
String goalStartMessage(Goal goal) =>
    'Goal: ${goal.objective}\n\n'
    'Work toward this until it is done and verified. After each of your turns a check reads the session and, if '
    'the goal is not met yet, sends you back to it (up to ${goal.budget} more times).';

/// Sends the agent back to work: the goal, what the check found, and what's next.
String goalContinueMessage(Goal goal, GoalVerdict verdict) {
  final out = StringBuffer('The goal is not met yet, so keep going.\n\nGoal: ${goal.objective}\n');
  if (verdict.reason.isNotEmpty) out.write('Check: ${verdict.reason}\n');
  if (verdict.next.isNotEmpty) out.write('Next: ${verdict.next}\n');
  final left = goal.left - 1;
  out.write(
    '\nThis is automatic follow-up ${goal.used + 1} of ${goal.budget}'
    '${left <= 0 ? '; it is the last one, so finish or say clearly what blocks you.' : '.'}',
  );
  return out.toString();
}
