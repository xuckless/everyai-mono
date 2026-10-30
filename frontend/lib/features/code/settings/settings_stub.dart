import 'agent_settings.dart';

Future<AgentSettings> loadAgentSettings(String projectDir) async => AgentSettings.defaults;

Future<CommitStyle> resolveCommitStyle(String projectDir, CommitStyle style) async =>
    style == CommitStyle.auto ? CommitStyle.conventional : style;

Future<void> excludeFromGit(String workingDir, List<String> patterns) async {}
