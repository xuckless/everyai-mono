// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

// The lead's one tool for a workflow run's agents (owner, 2026-11-08): when a run stalls the lead hears first and may
// look at the agents, message one, restart one (the same agent, a new turn that keeps its context), stop the run, or
// say the run is fine (ignore). The user hears only when the lead does nothing about the stall for another period.

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
      'stall clock starts over) and "stop" (stop the whole run; its result arrives as usual). The user is told about '
      'a stall only if you do nothing about it. Returns at once.',
  'parameters': {
    'type': 'object',
    'properties': {
      'action': {
        'type': 'string',
        'enum': ['list', 'inspect', 'message', 'restart', 'ignore', 'stop'],
      },
      'agent': {'type': 'string', 'description': 'The agent\'s key or id from "list" (inspect, message, restart)'},
      'text': {'type': 'string', 'description': 'The message (message), or what to do differently (restart)'},
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
