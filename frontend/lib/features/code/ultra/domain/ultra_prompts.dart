import 'dart:convert';

import 'ultra_journal.dart';
import 'ultra_plan.dart';

/// The `ultra_plan` client tool, given only to an Ultra orchestrator.
const ultraPlanSpec = <String, Object?>{
  'name': ultraPlanTool,
  'description':
      'Run a multi-agent workflow. You describe it as phases of steps; the app then starts one fresh agent per step '
      '(for every for_each item), runs phases in order, and sends you every result in the next user message. '
      'Steps in a "parallel" phase run at once; in a "pipeline" phase they run in order and each gets the previous '
      "step's result (with for_each, every item goes through the steps on its own). A step's agent sees nothing "
      'but its prompt and the results named in inputs, so the prompt must stand alone. Set writes:true only for '
      'steps that change files: each gets its own git worktree, merged back when it is done. Give result_schema '
      '(JSON Schema) when you need structured output, and verify {prompt} to have a separate read-only agent check '
      'the result (a failed check reruns the step once). After the last phase a critic compares every result with '
      'the goal and the app runs what it finds missing. Models: opus for hard steps, sonnet for ordinary ones, '
      'haiku for mechanical ones. Call this once, then end your turn and wait for the results.',
  'parameters': {
    'type': 'object',
    'properties': {
      'goal': {'type': 'string', 'description': 'What the whole run must achieve, and how to tell it is done'},
      'phases': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'id': {'type': 'string', 'description': 'Lowercase id, unique in the plan'},
            'title': {'type': 'string'},
            'mode': {
              'type': 'string',
              'enum': ['parallel', 'pipeline'],
            },
            'for_each': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': 'Optional: run the steps once per item; {{item}} in a prompt becomes the item',
            },
            'steps': {
              'type': 'array',
              'items': {
                'type': 'object',
                'properties': {
                  'id': {'type': 'string', 'description': 'Lowercase id, unique in the phase'},
                  'title': {'type': 'string', 'description': '3-6 words'},
                  'prompt': {'type': 'string', 'description': 'Complete, self-contained instructions'},
                  'agent': {'type': 'string', 'description': 'Optional: an agent from AGENT_TYPES'},
                  'model': {'type': 'string', 'description': 'opus, sonnet, haiku or a model id'},
                  'effort': {
                    'type': 'string',
                    'enum': ['low', 'medium', 'high', 'xhigh', 'max'],
                  },
                  'writes': {'type': 'boolean', 'description': 'True when the step changes files'},
                  'inputs': {
                    'type': 'array',
                    'items': {'type': 'string'},
                    'description': 'Earlier results it reads: "phase" or "phase.step"',
                  },
                  'result_schema': {'type': 'object', 'description': 'Optional JSON Schema for its result'},
                  'verify': {
                    'type': 'object',
                    'properties': {
                      'prompt': {'type': 'string', 'description': 'What the checker must confirm'},
                      'model': {'type': 'string'},
                    },
                    'required': ['prompt'],
                  },
                },
                'required': ['id', 'title', 'prompt'],
              },
            },
          },
          'required': ['id', 'steps'],
        },
      },
      'critic': {
        'type': 'object',
        'properties': {
          'prompt': {'type': 'string', 'description': 'Optional: what "complete" means beyond the goal'},
        },
      },
    },
    'required': ['goal', 'phases'],
  },
  'annotations': {'readOnlyHint': true, 'destructiveHint': false},
};

/// Appended to the orchestrator's system prompt (after the subagent rules,
/// which it overrides where they differ).
String ultraOrchestratorRules(UltraLimits limits) =>
    '''
<ULTRA_ORCHESTRATOR>
You are the orchestrator of an Ultra run. Unlike other subagents you do not do the work yourself: you plan it,
the app runs your plan with many agents, and you write the final answer from their results.
- First read just enough of the project to plan well (layout, key files, how it is built and tested). Do not change
  files.
- Then call $ultraPlanTool once with the whole workflow. Split the work so steps are independent where possible
  and run them in parallel; use a pipeline only when a step truly needs the one before. Give each step one clear
  job and a prompt that names files, constraints and what its report must contain. Put verify on steps whose
  mistakes would be costly, and prefer result_schema when you will compare or merge results.
- Limits for this run: at most ${limits.maxConcurrent} agents at once, ${limits.maxAgents} in all (verifiers, the
  critic and reruns count), \$${(limits.budgetMicros / 1e6).toStringAsFixed(0)} and ${limits.wallTime.inMinutes}
  minutes. Plan for less; the run stops starting agents at a cap.
- If the tool answers with problems in the plan, fix them and call it again.
- When the results arrive, check them against the goal and write your final message: what was done, what was
  verified, which branches were left unmerged and why, and anything still open. That message is the run's answer.
</ULTRA_ORCHESTRATOR>''';

