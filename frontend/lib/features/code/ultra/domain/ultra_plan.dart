import 'dart:convert';

/// Ultra mode: an orchestrator agent writes a workflow plan (this file's
/// [UltraPlan]) through the `ultra_plan` client tool, and the app runs it
/// step by step as child conversations (see `ultra_engine.dart`).
const ultraPlanTool = 'ultra_plan';

/// The plans Ultra is on (the user's call: Max only).
const ultraPlans = {'max'};

/// Whether the billing plan [planId] may start an Ultra run.
bool ultraAllowedOn(String planId) => ultraPlans.contains(planId);

/// The caps one Ultra run stays under. The defaults are the user's.
final class UltraLimits {
  const UltraLimits({
    this.maxConcurrent = 16,
    this.maxAgents = 150,
    this.budgetMicros = 25000000,
    this.wallTime = const Duration(hours: 2),
    this.verifyRetries = 1,
    this.maxPhases = 12,
    this.maxStepsPerPhase = 32,
    this.maxItems = 64,
  });

  /// Child conversations running at once.
  final int maxConcurrent;

  /// Child conversations per run, counting verifiers, the critic and retries.
  final int maxAgents;

  /// Dollars per run, in millionths.
  final int budgetMicros;
  final Duration wallTime;

  /// How often a step is redone after its verifier fails it.
  final int verifyRetries;

  final int maxPhases;
  final int maxStepsPerPhase;

  /// Entries in one phase's `for_each`.
  final int maxItems;

  Map<String, Object?> toJson() => {
    'max_concurrent': maxConcurrent,
    'max_agents': maxAgents,
    'budget_micros': budgetMicros,
    'wall_time_s': wallTime.inSeconds,
    'verify_retries': verifyRetries,
  };

  factory UltraLimits.fromJson(Map<String, Object?> j) {
    const d = UltraLimits();
    int n(String k, int or) => (j[k] as num?)?.toInt() ?? or;
    return UltraLimits(
      maxConcurrent: n('max_concurrent', d.maxConcurrent),
      maxAgents: n('max_agents', d.maxAgents),
      budgetMicros: n('budget_micros', d.budgetMicros),
      wallTime: Duration(seconds: n('wall_time_s', d.wallTime.inSeconds)),
      verifyRetries: n('verify_retries', d.verifyRetries),
    );
  }
}

/// The models a plan can name by tier, and what a step gets when it names none.
const ultraModelAliases = {
  'opus': 'anthropic/claude-opus-5.5',
  'sonnet': 'anthropic/claude-sonnet-5.5',
  'haiku': 'anthropic/claude-haiku-5.5',
};

/// Opus orchestrates and does the hard steps; the plan picks cheaper models
/// for easy ones. Verifiers default to Sonnet.
const ultraOrchestratorModel = 'anthropic/claude-opus-5.5';
const ultraStepModel = 'anthropic/claude-opus-5.5';
const ultraVerifyModel = 'anthropic/claude-sonnet-5.5';
const ultraCriticModel = 'anthropic/claude-opus-5.5';

const _efforts = {'low', 'medium', 'high', 'xhigh', 'max'};
final _idPattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,39}$');
final _modelPattern = RegExp(r'^[a-z0-9._~-]+/[A-Za-z0-9._:~-]+$');

/// How a phase's steps run.
enum FanOut {
  /// Every step (for every item) at once, up to the concurrency cap.
  parallel,

  /// The steps in order, each handed the one before's result; with
  /// `for_each`, every item goes through the steps on its own, items at once.
  pipeline,
}

/// A check run on a step's result by a separate, read-only agent.
final class UltraVerify {
  const UltraVerify({required this.prompt, this.agent, this.model, this.effort});

  final String prompt;
  final String? agent;
  final String? model;
  final String? effort;

  Map<String, Object?> toJson() => {'prompt': prompt, 'agent': ?agent, 'model': ?model, 'effort': ?effort};
}

final class UltraStep {
  const UltraStep({
    required this.id,
    required this.title,
    required this.prompt,
    this.agent,
    this.model,
    this.effort,
    this.writes = false,
    this.inputs = const [],
    this.resultSchema,
    this.verify,
  });

  final String id;
  final String title;

