import 'agent_mode.dart' show askUserQuestionTool, presentPlanTool;
import 'permissions.dart' show cancelledLead;
import 'shell_readonly.dart';
import 'subagents.dart' show parseTaskNotification, taskTool;
import 'transcript.dart' show planApprovedReason;

/// The steps a Max or Ultra session goes through, in order. The harness
/// enforces them: a call the phase doesn't allow comes back as an error
/// that names the next required step, and ending a turn early earns a
/// nudge, then a pause.
enum Phase {
  research('Research'),
  questions('Questions'),
  plan('Plan'),
  build('Build'),
  verify('Verify'),
  done('Done');

  const Phase(this.label);
  final String label;

  static Phase parse(Object? s) => values.where((p) => p.name == s).firstOrNull ?? research;

  /// Before the plan is approved: only reading, research and notes.
  bool get preparing => index <= plan.index;
}

/// What the harness does when the agent ends a turn.
sealed class TurnEnd {
  const TurnEnd();
}

/// Let the turn end.
final class EndTurn extends TurnEnd {
  const EndTurn();
}

/// Add [note] as a user message and keep going.
final class Nudge extends TurnEnd {
  const Nudge(this.note);
  final String note;
}

/// Stop and tell the user ([note]): the flow is stuck.
final class Stuck extends TurnEnd {
  const Stuck(this.note);
  final String note;
}

/// The phase flow of one session: where it is and what moved it on.
final class PhaseFlow {
  PhaseFlow({
    this.ultra = false,
    this.phase = Phase.research,
    this.nudges = 0,
    Set<String>? researchers,
    this.researchReports = 0,
    this.researchPending = 0,
  }) : researchers = researchers ?? {};

  /// Ultra runs research and build as workflows the harness starts.
  final bool ultra;
  Phase phase;

  /// Nudges since the phase last moved; two, then the flow pauses.
  int nudges;

  /// Titles of the researcher subagents started (to match their notifications).
  final Set<String> researchers;
  int researchReports;

  /// Researchers started in the background whose reports haven't come.
  int researchPending;

  static const maxNudges = 2;

  /// Where the plan is written before it is presented.
  static const planFile = '.everyai/scratch/plan.md';

  String get flowName => ultra ? 'Ultra' : 'Max';

  factory PhaseFlow.fromJson(Map<String, Object?> j) => PhaseFlow(
    ultra: j['ultra'] == true,
    phase: Phase.parse(j['phase']),
    nudges: (j['nudges'] as num?)?.toInt() ?? 0,
    researchers: {...?(j['researchers'] as List<Object?>?)?.whereType<String>()},
    researchReports: (j['research_reports'] as num?)?.toInt() ?? 0,
    researchPending: (j['research_pending'] as num?)?.toInt() ?? 0,
  );

  Map<String, Object?> toJson() => {
    'ultra': ultra,
    'phase': phase.name,
    'nudges': nudges,
    'researchers': [...researchers],
    'research_reports': researchReports,
    'research_pending': researchPending,
  };

  /// Why [tool] with [args] may not run now, or null. [inScratch] says
  /// whether a path argument is under `.everyai/scratch/`.
  String? gate(String tool, Map<String, Object?> args, {required bool Function(String path) inScratch}) {
    if (!phase.preparing) return null;
    final where = '$flowName flow, ${phase.label.toLowerCase()} phase';
    switch (tool) {
      case 'write' || 'edit':
        final path = args['file_path'] as String? ?? '';
        if (inScratch(path)) return null;
        return 'Error ($where): nothing in the project changes before the plan is approved. Write notes under '
            '.everyai/scratch/ for now. Next: ${next()}';
      case 'bash':
        final command = args['command'] as String? ?? '';
        if (args['run_in_background'] != true && isReadOnlyShell(command)) return null;
        return 'Error ($where): only read-only commands run before the plan is approved. Next: ${next()}';
      case askUserQuestionTool:
        if (phase == Phase.research) {
          return 'Error ($where): ask once research has reported, so the questions are about what it found. '
              'Next: ${next()}';
        }
      case presentPlanTool:
        if (phase != Phase.plan) return 'Error ($where): not yet. Next: ${next()}';
    }
    return null;
  }

