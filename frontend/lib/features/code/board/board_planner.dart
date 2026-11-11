import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/preferences.dart';
import '../agent_models.dart' show codeAgentProvider;
import '../code_providers.dart';
import '../code_settings_providers.dart' show codeSettingsProvider;
import '../gateway_key.dart' show remintGatewayKey;
import '../domain/agent_mode.dart';
import '../domain/code_session.dart';
import '../drivers/claude/claude_wire.dart' show claudeModelArg;
import '../drivers/driver.dart' show DriverModel;
import '../drivers/driver_policy.dart' show leadBlocked;
import '../drivers/driver_registry.dart';
import '../harness/harness.dart' show HarnessError;
import '../harness/summarizer.dart' show gatewaySummarizer;
import '../ui/code_home.dart' show lastModeKey;
import 'board_plan.dart';
import 'board_planner_stub.dart' if (dart.library.io) 'board_planner_io.dart' as cli;

/// The outside CLIs that can plan headless, read-only and without keeping a session.
enum PlannerCli {
  claude('claude-code', 'claude', 'Claude Code'),
  codex('codex', 'codex', 'Codex'),
  opencode('opencode', 'opencode', 'OpenCode'),
  gemini('gemini', 'gemini', 'Gemini CLI');

  const PlannerCli(this.harness, this.command, this.label);

  /// The driver id.
  final String harness;

  /// The program on PATH.
  final String command;
  final String label;

  static PlannerCli? of(String harness) => values.where((c) => c.harness == harness).firstOrNull;
}

/// The CLI's arguments for one headless, read-only planning run ([lastMessage]: where Codex writes its reply).
List<String> plannerArgs(PlannerCli cli, {required String model, required String prompt, String? lastMessage}) =>
    switch (cli) {
      // Plan mode reads but never edits; nothing is saved as a session.
      PlannerCli.claude => [
        '-p',
        prompt,
        '--output-format',
        'json',
        '--permission-mode',
        'plan',
        '--no-session-persistence',
        if (claudeModelArg(model) case final m?) ...['--model', m],
      ],
      // A read-only sandbox; the last message alone goes to the file.
      PlannerCli.codex => [
        'exec',
        '--skip-git-repo-check',
        '--sandbox',
        'read-only',
        if (lastMessage != null) ...['--output-last-message', lastMessage],
        if (model.isNotEmpty) ...['-m', model],
        '--',
        prompt,
      ],
      PlannerCli.opencode => [
        'run',
        if (model.isNotEmpty) ...['-m', model],
        '--',
        prompt,
      ],
      PlannerCli.gemini => [
        '-p',
        prompt,
        if (model.isNotEmpty) ...['-m', model],
      ],
    };

/// The reply in a CLI's output: Claude's JSON `result`, else the output as it is.
String plannerReplyText(PlannerCli cli, String stdout) {
  if (cli != PlannerCli.claude) return stdout;
  try {
    final json = jsonDecode(stdout.trim());
    if (json case {'is_error': true, 'result': final String why}) throw HarnessError('Claude Code: $why');
    if (json case {'result': final String text}) return text;
  } on FormatException {
    // Not the JSON shape: the text as it came.
  }
  return stdout;
}

/// Runs a goal's planner: an outside CLI headless on the user's own plan, or an EveryAI model through the gateway
/// (the user's key or credits, like a Code session). Tests replace it.
abstract interface class BoardPlanner {
  /// Why [pick] can't plan now (not installed, no consent, can't run headless), or null.
  String? unavailable(LeadPick pick);

  /// The planner's reply to [prompt], run in [project]'s folder.
  Future<String> ask(LeadPick pick, String prompt, {required CodeProject project, required String tag});
}

final boardPlannerProvider = Provider<BoardPlanner>(_AppPlanner.new);

final class _AppPlanner implements BoardPlanner {
  _AppPlanner(this.ref);
  final Ref ref;

  @override
  String? unavailable(LeadPick pick) {
    if (pick.harness == everyaiHarnessName) return null;
    final driver = ref.read(driverRegistryProvider).resolve(pick.harness);
    if (driver == null) return 'Not available';
    if (PlannerCli.of(pick.harness) == null) return "Can't plan without a session";
    final status = (ref.read(driverStatusesProvider).value ?? const {})[pick.harness];
    return leadBlocked(
      driver.info,
      status,
      consented: ref.read(codeSettingsProvider).ownClis.contains(driver.info.consentId),
    );
  }

