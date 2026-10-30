import 'package:flutter/foundation.dart';

import '../harness/events.dart';
import '../settings/agent_settings.dart' show AgentType;
import 'agent_mode.dart';
import 'transcript.dart';

/// The subagent client tool: the app runs each call as a child conversation
/// (fresh context, same folder, depth 1) and hands its final message back.
const taskTool = 'run_subagent';

/// How many subagents one session runs at a time; calls past it are refused.
const maxConcurrentSubagents = 4;

bool isTaskCall(ActionCall call) => call.toolName == taskTool;

/// What the parent's call asks for.
@immutable
final class SubagentTask {
  const SubagentTask({required this.description, required this.prompt, this.agent = ''});

  factory SubagentTask.of(ActionCall call) => SubagentTask(
    description: call.str('description').trim(),
    prompt: call.str('prompt').trim(),
    agent: call.str('agent').trim(),
  );

  /// A few words, shown on the card and as the child session's title.
  final String description;
  final String prompt;

  /// A project-defined role (`settings.json` "agents"), or ''.
  final String agent;

  String get title => description.isNotEmpty ? description : 'Subagent';
}

/// The first message of a child conversation: the task, with the role's own
/// instructions when the parent named one the project defines.
String subagentBrief(SubagentTask task, {AgentType? role}) {
  final out = StringBuffer('Task: ${task.title}\n');
  if (role != null) {
    out.write('Role: ${role.name}. ${role.description}\n');
    if (role.prompt.isNotEmpty) out.write('${role.prompt}\n');
  }
  out.write('\n${task.prompt.isEmpty ? task.description : task.prompt}');
  return out.toString();
}

/// A child conversation runs in the parent's mode: a Plan session gets
/// read-only subagents, and only a Full auto session gets Full auto ones.
AgentMode subagentMode(AgentMode parent) => parent;

/// Appended to a child conversation's system prompt (it replaces nothing, so
/// the rules above it stay cache-stable across sessions).
const subagentRules = '''
<SUBAGENT>
You are a subagent. Another agent handed you one task, and your final message is the report it gets back. Nobody
reads along while you work and you cannot ask the user anything; you also cannot start subagents of your own.
ask_user_question and present_plan do not exist in this conversation, whatever the rules above say about them.
- Do the task you were given and nothing else, within the limits it sets (only investigate, or change files).
- Work on your own until the task is done or you are blocked. Then end with one final message that gives exactly
  what the task asked for: findings with file paths and line numbers, what you changed and how you checked it, or
  what blocked you. That message is all the other agent will see, so make it complete and concise.
</SUBAGENT>''';

/// What the parent's tool says happens after the call, by answer path.
const _taskEndsTurn =
    'After calling it, end your turn: the reports arrive together in the next user message once every subagent '
    'has finished.';
const _taskHeld = 'The call waits while the subagent works; its report comes back as the result of this call.';

const taskSpec = <String, Object?>{
  'name': taskTool,
  'description':
      'Hand a self-contained piece of work to a subagent: a new agent with an empty context that works in the same '
      'folder with the same tools and reports back when it is done. Good uses: a broad search or investigation whose '
      'raw output you do not need to see, or an independent change you can describe completely. Not worth it for '
      'reading one file or a single grep; do those yourself. The subagent sees nothing of this conversation and '
      'cannot ask the user or you anything, so the prompt must stand alone: the goal, the files or leads you already '
      'have, whether it may change files or should only investigate, and exactly what its report must contain. It '
      'runs in the same mode as this session (a Plan session gets a read-only subagent). Several calls in one reply '
      'run in parallel, up to $maxConcurrentSubagents at a time. The user does not see the report, so pass on what '
      'matters. $_taskEndsTurn',
  'parameters': {
    'type': 'object',
    'properties': {
      'description': {'type': 'string', 'description': 'What the subagent does, in 3-6 words'},
      'prompt': {'type': 'string', 'description': 'The complete, self-contained instructions'},
      'agent': {
        'type': 'string',
        'description': 'Optional: a subagent role the project defines (see AGENT_TYPES, if present)',
      },
    },
    'required': ['description', 'prompt'],
  },
  'annotations': {'readOnlyHint': false, 'destructiveHint': false},
};

/// [taskSpec] for a session: with [held], the report is the call's result.
Map<String, Object?> taskSpecFor({required bool held}) => held
    ? {...taskSpec, 'description': (taskSpec['description']! as String).replaceAll(_taskEndsTurn, _taskHeld)}
    : taskSpec;

