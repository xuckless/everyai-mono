// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

// The notes a user message carries when the user picks a workflow: Max on
// or off, or a script workflow started on the message's task. The lead reads
// them; the transcript strips them and shows a short chip instead.

/// Max's id in `CodeSessionInfo.workflow`.
const maxWorkflowId = 'max';

/// The bundled skill Max turns on (the max lane ships it).
const maxSkillId = 'everyai-max';

const _open = '<everyai-workflow ';
const _close = '</everyai-workflow>';

String _attr(String s) => s.replaceAll('"', "'");

/// The note the next message carries when Max is turned on or off.
/// Prompt reason: Max is an approach skill the model loads itself now, not
/// phases the harness enforces. If the skill can't be loaded the lead says so,
/// so a Max that does nothing isn't silent (issue #10). Max covers one task and
/// the lead ends it with end_workflow (the owner: every workflow returns the
/// session to no workflow when it is done).
String maxWorkflowNote({required bool on}) => on
    ? '${_open}name="$maxWorkflowId" state="on">The user turned on the Max workflow. Load the $maxSkillId skill now '
          'and follow its approach for this task. When the task is done, verified and reported, call end_workflow '
          'to turn Max off. If you can\'t load the skill, tell the user in one line that Max isn\'t available in '
          'this session, then do the task your own way.$_close'
    : '${_open}name="$maxWorkflowId" state="off">The user turned the Max workflow off: stop following the '
          '$maxSkillId approach from here on.$_close';

/// The message the lead gets when the user picks workflow [id] ([title]) for [task]: the lead clarifies when it must,
/// then calls run_workflow, and the user starts the run from its estimate (owner, 2026-11-08: every workflow starts
/// that way, the lead clarifies for all of them). [args] says what the workflow takes; [draft] is a first guess at them
/// from the task.
/// Prompt reason: picked runs used to start at once on the raw task; now they get the same clarify-then-estimate path
/// as runs the lead starts, so the lead needs the args shape and a starting point.
String workflowStartNoteOf(String id, String title, String task, {String args = '', String draft = ''}) =>
    '${_open}name="${_attr(id)}" state="picked" title="${_attr(title)}">The user picked the $title workflow for the '
    'task below. If the task leaves out something $title needs to do it well, ask the user with ask_user_question '
    'first (only then, and only what is missing). Then call run_workflow with id "$id" and its args'
    '${args.isEmpty ? '' : ' ($args)'}${draft.isEmpty ? '' : '; from the task alone they would be $draft'}. The user '
    'then sees an estimate and starts it; its result reaches you later in a <workflow-result> message. Don\'t work '
    'on the task yourself.$_close\n\n$task';

/// The message the lead gets when the workflow [title] the user started
/// couldn't start after all ([why]).
String workflowFailedNote(String id, String title, String why) =>
    '${_open}name="${_attr(id)}" state="failed" title="${_attr(title)}">The $title workflow didn\'t start: $why '
    'Work on the task from the user\'s message yourself instead.$_close';

/// Splits the workflow notes off the start of [text]: a short label for
/// each ("Max on", "Started Bug fix"), and the rest.
(List<String>, String) splitWorkflowNotes(String text) {
  final labels = <String>[];
  var rest = text;
  while (rest.startsWith(_open)) {
    final head = rest.indexOf('>');
    final end = rest.indexOf(_close);
    if (head < 0 || end < 0) break;
    final attrs = rest.substring(0, head);
    String attr(String name) => RegExp('$name="([^"]*)"').firstMatch(attrs)?[1] ?? '';
    final title = attr('title').isEmpty ? attr('name') : attr('title');
    labels.add(switch (attr('state')) {
      'on' => 'Max on',
      'off' => 'Max off',
      'failed' => '$title didn\'t start',
      'picked' => title,
      'adjust' => 'Changing $title',
      _ => 'Started $title',
    });
    rest = rest.substring(end + _close.length).trimLeft();
  }
  return (labels, rest);
}