  /// The child's instructions; `{{item}}` becomes the phase's item.
  final String prompt;

  /// A library agent (`.everyai/agents/<name>.md`).
  final String? agent;

  /// A gateway model id (aliases resolved), or null for the default.
  final String? model;
  final String? effort;

  /// Changes files: it runs in a worktree of its own, merged back after.
  final bool writes;

  /// Earlier results it reads: `phase` (every step in it) or `phase.step`.
  final List<String> inputs;

  /// A JSON Schema the child's final ```json block must match.
  final Map<String, Object?>? resultSchema;
  final UltraVerify? verify;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'prompt': prompt,
    'agent': ?agent,
    'model': ?model,
    'effort': ?effort,
    if (writes) 'writes': true,
    if (inputs.isNotEmpty) 'inputs': inputs,
    'result_schema': ?resultSchema,
    'verify': ?verify?.toJson(),
  };
}

final class UltraPhase {
  const UltraPhase({
    required this.id,
    required this.title,
    required this.steps,
    this.fanOut = FanOut.parallel,
    this.forEach = const [],
  });

  final String id;
  final String title;
  final FanOut fanOut;
  final List<UltraStep> steps;

  /// One run of the phase's steps per entry; empty runs them once.
  final List<String> forEach;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'mode': fanOut.name,
    if (forEach.isNotEmpty) 'for_each': forEach,
    'steps': [for (final s in steps) s.toJson()],
  };
}

/// The completeness check after the last phase: it reads every result and
/// names what is missing, which then runs as one extra phase.
final class UltraCritic {
  const UltraCritic({this.prompt = '', this.model, this.effort});

  final String prompt;
  final String? model;
  final String? effort;

  Map<String, Object?> toJson() => {'prompt': prompt, 'model': ?model, 'effort': ?effort};
}

final class UltraPlan {
  const UltraPlan({required this.goal, required this.phases, this.critic = const UltraCritic()});

  final String goal;
  final List<UltraPhase> phases;
  final UltraCritic critic;

  Map<String, Object?> toJson() => {
    'goal': goal,
    'phases': [for (final p in phases) p.toJson()],
    'critic': critic.toJson(),
  };

  /// How many children the plan starts at least (no verify retries, no gaps).
  int get minimumAgents => phases.fold(
    0,
    (n, p) =>
        n + (p.forEach.isEmpty ? 1 : p.forEach.length) * p.steps.fold(0, (m, s) => m + 1 + (s.verify == null ? 0 : 1)),
  );

  bool get writes => phases.any((p) => p.steps.any((s) => s.writes));
}

/// A parsed plan, or what is wrong with it (said to the orchestrator so it
/// can fix and call again).
final class PlanParse {
  const PlanParse(this.plan, this.errors);
  final UltraPlan? plan;
  final List<String> errors;
}

