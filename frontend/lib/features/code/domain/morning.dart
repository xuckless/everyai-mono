import 'package:flutter/foundation.dart';

import 'code_session.dart';

/// One session as the morning brief sees it.
@immutable
final class MorningEntry {
  const MorningEntry({
    required this.session,
    required this.status,
    this.project = '',
    this.files = 0,
    this.added = 0,
    this.removed = 0,
    this.ahead = 0,
  });

  final CodeSessionInfo session;
  final SessionStatus status;
  final String project;

  /// Changes since the session's base commit (committed or not).
  final int files;
  final int added;
  final int removed;

  /// Commits on the session branch not on its base branch.
  final int ahead;

  bool get hasChanges => files > 0 || ahead > 0;
}

/// How far back finished sessions without changes are still mentioned.
const morningWindow = Duration(days: 3);

/// The brief in Markdown: what waits on the user, what is running, what is
/// done but not merged, and what failed. Subagents are left out (their
/// parent stands for them). No model call: it reads only what is known.
String morningBrief(List<MorningEntry> entries, {required DateTime now}) {
  final top = [
    for (final e in entries)
      if (!e.session.isSubagent) e,
  ]..sort((a, b) => b.session.createdAt.compareTo(a.session.createdAt));
  bool recent(MorningEntry e) => now.difference(e.session.createdAt) <= morningWindow;

  final waiting = [
    for (final e in top)
      if (e.status == SessionStatus.needsInput) e,
  ];
  final failed = [
    for (final e in top)
      if (e.status == SessionStatus.failed && (recent(e) || e.hasChanges)) e,
  ];
  final running = [
    for (final e in top)
      if (e.status == SessionStatus.running || e.status == SessionStatus.starting) e,
  ];
  final toMerge = [
    for (final e in top)
      if ((e.status == SessionStatus.done || e.status == SessionStatus.idle) && e.hasChanges) e,
  ];
  final quiet = [
    for (final e in top)
      if ((e.status == SessionStatus.done || e.status == SessionStatus.idle) && !e.hasChanges && recent(e)) e,
  ];

  final out = StringBuffer();
  final hour = now.hour;
  out.writeln(hour < 12 ? '**Good morning.**' : (hour < 18 ? '**Good afternoon.**' : '**Good evening.**'));
  if (top.isEmpty) {
    out.write('\nNo coding sessions yet. Start one from Code.');
    return out.toString();
  }
  final counts = [
    if (waiting.isNotEmpty) '${waiting.length} waiting on you',
    if (running.isNotEmpty) '${running.length} working',
    if (toMerge.isNotEmpty) '${toMerge.length} with changes to merge',
    if (failed.isNotEmpty) '${failed.length} failed',
  ];
  out.writeln(counts.isEmpty ? '\nNothing needs you right now.' : '\n${_capitalize(counts.join(', '))}.');

  void section(String heading, List<MorningEntry> list, String Function(MorningEntry) detail) {
    if (list.isEmpty) return;
    out.writeln('\n**$heading**');
    for (final e in list.take(8)) {
      final where = e.project.isEmpty ? '' : ' · ${e.project}';
      final more = detail(e);
      out.writeln('- ${e.session.title}$where${more.isEmpty ? '' : ' — $more'}');
    }
    if (list.length > 8) out.writeln('- and ${list.length - 8} more');
  }

  section('Waiting on you', waiting, _changes);
  section('Failed', failed, _changes);
  String age(MorningEntry e) => _age(e, now);
  section('Working', running, age);
  section('Done, not merged', toMerge, _changes);
  section('Finished recently', quiet, age);
  return out.toString().trimRight();
}

String _changes(MorningEntry e) {
  if (!e.hasChanges) return '';
  final parts = [
    if (e.files > 0) '${e.files} file${e.files == 1 ? '' : 's'} changed (+${e.added} −${e.removed})',
    if (e.ahead > 0) '${e.ahead} commit${e.ahead == 1 ? '' : 's'} on `${e.session.branch}`',
  ];
  return parts.join(', ');
}

String _age(MorningEntry e, DateTime now) {
  final d = now.difference(e.session.createdAt);
  if (d.inMinutes < 60) return 'started ${d.inMinutes < 1 ? 'just now' : '${d.inMinutes} min ago'}';
  if (d.inHours < 24) return 'started ${d.inHours} h ago';
  return 'started ${d.inDays} d ago';
}

String _capitalize(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
