import '../harness/harness.dart' show HarnessError;

/// No CLIs on the web.
Future<String> runPlannerCli(
  String harness,
  String model,
  String prompt,
  String cwd, {
  required String tag,
  Duration? timeout,
  Future<void>? cancel,
}) async => throw const HarnessError('Planning with a CLI needs the desktop app.');
