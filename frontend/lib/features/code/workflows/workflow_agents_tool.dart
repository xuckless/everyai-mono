// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

// The lead's one tool for a workflow run's agents (owner, 2026-11-08): when a run stalls the lead hears first and may
// look at the agents, message one, restart one (the same agent, a new turn that keeps its context), stop the run, or
// say the run is fine (ignore). The user hears only when the lead does nothing about the stall for another period.

import 'dart:convert';

import 'workflow_engine.dart' show StalledAgent;
import 'workflow_summary.dart' show workflowDuration;

const workflowAgentsTool = 'workflow_agents';

/// Prompt reason: a stalled workflow agent (a hung command, a loop, an agent waiting on nothing) used to sit until
/// the 2-hour cap; that cap is gone, so the lead is asked first and needs a way to act on the run's agents.
const workflowAgentsSpec = <String, Object?>{
  'name': workflowAgentsTool,
  'description':
      "Look at and act on the agents of this session's running workflow, mainly when a <workflow-stalled> note says "
      'it made no progress. Actions: "list" (each live agent, its phase and how long it has shown nothing), '
      '"inspect" (one agent\'s status and latest steps), "message" (tell one agent something; it reads it after its '
      'current step), "restart" (stop its current turn and have it go on in a new one, keeping its context: for an '
      'agent stuck on a hung command or a loop), "ignore" (the run is fine, e.g. a long test that prints nothing; the '
      'stall clock starts over), "stop" (stop the whole run; its result arrives as usual) and "off_track" (a '
      '<workflow-checkpoint> asked you to compare a phase with the task and it went off it: the run pauses and the '
      'user decides; put why in text). The user is told about a stall only if you do nothing about it. Returns at '
      'once.',
  'parameters': {
    'type': 'object',
    'properties': {
      'action': {
        'type': 'string',
        'enum': ['list', 'inspect', 'message', 'restart', 'ignore', 'stop', 'off_track'],
      },
      'agent': {'type': 'string', 'description': 'The agent\'s key or id from "list" (inspect, message, restart)'},
      'text': {
        'type': 'string',
        'description': 'The message (message), what to do differently (restart), or why it is off track (off_track)',
      },
    },
    'required': ['action'],
  },
};

/// The note a restarted agent gets as its new turn.
String workflowRestartNote(String? why) =>
    'Your last turn was stopped because it made no progress for a while. Go on with your task from where you are'
    '${why == null || why.trim().isEmpty ? '' : '; the agent that runs the workflow says: ${why.trim()}'}. Don\'t '
    'rerun a command that hung without a timeout.';

String _idle(Duration? d) => d == null ? 'unknown' : workflowDuration(d);

/// The lead's notice that run [name] stalled: who has been quiet, and what it can do.
String workflowStalledNote(String name, Duration after, List<StalledAgent> agents) {
  final who = [for (final a in agents) '- ${a.label} (agent ${a.key}): nothing for ${_idle(a.idle)}'].join('\n');
  return '<workflow-stalled name="${name.replaceAll('"', "'")}">The $name run made no progress for '
      '${workflowDuration(after)}.\n$who\nLook with `$workflowAgentsTool` (inspect), then message or restart a stuck '
      'agent, stop the run, or ignore it when the work is just slow. If you do nothing, the user is told in '
      '${workflowDuration(after)}.</workflow-stalled>';
}

String _cut(String s, int max) => s.length <= max ? s : '${s.substring(0, max)}…';

/// What the drift check reads at a phase's end: the run's arguments and what the phase's agents answered.
String driftText(String name, Object? args, String phase, List<({String label, String text})> results) => [
  'Workflow: $name',
  'Its task (the arguments the user started it with):\n${_cut(args == null ? '' : jsonEncode(args), 4000)}',
  'The phase that just ended: $phase',
  for (final r in results.take(12)) '--- ${r.label} answered:\n${_cut(r.text, 1500)}',
].join('\n\n');

/// Prompt reason: a run that wandered off its task (agents fixing other things, rewriting what wasn't asked) ran to
/// the end before anyone noticed; the owner wants a check at each phase's end that only pauses when sure.
const driftInstructions =
    'You check one phase of a multi-agent workflow against the task it was started for. Answer false only when the '
    "agents' answers clearly work on something other than the task, or plainly undo or ignore what it asks. Slow "
    'progress, partial results, failures and reasonable steps toward the task are on track.';

/// The question the decider answers (true: on track).
const driftQuestionPrompt = 'Is the work of this phase still on track for the task?';

/// The outside lead's drift check (it costs EveryAI nothing): the same question, answered with workflow_agents only
/// when the run is off track.
String workflowDriftAsk(String name, String phase, String text) =>
    '<workflow-checkpoint name="${name.replaceAll('"', "'")}">The $phase phase of the $name run ended. Compare what '
    'its agents answered with the task. Only if they clearly work on something else or undo what it asks, call '
    '`$workflowAgentsTool` with {"action": "off_track", "text": "<one sentence: why>"}: the run pauses and the user '
    "decides. Otherwise do nothing and don't reply about it.\n\n$text</workflow-checkpoint>";
