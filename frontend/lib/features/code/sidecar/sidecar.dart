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

  /// Started (or starting) already: asking it something won't start it.
  bool get started;

  /// Fires when a server that crashed is running again (new port and key).
  /// Sessions reconnect at once and resume a run the crash cut off.
  Stream<void> get restarts;

  Future<void> stop();
}

/// How often a crashed server is started again: at once, unless it crashed
/// [limit] times within [window]; then not before [cooldown] has passed since
/// the last crash, so a server that dies on start doesn't spin.
final class CrashPolicy {
  CrashPolicy({this.limit = 3, this.window = const Duration(minutes: 1), this.cooldown = const Duration(seconds: 30)});

  final int limit;
  final Duration window;
  final Duration cooldown;
  final _crashes = <DateTime>[];

  void crashed(DateTime at) {
    _crashes
      ..add(at)
      ..removeWhere((t) => at.difference(t) > window);
  }

  /// When a start is allowed again, or null if it is now.
  DateTime? blockedUntil(DateTime now) {
    final recent = _crashes.where((t) => now.difference(t) <= window).toList();
    if (recent.length < limit) return null;
    final until = recent.last.add(cooldown);
    return now.isBefore(until) ? until : null;
  }
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
