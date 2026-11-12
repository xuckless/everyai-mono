// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';

import '../../../../core/process/supervisor.dart';
import '../../harness/events.dart';
import '../../harness/harness.dart';
import '../../harness/session_processes.dart' show registerDriverRoot;
import '../../panes/pty.dart';
import '../briefing/briefing_types.dart' show briefingRootOf;
import '../driver.dart';
import '../driver_process.dart';
import '../short_run.dart' show adoptSlack, logStop;
import 'session_text_stub.dart' if (dart.library.io) 'session_text_io.dart' as text;
import 'terminal_session.dart';

/// A coding CLI with no machine protocol (`terminal:<command>`): it runs in a pseudo-terminal, a message is pasted
/// into it and Return pressed, and the app reads nothing back (see [TerminalSession]).
final class TerminalDriver implements HarnessDriver {
  TerminalDriver({
    required this.id,
    required this.label,
    required this.command,
    this.args = const [],
    this.which,
    this.startPty = startProgram,
    this.readText = text.readSessionText,
    this.settle,
    this._supervisor,
  });

  final String id;
  final String label;
  final String command;
  final List<String> args;

  /// Replaces the PATH lookup (tests).
  final Future<String?> Function(String command)? which;

  /// Replaces the pty start (tests). [env] is added to its environment (the supervisor's tags).
  final Future<ShellPty?> Function({
    required String executable,
    required List<String> args,
    required String workingDir,
    required String sessionTag,
    Map<String, String> env,
  })
  startPty;

  /// The supervisor the CLI's process is adopted by (tests give their own); the app's when null.
  final ProcessSupervisor? _supervisor;
  ProcessSupervisor get supervisor => _supervisor ?? ProcessSupervisor.instance;

  /// Replaces the wait before Return (tests).
  final Future<void> Function()? settle;

  /// Replaces the briefing file read (tests).
  final Future<String?> Function(String briefingRoot) readText;

  @override
  DriverInfo get info => DriverInfo(id: id, label: label);

  @override
  Set<DriverCap> get caps => const {};

  @override
  Future<DriverStatus> detect() => detectCli(command, which: which);

  @override
  Future<List<DriverModel>> models() async => const [];

  @override
  Future<HarnessSession> start(SessionSpec spec) async {
    final status = await detect();
    final path = status.path;
    if (!status.installed || path == null) throw HarnessError("$label isn't installed.");
    final owner = SessionOwner(spec.procTag);
    final startedAt = DateTime.now();
    final pty = await startPty(
      executable: path,
      args: args,
      workingDir: spec.workingDir,
      sessionTag: spec.procTag,
      // flutter_pty starts it, so the supervisor adopts it: it carries the tags a spawn would give it.
      env: supervisor.tagsFor(owner),
    );
    if (pty == null) throw HarnessError('A terminal session needs a desktop computer.');
    final SupervisedChild child;
    try {
      child = supervisor.adopt(
        pty.pid,
        SpawnSpec(owner: owner, kind: ProcessKind.pty, exe: path, args: args, label: '$label (terminal)'),
        exitCode: pty.exitCode,
        // Our own child, just started: matched by its start time before it is ever signalled.
        startedWithin: DateTime.now().difference(startedAt) + adoptSlack,
      );
    } on SupervisorClosed {
      // Started while the app quits: it must not outlive it.
      logStop('$label (terminal)', await supervisor.killTree(pty.pid));
      rethrow;
    }
    registerDriverRoot(spec.procTag, pty.pid);
    final skillDir = spec.briefing?.skillDir;
    final session = TerminalSession(
      id: spec.sessionTag,
      label: label,
      pty: pty,
      child: child,
      sessionTag: spec.procTag,
      briefing: skillDir == null ? null : () => readText(briefingRootOf(skillDir)),
      settle: settle ?? TerminalSession.defaultSettle,
    );
    // Shown at once; pasted when the CLI has drawn its first screen.
    if (spec.initialMessage case final text? when text.isNotEmpty && spec.runInitial) unawaited(session.send(text));
    return session;
  }

  @override
  Future<HarnessSession> attach(String conversationId) async =>
      throw HarnessError("$label sessions can't be reopened.");

  @override
  Future<Map<String, ExecutionStatus>> statuses(List<String> conversationIds) async => const {};
}
