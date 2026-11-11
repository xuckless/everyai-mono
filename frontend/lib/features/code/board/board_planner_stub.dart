import '../harness/harness.dart' show HarnessError;

/// No CLIs on the web.
Future<String> runPlannerCli(String harness, String model, String prompt, String cwd, {Duration? timeout}) async =>
    throw const HarnessError('Planning with a CLI needs the desktop app.');
