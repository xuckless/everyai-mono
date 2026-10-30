import 'agent_prompt.dart';
import 'agent_settings.dart';
import 'settings_stub.dart' if (dart.library.io) 'settings_io.dart' as impl;

export 'agent_settings.dart';
export 'agent_prompt.dart' show HarnessMode, HarnessTier, bugFixRules, tierChangeNote;

/// Project settings committed with the repo.
const projectSettingsPath = '.everyai/settings.json';

/// Personal overrides for one checkout; kept out of git.
const localSettingsPath = '.everyai/settings.local.json';

/// The user's settings (App Support `settings.json`), then [projectDir]'s
/// project and local files, merged. Missing or malformed files are skipped.
Future<AgentSettings> loadAgentSettings(String projectDir) => impl.loadAgentSettings(projectDir);

/// [style], or for [CommitStyle.auto] the style of [projectDir]'s recent commits.
Future<CommitStyle> resolveCommitStyle(String projectDir, CommitStyle style) =>
    impl.resolveCommitStyle(projectDir, style);

/// Adds [patterns] to the repository's `info/exclude` (shared by its
/// worktrees). Does nothing outside a git repository.
Future<void> excludeFromGit(String workingDir, List<String> patterns) => impl.excludeFromGit(workingDir, patterns);

/// The persona and system-prompt suffix for a session in [projectDir], from
/// its settings and commit history; [agents] as in [agentPromptSuffix].
/// [isolated] and [everyai] as in [agentPersona].
Future<({String persona, String suffix})> agentPromptFor(
  String projectDir, {
  List<({String name, String description})> agents = const [],
  bool isolated = false,
  bool everyai = false,
  HarnessTier tier = HarnessTier.efficient,
  bool forks = false,
  Map<String, String> models = const {},
  HarnessMode harnessMode = HarnessMode.build,
}) async {
  final settings = await loadAgentSettings(projectDir);
  final style = await resolveCommitStyle(projectDir, settings.commitStyle);
  return (
    persona: agentPersona(style: style, attribution: settings.attribution, isolated: isolated, everyai: everyai),
    suffix: agentPromptSuffix(
      settings,
      agents: agents,
      everyai: everyai,
      tier: tier,
      forks: forks,
      models: models,
      harnessMode: harnessMode,
    ),
  );
}
