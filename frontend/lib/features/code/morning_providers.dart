import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'code_providers.dart';
import 'domain/code_session.dart';
import 'domain/morning.dart';
import 'domain/session_commands.dart';
import 'git/git_service.dart';

/// The `/morning` brief, shown as a card in Code until dismissed; null when
/// none is shown.
final morningBriefProvider = NotifierProvider<MorningBriefController, Aside?>(MorningBriefController.new);

final class MorningBriefController extends Notifier<Aside?> {
  int _ids = 0;

  @override
  Aside? build() => null;

  void dismiss() => state = null;

  /// Gathers every session's status and changes and writes the brief. No
  /// model call: everything comes from the app, git and the agent server.
  Future<void> refresh({DateTime? now}) async {
    final id = --_ids; // Negative, so it never collides with a session's aside ids.
    final pending = Aside(id: id, kind: AsideKind.morning, busy: true);
    state = pending;
    _read = 0;
    try {
      final sessions = ref.read(codeSessionsProvider);
      final projects = {for (final p in ref.read(codeProjectsProvider)) p.id: p.name};
      final top = [
        for (final s in sessions)
          if (!s.isSubagent) s,
      ];
      final statuses = await sessionStatusesNow(ref, top);
      final entries = await Future.wait([
        for (final s in top) _entry(s, statuses[s.id] ?? SessionStatus.idle, projects[s.projectId] ?? ''),
      ]);
      if (state?.id != id) return;
      state = pending.done(morningBrief(entries, now: now ?? DateTime.now()));
    } on Object catch (e) {
      if (state?.id == id) state = pending.failed("Couldn't put the brief together: $e");
    }
  }

  /// The most sessions whose git state is read (newest first); older ones
  /// show with their status only.
  static const _gitReads = 20;
  int _read = 0;

  Future<MorningEntry> _entry(CodeSessionInfo s, SessionStatus status, String project) async {
    final w = s.worktree;
    if (w == null || _read++ >= _gitReads) return MorningEntry(session: s, status: status, project: project);
    try {
      final (changes, counts) = await (GitService.changes(w), GitService.aheadBehind(w)).wait;
      return MorningEntry(
        session: s,
        status: status,
        project: project,
        files: changes.length,
        added: changes.fold(0, (n, c) => n + c.added),
        removed: changes.fold(0, (n, c) => n + c.removed),
        ahead: counts.ahead,
      );
    } on Object {
      // A worktree that was removed by hand: status only.
      return MorningEntry(session: s, status: status, project: project);
    }
  }
}