/// Reads an `ultra_plan` call's arguments: `{plan: {...}}`, the plan itself,
/// or either as a JSON string. With [allowWrites] false, writing steps are an
/// error (the session is in Plan mode).
PlanParse parseUltraPlan(Object? args, {UltraLimits limits = const UltraLimits(), bool allowWrites = true}) {
  final errors = <String>[];
  var root = _decode(args);
  if (root case {'plan': final Object? inner} when root['phases'] == null) root = _decode(inner);
  if (root is! Map<String, Object?>) return const PlanParse(null, ['The plan must be a JSON object.']);

  final goal = _str(root['goal']);
  if (goal.isEmpty) errors.add('goal: say what the whole run must achieve.');
  final rawPhases = root['phases'];
  if (rawPhases is! List || rawPhases.isEmpty) {
    errors.add('phases: give at least one phase.');
    return PlanParse(null, errors);
  }
  if (rawPhases.length > limits.maxPhases) errors.add('phases: at most ${limits.maxPhases}.');

  final phases = <UltraPhase>[];
  // What an input may point at: phases and steps defined earlier.
  final known = <String>{};
  for (final (i, raw) in rawPhases.indexed) {
    final where = 'phases[$i]';
    if (raw is! Map<String, Object?>) {
      errors.add('$where: must be an object.');
      continue;
    }
    final id = _str(raw['id']);
    if (!_idPattern.hasMatch(id)) errors.add('$where.id: lowercase letters, digits, - and _ (got "$id").');
    if (known.contains(id)) errors.add('$where.id: "$id" is used twice.');
    final mode = switch (_str(raw['mode'])) {
      '' || 'parallel' => FanOut.parallel,
      'pipeline' => FanOut.pipeline,
      final m => () {
        errors.add('$where.mode: "parallel" or "pipeline" (got "$m").');
        return FanOut.parallel;
      }(),
    };
    final forEach = [
      for (final e in (raw['for_each'] as List?) ?? const [])
        if (_str(e is String ? e : jsonEncode(e)) case final s when s.isNotEmpty) s,
    ];
    if (forEach.length > limits.maxItems) errors.add('$where.for_each: at most ${limits.maxItems} items.');
    final rawSteps = raw['steps'];
    if (rawSteps is! List || rawSteps.isEmpty) {
      errors.add('$where.steps: give at least one step.');
      continue;
    }
    if (rawSteps.length > limits.maxStepsPerPhase) errors.add('$where.steps: at most ${limits.maxStepsPerPhase}.');
    final steps = <UltraStep>[];
    final stepIds = <String>{};
    for (final (j, s) in rawSteps.indexed) {
      final at = '$where.steps[$j]';
      if (s is! Map<String, Object?>) {
        errors.add('$at: must be an object.');
        continue;
      }
      final sid = _str(s['id']);
      if (!_idPattern.hasMatch(sid)) errors.add('$at.id: lowercase letters, digits, - and _ (got "$sid").');
      if (!stepIds.add(sid)) errors.add('$at.id: "$sid" is used twice in this phase.');
      final prompt = _str(s['prompt']);
      if (prompt.isEmpty) errors.add('$at.prompt: the step needs complete, self-contained instructions.');
      final writes = s['writes'] == true;
      if (writes && !allowWrites) errors.add('$at.writes: the session is in Plan mode, so no step may change files.');
      final inputs = [for (final e in (s['inputs'] as List?) ?? const []) _str(e)];
      for (final input in inputs) {
        // Same-phase inputs only make sense in a pipeline, and only backwards.
        final ok =
            known.contains(input) ||
            (mode == FanOut.pipeline && input.startsWith('$id.') && stepIds.contains(input.substring(id.length + 1)));
        if (!ok) errors.add('$at.inputs: "$input" is not an earlier phase or phase.step.');
      }
      final schema = s['result_schema'] ?? s['result'];
      if (schema != null && schema is! Map<String, Object?>) errors.add('$at.result_schema: must be a JSON Schema.');
      final verify = switch (s['verify']) {
        null => null,
        final String p when p.trim().isNotEmpty => UltraVerify(prompt: p.trim()),
        final Map<String, Object?> v when _str(v['prompt']).isNotEmpty => UltraVerify(
          prompt: _str(v['prompt']),
          agent: _opt(v['agent']),
          model: _model(v['model'], '$at.verify.model', errors),
          effort: _effort(v['effort'], '$at.verify.effort', errors),
        ),
        _ => () {
          errors.add('$at.verify: give {prompt} saying what to check.');
          return null;
        }(),
      };
      steps.add(
        UltraStep(
          id: sid,
          title: _str(s['title']).isEmpty ? sid : _str(s['title']),
          prompt: prompt,
          agent: _opt(s['agent']),
          model: _model(s['model'], '$at.model', errors),
          effort: _effort(s['effort'], '$at.effort', errors),
          writes: writes,
          inputs: inputs,
          resultSchema: schema is Map<String, Object?> ? schema : null,
          verify: verify,
        ),
      );
    }
    known.add(id);
    for (final s in steps) {
      known.add('$id.${s.id}');
    }
    phases.add(
      UltraPhase(
        id: id,
        title: _str(raw['title']).isEmpty ? id : _str(raw['title']),
        fanOut: mode,
        steps: steps,
        forEach: forEach,
      ),
    );
  }

  final critic = switch (root['critic']) {
    final Map<String, Object?> c => UltraCritic(
      prompt: _str(c['prompt']),
      model: _model(c['model'], 'critic.model', errors),
      effort: _effort(c['effort'], 'critic.effort', errors),
    ),
    final String p => UltraCritic(prompt: p.trim()),
    _ => const UltraCritic(),
  };
  final plan = UltraPlan(goal: goal, phases: phases, critic: critic);
  // The critic is one more agent.
  if (plan.minimumAgents + 1 > limits.maxAgents) {
    errors.add(
      'The plan needs at least ${plan.minimumAgents + 1} agents; a run may start ${limits.maxAgents}. '
      'Merge steps or shorten for_each.',
    );
  }
  return PlanParse(errors.isEmpty ? plan : null, errors);
}

