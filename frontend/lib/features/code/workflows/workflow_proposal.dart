// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/foundation.dart';

import 'workflow_estimate.dart';

/// A workflow run the lead asked for (run_workflow), waiting for the user to start it: the card above the composer
/// shows its phases and [estimate] with Start, Adjust and Cancel (owner, 2026-11-08: every run starts that way).
/// Kept on disk while open, so the card survives a restart.
@immutable
final class WorkflowProposal {
  const WorkflowProposal({
    required this.id,
    required this.workflowId,
    required this.title,
    required this.args,
    required this.ctx,
    required this.estimate,
    this.phases = const [],
    this.capUsd,
    this.items = const [],
  });

  final String id;
  final String workflowId;
  final String title;
  final Map<String, Object?> args;
  final Map<String, Object?> ctx;
  final WorkflowEstimate estimate;
  final List<String> phases;

  /// The hard money cap of an EveryAI-led run; null on an outside lead.
  final double? capUsd;

  /// The items' titles when the args list them (Ultra), for the card.
  final List<String> items;

  Map<String, Object?> toJson() => {
    'id': id,
    'workflow': workflowId,
    'title': title,
    'args': args,
    'ctx': ctx,
    'estimate': estimate.toJson(),
    'phases': phases,
    'cap_usd': ?capUsd,
    if (items.isNotEmpty) 'items': items,
  };

  static WorkflowProposal? fromJson(Object? j) => switch (j) {
    {
      'id': final String id,
      'workflow': final String w,
      'title': final String title,
      'args': final Map<String, Object?> args,
      'estimate': final Map<String, Object?> e,
    } =>
      WorkflowProposal(
        id: id,
        workflowId: w,
        title: title,
        args: args,
        ctx: ((j as Map)['ctx'] as Map?)?.cast<String, Object?>() ?? const {},
        estimate: WorkflowEstimate.fromJson(e),
        phases: [
          if (j['phases'] case final List<Object?> p)
            for (final t in p) '$t',
        ],
        capUsd: (j['cap_usd'] as num?)?.toDouble(),
        items: [
          if (j['items'] case final List<Object?> p)
            for (final t in p) '$t',
        ],
      ),
    _ => null,
  };
}

/// The titles of the items [args] lists (Ultra's `items: [{id, title, …}]`).
List<String> proposalItems(Map<String, Object?> args, String key) => [
  if (args[key] case final List<Object?> items)
    for (final it in items)
      if (it case {'title': final String t} when t.trim().isNotEmpty)
        t.trim()
      else if (it case {'id': final String id})
        id,
];

/// run_workflow's result while the user decides.
String proposedResult(String title) =>
    'The user now sees an estimate for $title and decides: Start, Adjust or Cancel. Tell them in one line that it '
    'waits for their OK, then end your turn. If they start it, its result arrives later as a <workflow-result> '
    'message; if they want changes, their next message says what (then call run_workflow again with the changed '
    'args); if they cancel, you are told. Do not poll for it.';

/// The lead's note when the user cancelled the estimate.
String proposalCancelledNote(String title) =>
    '<workflow-result>\nThe user cancelled the $title run before it started: nothing ran. Ask what they want '
    'instead in one line, unless they already said.\n</workflow-result>';

/// The lead's note when a run paused for the user's decision (past its estimate, or off track; [why] is the card's
/// row).
String workflowDecisionNote(String name, String why) =>
    '<workflow-checkpoint name="${name.replaceAll('"', "'")}">The $name run is paused: $why The user decides on its '
    'card (go on, Stop or Adjust). Tell them in one line; don\'t work on its task yourself meanwhile.'
    '</workflow-checkpoint>';

/// The note on the user's next message after Adjust on a run paused for their decision.
String workflowAdjustNote(String name) =>
    '<everyai-workflow state="adjust" title="${name.replaceAll('"', "'")}">The $name run is paused for their decision, '
    'and the user wants something changed (their message below). A running run keeps its args: answer them, and if '
    'the change needs other args, tell them to stop it so you can propose a new run. It goes on when they press '
    'the button on its card to go on.</everyai-workflow>';

/// The note on the user's next message after Adjust.
String proposalAdjustNote(String title) =>
    '<everyai-workflow state="adjust" title="${title.replaceAll('"', "'")}">The user wants changes to the proposed '
    '$title run before it starts; nothing ran. Their message below says what. Call run_workflow again with the '
    'changed args: they see a new estimate.</everyai-workflow>';
