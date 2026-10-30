import 'package:flutter/foundation.dart';

import 'sidecar_stub.dart' if (dart.library.io) 'sidecar_io.dart' as impl;

/// Where a running agent server listens, and the key its REST and WS calls need.
@immutable
final class AgentServerEndpoint {
  const AgentServerEndpoint(this.baseUrl, this.sessionApiKey);
  final Uri baseUrl;
  final String sessionApiKey;
}

/// The OpenHands agent-server the Code workspace runs on.
///
/// With `AGENT_SERVER_URL` (+ `AGENT_SERVER_KEY`) set at build time, the app
/// uses that server. Otherwise it starts the binary itself: `AGENT_SERVER_BIN`,
/// else `agent-server` in the app bundle's Resources or the app support `bin/`
/// folder (`tool/fetch_agent_server.sh` downloads it).
abstract interface class Sidecar {
  /// Starts the server if it isn't running and resolves once it is ready.
  Future<AgentServerEndpoint> endpoint();

  Future<void> stop();
}

final class SidecarError implements Exception {
  const SidecarError(this.message);
  final String message;
  @override
  String toString() => message;
}

Sidecar createSidecar() => impl.createSidecar();

/// Creates a small git repo (a Dart `Counter` with one test) to try the agent
/// on, and returns its path. Each call makes a fresh copy.
Future<String> createSampleProject() => impl.createSampleProject();