/// The orchestrator's first message.
String ultraOrchestratorBrief(String goal) => 'Ultra run. The user asked for:\n\n$goal';

/// The tool result for a plan the app could not take.
String ultraPlanRejected(List<String> errors) =>
    'The plan was not run. Fix these and call $ultraPlanTool again:\n${errors.map((e) => '- $e').join('\n')}';

const _maxInput = 8000;
const _maxReportStep = 6000;
const _maxReport = 90000;

String _cut(String s, int max) => s.length <= max ? s : '${s.substring(0, max)}\n[… cut at $max characters]';

/// The first message of a step's child conversation.
String stepBrief({
  required UltraPlan plan,
  required UltraPhase phase,
  required UltraStep step,
  required String? item,
  required Map<String, String> inputs,
  required bool isolated,
  String retryNotes = '',
}) {
  final prompt = item == null
      ? step.prompt
      : step.prompt.contains('{{item}}')
      ? step.prompt.replaceAll('{{item}}', item)
      : '${step.prompt}\n\nItem: $item';
  final out = StringBuffer()
    ..writeln('You are one step of a larger multi-agent run.')
    ..writeln('Run goal: ${plan.goal}')
    ..writeln('Phase: ${phase.title}')
    ..writeln('Your step: ${step.title}')
    ..writeln()
    ..writeln(prompt);
  if (inputs.isNotEmpty) {
    out.writeln('\nResults from earlier steps:');
    for (final e in inputs.entries) {
      out.writeln('<ultra_input from="${e.key}">\n${_cut(e.value, _maxInput)}\n</ultra_input>');
    }
  }
  out.writeln();
  out.writeln(
    step.writes
        ? isolated
              ? 'You work in a git worktree of your own; leave your changes in it (no need to commit or push). '
                    'They are merged back after you finish.'
              : 'You may change files in this folder; other steps do not run while you do.'
        : 'Do not change any files: this step only investigates and reports.',
  );
  if (step.resultSchema case final schema?) {
    out.writeln(
      'End your final message with one ```json block whose value matches this JSON Schema:\n'
      '```json\n${const JsonEncoder.withIndent('  ').convert(schema)}\n```',
    );
  }
  if (retryNotes.isNotEmpty) {
    out.writeln('\nAn earlier attempt at this step was checked and failed. Fix these problems:\n$retryNotes');
  }
  return out.toString().trimRight();
}

/// What a step's verifier returns.
const verifySchema = <String, Object?>{
  'type': 'object',
  'properties': {
    'pass': {'type': 'boolean'},
    'issues': {
      'type': 'array',
      'items': {'type': 'string'},
    },
  },
  'required': ['pass', 'issues'],
};

/// The first message of a verifier, which reads (and may run) but changes nothing.
String verifyBrief({required UltraPlan plan, required UltraStep step, required StepRecord record}) =>
    '''
You check one step of a multi-agent run. Do not change any files.
Run goal: ${plan.goal}
Step: ${step.title}${record.item == null ? '' : ' (item: ${record.item})'}

The step was asked to:
${_cut(step.prompt, _maxInput)}

It reported:
<step_result>
${_cut(record.result, _maxInput)}
</step_result>

Check this: ${step.verify!.prompt}
Look at the files and run checks yourself rather than trusting the report. End your final message with one ```json
block: {"pass": true or false, "issues": ["what is wrong, with file and line"]}.''';

/// What the critic returns.
const criticSchema = <String, Object?>{
  'type': 'object',
  'properties': {
    'complete': {'type': 'boolean'},
    'notes': {'type': 'string'},
    'gaps': {
      'type': 'array',
      'items': {
        'type': 'object',
        'properties': {
          'title': {'type': 'string'},
          'prompt': {'type': 'string'},
          'writes': {'type': 'boolean'},
        },
        'required': ['title', 'prompt'],
      },
    },
  },
  'required': ['complete', 'gaps'],
};