Object? _decode(Object? v) {
  if (v is String) {
    try {
      return jsonDecode(v);
    } on FormatException {
      return null;
    }
  }
  return v;
}

String _str(Object? v) => v is String ? v.trim() : '';
String? _opt(Object? v) => _str(v).isEmpty ? null : _str(v);

String? _model(Object? v, String at, List<String> errors) {
  final m = _str(v);
  if (m.isEmpty || m == 'inherit') return null;
  if (ultraModelAliases[m.toLowerCase()] case final id?) return id;
  if (!_modelPattern.hasMatch(m)) {
    errors.add('$at: opus, sonnet, haiku or a model id such as anthropic/claude-sonnet-5.5 (got "$m").');
    return null;
  }
  return m;
}

String? _effort(Object? v, String at, List<String> errors) {
  final e = _str(v);
  if (e.isEmpty) return null;
  if (!_efforts.contains(e)) errors.add('$at: one of ${_efforts.join(', ')} (got "$e").');
  return e;
}

/// Checks [value] against the parts of JSON Schema plans use: `type`,
/// `properties`, `required`, `items` and `enum`. Returns the problems found.
List<String> checkSchema(Object? value, Map<String, Object?> schema, [String at = r'$']) {
  final out = <String>[];
  final type = schema['type'];
  final types = type is List ? type.whereType<String>().toSet() : {if (type is String) type};
  if (types.isNotEmpty && !types.any((t) => _isType(value, t))) {
    out.add('$at: expected ${types.join(' or ')}, got ${_typeOf(value)}.');
    return out;
  }
  if (schema['enum'] case final List<Object?> allowed when !allowed.contains(value)) {
    out.add('$at: must be one of ${jsonEncode(allowed)}.');
  }
  if (value is Map<String, Object?>) {
    for (final key in (schema['required'] as List?)?.whereType<String>() ?? const <String>[]) {
      if (!value.containsKey(key)) out.add('$at.$key: missing.');
    }
    if (schema['properties'] case final Map<String, Object?> props) {
      for (final e in props.entries) {
        if (value.containsKey(e.key) && e.value is Map<String, Object?>) {
          out.addAll(checkSchema(value[e.key], e.value! as Map<String, Object?>, '$at.${e.key}'));
        }
      }
    }
  }
  if (value is List && schema['items'] is Map<String, Object?>) {
    for (final (i, v) in value.indexed) {
      out.addAll(checkSchema(v, schema['items']! as Map<String, Object?>, '$at[$i]'));
      if (out.length > 20) break;
    }
  }
  return out;
}

bool _isType(Object? v, String t) => switch (t) {
  'object' => v is Map,
  'array' => v is List,
  'string' => v is String,
  'integer' => v is int || (v is double && v == v.roundToDouble()),
  'number' => v is num,
  'boolean' => v is bool,
  'null' => v == null,
  _ => true,
};

String _typeOf(Object? v) => switch (v) {
  null => 'null',
  Map() => 'object',
  List() => 'array',
  String() => 'string',
  bool() => 'boolean',
  num() => 'number',
  _ => 'unknown',
};

final _fence = RegExp(r'```json[ \t]*\n([\s\S]*?)\n```');

/// The structured result in a child's final message: its last ```json block,
/// or the whole message when that is JSON. [found] is false when there is none.
({bool found, Object? value}) structuredResult(String text) {
  final blocks = _fence.allMatches(text).toList();
  final candidates = [if (blocks.isNotEmpty) blocks.last[1]!, text.trim()];
  for (final c in candidates) {
    try {
      return (found: true, value: jsonDecode(c));
    } on FormatException {
      continue;
    }
  }
  return (found: false, value: null);
}