  /// The next required step, said to the agent.
  String next() => switch (phase) {
    Phase.research =>
      researchPending > 0
          ? 'wait for the researcher reports (end your turn; they wake you).'
          : ultra
          ? 'read the research workflow\'s reports when they arrive.'
          : 'start one or more forks with role "researcher" (run_subagent, run_in_background true), one per question '
                'worth answering: how this is best built, which libraries or reference code to borrow from, what '
                'goes wrong. Then end your turn until they report.',
    Phase.questions =>
      'ask the user about the directions research found with ask_user_question: the choices that change what gets '
          'built, your recommendation first.',
    Phase.plan =>
      'write the plan to $planFile (the parts, which research each uses, how each is checked), then present_plan.',
    Phase.build =>
      ultra
          ? 'the build workflow runs the plan; integrate and check what it merges.'
          : 'build the plan: give each independent part to a fork (isolation "worktree") and build the rest '
                'yourself, to the Thorough standard.',
    Phase.verify =>
      'verify the whole as the user will use it (run it, click through it, screenshots), fix what is wrong, then '
          'give your final report.',
    Phase.done => 'nothing: the flow is done.',
  };

  /// The note that opens [phase], kept in the conversation.
  String note({bool stuck = false}) =>
      '<everyai-phase flow="${ultra ? 'ultra' : 'max'}" phase="${phase.name}"${stuck ? ' stuck="true"' : ''}>\n'
      '${stuck ? 'The $flowName flow is stuck at the ${phase.label.toLowerCase()} phase.' : 'Phase: ${phase.label}.'} '
      'Next: ${next()}\n</everyai-phase>';

  /// A call was made: remember researchers.
  void onCall(String tool, Map<String, Object?> args) {
    if (tool != taskTool || (args['role'] ?? args['agent']) != 'researcher') return;
    researchers.add((args['description'] as String? ?? '').trim().toLowerCase());
  }

  /// A held call got its answer ([reason], what the app sent back). True
  /// when the phase moved.
  bool onAnswer(String tool, Map<String, Object?> args, String reason) {
    switch (tool) {
      case taskTool when (args['role'] ?? args['agent']) == 'researcher':
        if (reason.startsWith('Started in the background')) {
          researchPending++;
          return false;
        }
        researchReports++;
        return _advanceFrom(Phase.research);
      case askUserQuestionTool when reason.trim().isNotEmpty && !_cancelled(reason):
        return _advanceFrom(Phase.questions);
      case presentPlanTool when reason.startsWith(planApprovedReason.substring(0, 40)):
        return _advanceFrom(Phase.plan);
    }
    return false;
  }

  /// A user message arrived: a researcher's background report moves research on.
  bool onMessage(String text) {
    final n = parseTaskNotification(text);
    if (n == null || !researchers.contains(n.title.trim().toLowerCase())) return false;
    if (researchPending > 0) researchPending--;
    researchReports++;
    return _advanceFrom(Phase.research);
  }

  /// The user moved it on by hand (`/skip-phase`).
  void skip() {
    if (phase != Phase.done) phase = Phase.values[phase.index + 1];
    nudges = 0;
  }

  /// The agent ended its turn: let it, nudge it, or stop the flow.
  TurnEnd onTurnEnd() {
    switch (phase) {
      case Phase.done:
        return const EndTurn();
      case Phase.research when researchPending > 0:
        // Waiting for background researchers is right.
        return const EndTurn();
      case Phase.build:
        phase = Phase.verify;
        nudges = 0;
        return Nudge(note());
      case Phase.verify:
        phase = Phase.done;
        return const EndTurn();
      case Phase.research || Phase.questions || Phase.plan:
        if (nudges >= maxNudges) return Stuck(note(stuck: true));
        nudges++;
        return Nudge(note());
    }
  }

  bool _advanceFrom(Phase from) {
    if (phase != from) return false;
    phase = Phase.values[from.index + 1];
    nudges = 0;
    return true;
  }

  static bool _cancelled(String reason) => reason.startsWith(cancelledLead);
}

/// The phase note at the start of [text], or null: (flow, phase, stuck, body).
({String flow, Phase phase, bool stuck, String body})? parsePhaseNote(String text) {
  final m = RegExp(r'^<everyai-phase flow="(\w+)" phase="(\w+)"( stuck="true")?>\n([\s\S]*?)\n</everyai-phase>')
      .firstMatch(text.trimLeft());
  if (m == null) return null;
  return (flow: m[1]!, phase: Phase.parse(m[2]), stuck: m[3] != null, body: m[4]!);
}