/// The critic's first message.
String criticBrief(UltraJournal j, {required bool allowWrites, required int maxGaps}) {
  final out = StringBuffer()
    ..writeln('You are the completeness critic of a multi-agent run. Do not change any files.')
    ..writeln('Run goal: ${j.plan.goal}');
  if (j.plan.critic.prompt.isNotEmpty) out.writeln('Also required: ${j.plan.critic.prompt}');
  out
    ..writeln('\nThese are the step results:')
    ..writeln(_results(j, perStep: 3000, total: 60000))
    ..writeln(
      '\nCompare them with the goal, and check the project where a result makes a claim you can verify. List only '
      'real gaps: work the goal needs that no step did, or did wrong. Each gap becomes a new step for a fresh agent, '
      'so its prompt must stand alone. At most $maxGaps gaps.${allowWrites ? '' : ' No gap may change files.'}',
    )
    ..writeln(
      'End your final message with one ```json block: {"complete": true or false, "notes": "short verdict", '
      '"gaps": [{"title": "...", "prompt": "...", "writes": false}]}.',
    );
  return out.toString().trimRight();
}

String _results(UltraJournal j, {required int perStep, required int total}) {
  final out = StringBuffer();
  for (final s in j.steps.values) {
    if (s.key == criticKey) continue;
    final head = [
      '<result step="${s.key}" status="${s.status.name}"',
      if (s.verified != null) ' verified="${s.verified}"',
      if (s.merge != null) ' merged="${s.merge!.merged}" branch="${s.merge!.branch}"',
      '>',
    ].join();
    final body = [
      if (s.title.isNotEmpty) 'Title: ${s.title}${s.item == null ? '' : ' (item: ${s.item})'}',
      if (s.note.isNotEmpty) 'Note: ${s.note}',
      if (s.verifyNotes.isNotEmpty) 'Check: ${_cut(s.verifyNotes, 1500)}',
      if (s.merge?.detail.isNotEmpty ?? false) 'Merge: ${s.merge!.detail}',
      if (s.schemaErrors.isNotEmpty) 'Result did not match its schema: ${s.schemaErrors.take(5).join('; ')}',
      _cut(s.result, perStep),
    ].join('\n');
    out.writeln('$head\n$body\n</result>');
    if (out.length > total) {
      out.writeln('[… more results cut]');
      break;
    }
  }
  return out.toString().trimRight();
}

/// The journal key of the critic's record.
const criticKey = '_critic';

/// The user message that hands a finished (or capped) run back to the
/// orchestrator, for its final answer.
String ultraReport(UltraJournal j) {
  final counts = <StepStatus, int>{};
  for (final s in j.steps.values) {
    if (s.key != criticKey) counts[s.status] = (counts[s.status] ?? 0) + 1;
  }
  final unmerged = [
    for (final s in j.steps.values)
      if (s.merge case final m? when !m.merged) '${m.branch} (${s.key}${m.detail.isEmpty ? '' : ': ${m.detail}'})',
  ];
  final out = StringBuffer()
    ..writeln('The Ultra run ${j.status == UltraRunStatus.done ? 'finished' : 'ended early (${j.status.name})'}.')
    ..writeln(
      'Agents: ${j.agentsStarted}. Cost: \$${(j.spentMicros / 1e6).toStringAsFixed(2)} of '
      '\$${(j.budgetMicros / 1e6).toStringAsFixed(2)}. Time: ${j.elapsed.inMinutes} min. Steps: '
      '${counts.entries.map((e) => '${e.value} ${e.key.name}').join(', ')}.',
    );
  if (j.note.isNotEmpty) out.writeln('Why it ended: ${j.note}');
  if (j.complete != null) {
    out.writeln(
      'Critic: ${j.complete! ? 'complete' : 'gaps found'}${j.criticNotes.isEmpty ? '' : '. ${j.criticNotes}'}',
    );
  }
  if (unmerged.isNotEmpty) out.writeln('Branches left for the user: ${unmerged.join('; ')}');
  out
    ..writeln()
    ..writeln(_results(j, perStep: _maxReportStep, total: _maxReport))
    ..writeln()
    ..writeln('Write your final message now (the user has not seen these results).');
  return out.toString().trimRight();
}
