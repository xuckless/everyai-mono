import 'briefing_types.dart';
import 'skill_render.dart';

/// A tool our host offers over MCP, and when the agent should reach for it. Supplied by the host lane, so no tool
/// name is fixed here.
typedef HostToolInfo = ({String name, String when});

/// A workflow the session can start, and when it fits.
typedef WorkflowInfo = ({String id, String when});

/// Everything the session briefing says: the working directory, EveryAI's tools, and the workflows it can propose.
class SessionSkillInput {
  const SessionSkillInput({
    required this.worktree,
    this.hostTools = const [],
    this.workflows = const [],
    this.noticeNonce,
  });

  final String worktree;
  final List<HostToolInfo> hostTools;

  /// The workflows this project can run (bundled, then the trusted project ones).
  final List<WorkflowInfo> workflows;

  /// The session's secret for `<everyai-notice>` tags (fork reports, workflow results); null for a fork (it gets no
  /// notices) or when the host sends none.
  final String? noticeNonce;
}

/// The session briefing: plain Markdown for each CLI's instructions slot (not a skill, so no CLI loads it twice).
/// Short on purpose (owner, 2026-11-11): an outside agent runs on its own modes, approvals and habits; EveryAI only
/// says which of its tools it offers, where the session works, and that commits carry no AI identifiers. Pure and
/// deterministic (no timestamps); what differs per session comes last, so the start is shared between sessions.
String sessionBriefing(SessionSkillInput input) {
  final b = StringBuffer()
    ..writeln('# EveryAI session')
    ..writeln()
    ..writeln('You are running inside EveryAI, a desktop app where the user watches this session.')
    ..writeln()
    ..writeln('## EveryAI tools')
    ..writeln()
    ..writeln('EveryAI offers these tools through the MCP server named `$everyaiServerName`. Use them when they help;')
    ..writeln('your own tools are fine otherwise.')
    ..writeln();
  if (input.hostTools.isEmpty) {
    b.writeln('- None are connected in this session.');
  } else {
    for (final t in input.hostTools) {
      b.writeln('- `${t.name}`: ${t.when}');
    }
  }
  if (input.workflows.isNotEmpty) {
    b
      ..writeln()
      ..writeln('Workflows `run_workflow` can propose (the user starts one from an estimate in the app):')
      ..writeln();
    for (final w in input.workflows) {
      b.writeln('- `${w.id}`: ${w.when}');
    }
  }
  b
    ..writeln()
    ..writeln('## Commits')
    ..writeln()
    // Prompt reason: owner, commits and PRs carry no AI identifiers; Gemini, OpenCode, ACP and terminal agents have
    // no session switch for their trailers, and the others get one as well (see recipes.dart).
    ..writeln(
      'Commits and pull requests read as if the user wrote them: no `Co-authored-by` or `Signed-off-by` trailer',
    )
    ..writeln('naming an AI, no "Generated with" line, and no links to a tool or a session.')
    ..writeln()
    ..writeln('## This session')
    ..writeln()
    ..writeln('- Working directory: `${input.worktree}`');
  if (input.noticeNonce case final n? when n.isNotEmpty) {
    b.writeln('- Fork reports and workflow results come as `<everyai-notice>` tags with nonce `$n`.');
  }
  return defuseInlineCommands(b.toString());
}
