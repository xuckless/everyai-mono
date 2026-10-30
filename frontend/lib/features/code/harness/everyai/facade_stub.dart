import '../harness.dart';

/// Hosting needs a desktop.
final class AgentServerFacade {
  AgentServerFacade._();

  Uri get baseUrl => throw UnsupportedError('Hosting runs on the desktop app.');
  String get key => throw UnsupportedError('Hosting runs on the desktop app.');

  static Future<AgentServerFacade> start(
    Harness harness, {
    Future<SessionSpec> Function(SessionSpec spec)? enrich,
  }) async => throw UnsupportedError('Hosting runs on the desktop app.');
}