enum SubagentStatus {
  completed,
  failed,

  /// The user stopped it (or the parent's turn) before it finished.
  stopped,

  /// Refused before it started (too many at once, or it couldn't start).
  notStarted;

  String get wire => switch (this) {
    notStarted => 'not_started',
    _ => name,
  };

  static SubagentStatus parse(String s) => values.where((v) => v.wire == s).firstOrNull ?? completed;
}

/// What a subagent hands back to its parent.
@immutable
final class SubagentReport {
  const SubagentReport(this.status, this.text);
  final SubagentStatus status;
  final String text;

  @override
  bool operator ==(Object other) => other is SubagentReport && other.status == status && other.text == text;

  @override
  int get hashCode => Object.hash(status, text);
}

/// Long reports are cut so one subagent can't flood the parent's context.
const _maxReport = 24000;

/// How a child conversation ended, from its transcript, or null while it is
/// still going. [error] is the child session's own failure (couldn't connect).
SubagentReport? subagentOutcome(Transcript t, {String? error}) {
  if (error != null) return SubagentReport(SubagentStatus.failed, error);
  final last = _lastWords(t);
  return switch (t.status) {
    ExecutionStatus.finished => SubagentReport(
      SubagentStatus.completed,
      last.isEmpty ? 'The subagent finished without writing a report.' : last,
    ),
    ExecutionStatus.error || ExecutionStatus.stuck => SubagentReport(
      SubagentStatus.failed,
      [
        'The subagent stopped with an error${_lastError(t).isEmpty ? '' : ': ${_lastError(t)}'}.',
        if (last.isNotEmpty) 'Its last message:\n$last',
      ].join('\n\n'),
    ),
    _ => null,
  };
}

/// The report for a subagent the user stopped: what it had said so far.
SubagentReport stoppedReport(Transcript t) {
  final last = _lastWords(t);
  return SubagentReport(
    SubagentStatus.stopped,
    last.isEmpty
        ? 'The user stopped this subagent before it reported anything.'
        : 'The user stopped this subagent before it finished. Its last message:\n$last',
  );
}

String _lastWords(Transcript t) {
  for (final item in t.items.reversed) {
    if (item is AgentText && item.text.trim().isNotEmpty) return item.text.trim();
  }
  return '';
}

String _lastError(Transcript t) {
  for (final item in t.items.reversed) {
    if (item is NoticeItem && item.error) return item.message;
  }
  return '';
}

/// The tool steps a child has taken so far, for the parent's card.
int stepCount(Transcript t) => t.items.fold(
  0,
  (n, item) => switch (item) {
    ExploreGroup(:final steps) => n + steps.length,
    StepItem() || SubagentItem() => n + 1,
    _ => n,
  },
);

const _open = '<subagent_report id="';
final _block = RegExp(r'<subagent_report id="([^"]*)" status="([^"]*)">\n([\s\S]*?)\n</subagent_report>');

String _blocks(Map<String, SubagentReport> reports) => [
  for (final e in reports.entries)
    '$_open${e.key}" status="${e.value.status.wire}">\n'
        '${_cut(e.value.text).replaceAll('</subagent_report>', '</subagent-report>')}\n</subagent_report>',
].join('\n\n');

String _cut(String s) =>
    s.length <= _maxReport ? s : '${s.substring(0, _maxReport)}\n[… report cut at $_maxReport characters]';

/// The result of held `run_subagent` calls when the user interrupts the agent.
const subagentInterrupted =
    'Not an error: the user interrupted, so the subagent was stopped before it reported; see their next message.';

/// The user message that brings reports back to a session whose tool calls
/// end the turn.
String subagentMessage(Map<String, SubagentReport> reports) =>
    'Reports from the subagents you started (the user has not seen them):\n\n${_blocks(reports)}';

/// The result of held `run_subagent` calls: a rejection reason the agent reads as
/// the call's output.
String subagentReason(Map<String, SubagentReport> reports) =>
    'Not an error and not a refusal: the subagent ran, and this is its report (the user has not seen it).\n\n'
    '${_blocks(reports)}';

/// The reports in [text] (a [subagentMessage] or [subagentReason]) by call id;
/// empty when it has none.
Map<String, SubagentReport> parseSubagentReports(String text) {
  if (!text.contains(_open)) return const {};
  return {for (final m in _block.allMatches(text)) m[1]!: SubagentReport(SubagentStatus.parse(m[2]!), m[3]!)};
}
