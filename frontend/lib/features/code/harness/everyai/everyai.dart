// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:http/http.dart' as http;

import '../harness.dart';
import 'everyai_stub.dart' if (dart.library.io) 'everyai_harness_io.dart' as impl;

/// The EveryAI harness (desktop only: it runs commands and edits files on
/// this computer). See `everyai_harness_io.dart`.
Harness everyAIHarness({
  required Future<String> Function() dataDir,
  required Future<String> Function() gatewayKey,
  http.Client? client,
}) => impl.EveryAIHarness(dataDir: dataDir, gatewayKey: gatewayKey, client: client);

/// True on Windows when Git Bash isn't installed, so the EveryAI harness
/// can't run commands (see `git_bash.dart`).
bool gitBashMissing() => impl.gitBashMissing();

/// Starts [spec] as a fork of [parentConversationId] when [harness] can fork
/// (the EveryAI harness, or a driver around it); null otherwise.
Future<HarnessSession>? forkSession(Harness harness, String parentConversationId, SessionSpec spec) =>
    switch (harness) {
      final ForksSessions f => f.fork(parentConversationId, spec),
      _ => null,
    };

/// Ends every EveryAI-harness session's language servers (the app quits).
Future<void> closeAllLanguageServers() => impl.closeAllLanguageServers();
