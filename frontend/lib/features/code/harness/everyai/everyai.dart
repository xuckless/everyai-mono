import 'package:http/http.dart' as http;

import '../harness.dart';
import 'everyai_stub.dart' if (dart.library.io) 'everyai_harness_io.dart' as impl;
import 'facade_stub.dart' if (dart.library.io) 'agent_server_facade_io.dart' as facade;

/// The EveryAI harness (desktop only: it runs commands and edits files on
/// this computer). See `everyai_harness_io.dart`.
Harness everyAIHarness({
  required Future<String> Function() dataDir,
  required Future<String> Function() gatewayKey,
  http.Client? client,
}) => impl.EveryAIHarness(dataDir: dataDir, gatewayKey: gatewayKey, client: client);

/// Starts [spec] as a fork of [parentConversationId] when [harness] can fork
/// (the EveryAI harness); null otherwise.
Future<HarnessSession>? forkSession(Harness harness, String parentConversationId, SessionSpec spec) =>
    harness is impl.EveryAIHarness ? harness.fork(parentConversationId, spec) : null;

/// Serves [harness] on loopback behind the agent-server protocol (see
/// `AgentServerFacade`), for paired devices; returns where and its key.
Future<({Uri baseUrl, String key})> serveAsAgentServer(
  Harness harness, {
  Future<SessionSpec> Function(SessionSpec spec)? enrich,
}) async {
  final f = await facade.AgentServerFacade.start(harness, enrich: enrich);
  return (baseUrl: f.baseUrl, key: f.key);
}