  @override
  Future<String> ask(LeadPick pick, String prompt, {required CodeProject project, required String tag}) async {
    if (unavailable(pick) case final why?) throw HarnessError(why);
    if (isDemoPath(project.path)) throw const HarnessError('The demo project has no model to plan with.');
    if (pick.harness != everyaiHarnessName) {
      if (project.environment != 'host') throw const HarnessError('Planning with a CLI runs on this computer only.');
      return cli.runPlannerCli(pick.harness, pick.model, prompt, project.path);
    }
    final ask = gatewaySummarizer(
      baseUrl: gatewayBaseUrl(ref),
      apiKey: await gatewayKey(ref),
      sessionTag: tag,
      model: pick.model.isEmpty ? ref.read(codeAgentProvider).model : pick.model,
      onUnauthorized: (k) => remintGatewayKey(ref, k),
    );
    return ask([
      {'role': 'user', 'content': prompt},
    ]);
  }
}

/// Starts a session for a task or a race runner; its id. Tests replace it.
abstract interface class BoardStarter {
  Future<String> start({
    required CodeProject project,
    required String prompt,
    required LeadPick lead,
    required bool worktree,
  });
}

final boardStarterProvider = Provider<BoardStarter>(_AppStarter.new);

final class _AppStarter implements BoardStarter {
  _AppStarter(this.ref);
  final Ref ref;

  @override
  Future<String> start({
    required CodeProject project,
    required String prompt,
    required LeadPick lead,
    required bool worktree,
  }) async {
    // The mode the user last started a session of this project in; Auto-edit when none (Code home's default).
    final saved = ref.read(preferencesProvider)[lastModeKey(project.id)];
    final mode = AgentMode.values.asNameMap()[saved] ?? AgentMode.autoEdit;
    final effort = lead.harness == everyaiHarnessName
        ? ref.read(codeAgentProvider).effort
        : ref.read(codeLeadProvider).of(lead.harness).effort;
    final model = lead.model.isNotEmpty
        ? lead.model
        : lead.harness == everyaiHarnessName
        ? ref.read(codeAgentProvider).model
        : ref.read(codeLeadProvider).of(lead.harness).model;
    final info = await ref
        .read(codeSessionsProvider.notifier)
        .start(
          project: project,
          prompt: prompt,
          model: model,
          effort: effort,
          mode: mode,
          isolated: worktree,
          tier: ref.read(codeSettingsProvider).tier,
          harness: lead.harness,
        );
    return info.id;
  }
}

/// The leads a planner may hand tasks to (and a race may run): EveryAI and every outside harness ready to lead here,
/// with the models each lists. [plannerLeadsProvider] keeps it current.
final plannerLeadsProvider = Provider<List<PlannerLead>>((ref) {
  final registry = ref.watch(driverRegistryProvider);
  final statuses = ref.watch(driverStatusesProvider).value ?? const {};
  final own = ref.watch(codeSettingsProvider.select((s) => s.ownClis));
  final agent = ref.watch(codeAgentProvider).model;
  return [
    for (final d in registry.listed)
      if (d.info.id == everyaiHarnessName)
        (id: d.info.id, label: 'EveryAI', models: [if (agent.isNotEmpty) agent])
      else if (leadBlocked(d.info, statuses[d.info.id], consented: own.contains(d.info.consentId)) == null)
        (
          id: d.info.id,
          label: d.info.label,
          models: [for (final m in ref.watch(driverModelsProvider(d.info.id)).value ?? const <DriverModel>[]) m.id],
        ),
  ];
});

/// The lead a new goal plans with and its tasks default to: the user's default Code lead and its model.
final defaultLeadProvider = Provider<LeadPick>((ref) {
  final lead = ref.watch(codeLeadProvider);
  return (
    harness: lead.harness,
    model: lead.harness == everyaiHarnessName ? ref.watch(codeAgentProvider).model : lead.of(lead.harness).model,
  );
});
