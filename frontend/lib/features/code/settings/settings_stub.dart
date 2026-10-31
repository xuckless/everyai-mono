import 'agent_settings.dart';

Future<AgentSettings> loadAgentSettings(String projectDir) async => AgentSettings.defaults;

Future<CommitStyle> resolveCommitStyle(String projectDir, CommitStyle style) async =>
    style == CommitStyle.auto ? CommitStyle.conventional : style;

Future<void> excludeFromGit(String workingDir, List<String> patterns) async {}

Future<String?> userSettingsPath() async => null;

Future<Map<String, Object?>> readLayer(String path) async => {};

Future<Map<String, Object?>> writeLayer(
  String path,
  Map<String, Object?> Function(Map<String, Object?> current) edit,
) async => throw UnsupportedError('No settings files here.');
